/* Copyright (c) 2026, MariaDB plc

   This program is free software; you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation; version 2 of the License.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program; if not, write to the Free Software
   Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1335 USA */

#include "mariadb.h"
#include "sql_priv.h"
#include "sql_class.h"
#include "sql_lex.h"
#include "sql_select.h"
#include "sql_plan_cache.h"
#include "item_cmpfunc.h"
#include "item_sum.h"
#include "item.h"
#include "table.h"

#include <atomic>
#include <new>

namespace plan_cache
{

enum class Invalidation_reason
{
  NONE,
  DISABLED,
  NOT_ELIGIBLE,
  OPTIMIZER_SWITCH,
  CHARACTER_SET_CLIENT,
  TABLE_VERSION,
  TABLE_RECORDS,
  TABLE_RECORDS_REFRESH_FAILED,
  PARAMETER_SHAPE,
  ACCESS_SHAPE
};

class Table_stats_refresh_error_handler : public Internal_error_handler
{
public:
  Table_stats_refresh_error_handler() : m_error(false) {}

  bool handle_condition(THD *thd,
                        uint sql_errno,
                        const char *sqlstate,
                        Sql_condition::enum_warning_level *level,
                        const char *msg,
                        Sql_condition **cond_hdl) override
  {
    if (*level != Sql_condition::WARN_LEVEL_ERROR)
      return false;

    m_error= true;
    *cond_hdl= NULL;
    return true;
  }

  bool saw_error() const { return m_error; }

private:
  bool m_error;
};

struct Param_signature
{
  Item::Type type;
  enum_field_types field_type;
  Item_result cmp_type;
  uint32 max_length;
  uint decimals;
  bool unsigned_flag;
  bool maybe_null;
  bool null_value;
  bool no_value;
  const CHARSET_INFO *collation;
  Derivation derivation;

  bool operator==(const Param_signature &rhs) const
  {
    return type == rhs.type &&
           field_type == rhs.field_type &&
           cmp_type == rhs.cmp_type &&
           max_length == rhs.max_length &&
           decimals == rhs.decimals &&
           unsigned_flag == rhs.unsigned_flag &&
           maybe_null == rhs.maybe_null &&
           null_value == rhs.null_value &&
           no_value == rhs.no_value &&
           collation == rhs.collation &&
           derivation == rhs.derivation;
  }
};

struct Param_signature_array
{
  Param_signature *data;
  size_t elements;

  Param_signature_array() : data(0), elements(0) {}

  ~Param_signature_array()
  {
    my_free(data);
  }

  bool allocate(size_t count)
  {
    data= 0;
    elements= count;
    if (!count)
      return true;

    data= static_cast<Param_signature *>
      (my_malloc(PSI_NOT_INSTRUMENTED,
                 sizeof(Param_signature) * count, MYF(0)));
    if (!data)
    {
      elements= 0;
      return false;
    }
    return true;
  }

private:
  Param_signature_array(const Param_signature_array&);
  Param_signature_array &operator=(const Param_signature_array&);
};

struct Access_signature
{
  uint table_count;
  uint const_tables;
  uint top_join_tab_count;
  bool impossible_where;
  bool zero_result;
  enum join_type join_type;
  int ref_key;
  uint ref_key_parts;
  uint ref_key_length;
  key_part_map ref_const_part_map;
  key_part_map ref_null_rejecting;
  uint index;
  uint use_quick;
  int quick_type;
  uint quick_index;
  uint quick_used_key_parts;
  uint quick_max_used_key_length;
  ha_rows quick_records;
  double quick_read_time;
  uint quick_mrr_flags;
  uint quick_mrr_buf_size;

  bool operator==(const Access_signature &rhs) const
  {
    return table_count == rhs.table_count &&
           const_tables == rhs.const_tables &&
           top_join_tab_count == rhs.top_join_tab_count &&
           impossible_where == rhs.impossible_where &&
           zero_result == rhs.zero_result &&
           join_type == rhs.join_type &&
           ref_key == rhs.ref_key &&
           ref_key_parts == rhs.ref_key_parts &&
           ref_key_length == rhs.ref_key_length &&
           ref_const_part_map == rhs.ref_const_part_map &&
           ref_null_rejecting == rhs.ref_null_rejecting &&
           index == rhs.index &&
           use_quick == rhs.use_quick &&
           quick_type == rhs.quick_type &&
           quick_index == rhs.quick_index &&
           quick_used_key_parts == rhs.quick_used_key_parts &&
           quick_max_used_key_length == rhs.quick_max_used_key_length &&
           quick_records == rhs.quick_records &&
           quick_read_time == rhs.quick_read_time &&
           quick_mrr_flags == rhs.quick_mrr_flags &&
           quick_mrr_buf_size == rhs.quick_mrr_buf_size;
  }
};

enum class Recipe_kind
{
  NONE,
  UNIQUE_EQ_PARAM,
  REF_EQ_PARAM,
  RANGE_BETWEEN_PARAM
};

struct Access_recipe
{
  Recipe_kind kind;
  uint key;
  uint key_parts;
  ulong key_flags;
  field_index_t fieldnr;
  uint field_length;
  enum_field_types field_type;
  const CHARSET_INFO *field_charset;
  uint param_index;
  uint high_param_index;
  Item_param *param_item;
  Item_param *high_param_item;
  Param_signature param_signature;
  Param_signature high_param_signature;

  bool operator==(const Access_recipe &rhs) const
  {
    if (kind != rhs.kind)
      return false;
    if (kind == Recipe_kind::NONE)
      return true;
    return key == rhs.key &&
           key_parts == rhs.key_parts &&
           key_flags == rhs.key_flags &&
           fieldnr == rhs.fieldnr &&
           field_length == rhs.field_length &&
           field_type == rhs.field_type &&
           field_charset == rhs.field_charset &&
           param_index == rhs.param_index &&
           high_param_index == rhs.high_param_index &&
           param_item == rhs.param_item &&
           high_param_item == rhs.high_param_item &&
           param_signature == rhs.param_signature &&
           high_param_signature == rhs.high_param_signature;
  }
};

struct Pending_access_recipe
{
  Access_recipe recipe;
};

static bool make_param_signatures(LEX *lex, Param_signature_array *signatures);
static Access_signature make_access_signature(JOIN *join);
static Access_recipe make_access_recipe(LEX *lex, SELECT_LEX *select_lex,
                                        JOIN *join);
static Eligibility check_execute_eligibility(THD *thd, SELECT_LEX *select_lex,
                                             TABLE **table_arg);
static void clear_pending_access_recipe(SELECT_LEX *select_lex);
static const Lex_select_limit *explicit_limit_params(SELECT_LEX *select_lex);
static bool supports_limit_boundary(SELECT_LEX *select_lex);
static bool supports_limit_recipe_boundary(LEX *lex, SELECT_LEX *select_lex);
static std::atomic_ulong cached_plan_live_count(0);

static inline bool profile_enabled(THD *thd)
{
  return thd && thd->variables.session_plan_cache_profile;
}

static inline ulonglong profile_start(THD *thd)
{
  return profile_enabled(thd) ? microsecond_interval_timer() : 0;
}

static inline void profile_add(THD *thd, ulonglong start, ulonglong *counter)
{
  if (start)
    *counter+= microsecond_interval_timer() - start;
}

static inline ulonglong profile_elapsed(ulonglong start)
{
  return start ? microsecond_interval_timer() - start : 0;
}

static inline void profile_add_delta(ulonglong delta, ulonglong *counter)
{
  if (delta)
    *counter+= delta;
}

struct Cached_plan_state
{
  ulonglong optimizer_switch;
  const CHARSET_INFO *character_set_client;
  ulonglong table_ref_version;
  ha_rows table_records;
  Param_signature_array param_signatures;
  Access_signature access_signature;
  Access_recipe access_recipe;

  Cached_plan_state(THD *thd, TABLE *table, SELECT_LEX *select_lex,
                    JOIN *join, const Access_recipe &recipe)
    : optimizer_switch(thd->variables.optimizer_switch),
      character_set_client(thd->variables.character_set_client),
      table_ref_version(table->s->get_table_ref_version()),
      table_records(table->file ? table->file->stats.records : 0),
      access_signature(make_access_signature(join)),
      access_recipe(recipe)
  {}

  bool init(THD *thd)
  {
    return make_param_signatures(thd->lex, &param_signatures);
  }
};

static Eligibility make_result(Eligibility_reason reason)
{
  return {reason == Eligibility_reason::CANDIDATE, reason};
}

static Execute_validation make_execute_validation(bool had_state,
                                                  bool invalidated,
                                                  bool recipe_prevalidated)
{
  return {had_state, invalidated, recipe_prevalidated};
}

static void destroy_state(THD *thd, SELECT_LEX *select_lex, bool invalidation)
{
  if (!thd || !select_lex)
    return;

  clear_pending_access_recipe(select_lex);

  if (!select_lex->plan_cache_state)
  {
    select_lex->plan_cache_state_status= State::NONE;
    return;
  }

  delete select_lex->plan_cache_state;
  select_lex->plan_cache_state= 0;
  select_lex->plan_cache_state_status= State::NONE;

  cached_plan_live_count.fetch_sub(1, std::memory_order_relaxed);

  if (invalidation)
    status_var_increment(thd->status_var.cached_plan_invalidations);
}

static void mark_uncacheable(SELECT_LEX *select_lex)
{
  if (!select_lex || select_lex->plan_cache_state_status == State::READY)
    return;
  clear_pending_access_recipe(select_lex);
  select_lex->plan_cache_state_status= State::UNCACHEABLE;
}

static bool permanently_uncacheable(Eligibility_reason reason)
{
  switch (reason) {
  case Eligibility_reason::DISABLED:
  case Eligibility_reason::NOT_PREPARED_STATEMENT:
  case Eligibility_reason::CANDIDATE:
    return false;
  case Eligibility_reason::NOT_SELECT:
  case Eligibility_reason::EXPLAIN_OR_ANALYZE:
  case Eligibility_reason::NOT_TOP_LEVEL_SELECT:
  case Eligibility_reason::NOT_SINGLE_TABLE:
  case Eligibility_reason::NOT_BASE_TABLE:
  case Eligibility_reason::HAS_SET_OPERATION:
  case Eligibility_reason::HAS_GROUP_ORDER_DISTINCT_OR_WINDOW:
  case Eligibility_reason::HAS_SUBQUERY:
  case Eligibility_reason::HAS_USER_VARIABLE:
  case Eligibility_reason::HAS_LOCKING_CLAUSE:
  case Eligibility_reason::HAS_UNSUPPORTED_TABLE:
    return true;
  }
  return true;
}

static TABLE_LIST *single_table_list(SELECT_LEX *select_lex)
{
  if (!select_lex || select_lex->leaf_tables.elements != 1)
    return 0;
  return select_lex->leaf_tables.head();
}

static TABLE *single_table(SELECT_LEX *select_lex)
{
  TABLE_LIST *table_list= single_table_list(select_lex);
  return table_list ? table_list->table : 0;
}

static bool current_table_records(THD *thd, TABLE *table, ha_rows *records)
{
  if (!thd || !table || !table->file || !records)
    return false;

  DBUG_EXECUTE_IF("session_plan_cache_table_info_fail",
  {
    DBUG_PRINT("plan_cache", ("debug table info refresh failure table=%p",
                              table));
    return false;
  });

  Table_stats_refresh_error_handler error_handler;
  bool had_error= thd->is_error();
  thd->push_internal_handler(&error_handler);
  int error= table->file->info(HA_STATUS_VARIABLE | HA_STATUS_NO_LOCK);
  thd->pop_internal_handler();
  if (!had_error && thd->is_error() && !thd->is_fatal_error)
    thd->clear_error();

  if (error || error_handler.saw_error())
    return false;

  *records= table->file->stats.records;
  return true;
}

static bool table_records_changed_sharply(ha_rows old_records,
                                          ha_rows new_records,
                                          double ratio)
{
  if (ratio <= 0 || old_records == new_records)
    return false;

  if (!old_records || !new_records)
    return true;

  double old_value= static_cast<double>(old_records);
  double new_value= static_cast<double>(new_records);
  double delta= old_value > new_value ? old_value - new_value :
                                      new_value - old_value;
  return delta / old_value > ratio;
}

static Param_signature make_param_signature(Item_param *param)
{
  Param_signature signature;
  signature.type= param->type();
  signature.field_type= param->field_type();
  signature.cmp_type= param->type_handler()->cmp_type();
  signature.max_length= param->max_length;
  signature.decimals= param->decimals;
  signature.unsigned_flag= param->unsigned_flag;
  signature.maybe_null= param->maybe_null();
  signature.null_value= param->null_value;
  signature.no_value= param->has_no_value();
  signature.collation= param->collation.collation;
  signature.derivation= param->collation.derivation;
  return signature;
}

static bool make_param_signatures(LEX *lex, Param_signature_array *signatures)
{
  if (!lex)
    return signatures->allocate(0);

  if (!signatures->allocate(lex->param_list.elements))
    return false;

  List_iterator_fast<Item_param> it(lex->param_list);
  Item_param *param;
  size_t i= 0;
  while ((param= it++))
    signatures->data[i++]= make_param_signature(param);
  DBUG_ASSERT(i == signatures->elements);
  return true;
}

static bool param_signatures_match(LEX *lex,
                                   const Param_signature_array &stored)
{
  if (!lex)
    return stored.elements == 0;

  if (lex->param_list.elements != stored.elements)
    return false;

  List_iterator_fast<Item_param> it(lex->param_list);
  Item_param *param;
  size_t i= 0;
  while ((param= it++))
  {
    if (!(stored.data[i++] == make_param_signature(param)))
      return false;
  }
  DBUG_ASSERT(i == stored.elements);
  return true;
}

static void clear_pending_access_recipe(SELECT_LEX *select_lex)
{
  if (!select_lex || !select_lex->plan_cache_pending_access_recipe)
    return;

  delete select_lex->plan_cache_pending_access_recipe;
  select_lex->plan_cache_pending_access_recipe= 0;
}

static Access_recipe empty_access_recipe()
{
  Access_recipe recipe;
  recipe.kind= Recipe_kind::NONE;
  recipe.key= MAX_KEY;
  recipe.key_parts= 0;
  recipe.key_flags= 0;
  recipe.fieldnr= 0;
  recipe.field_length= 0;
  recipe.field_type= MYSQL_TYPE_NULL;
  recipe.field_charset= 0;
  recipe.param_index= UINT_MAX;
  recipe.high_param_index= UINT_MAX;
  recipe.param_item= 0;
  recipe.high_param_item= 0;
  recipe.param_signature.type= Item::NULL_ITEM;
  recipe.param_signature.field_type= MYSQL_TYPE_NULL;
  recipe.param_signature.cmp_type= STRING_RESULT;
  recipe.param_signature.max_length= 0;
  recipe.param_signature.decimals= 0;
  recipe.param_signature.unsigned_flag= false;
  recipe.param_signature.maybe_null= false;
  recipe.param_signature.null_value= false;
  recipe.param_signature.no_value= true;
  recipe.param_signature.collation= 0;
  recipe.param_signature.derivation= DERIVATION_IGNORABLE;
  recipe.high_param_signature= recipe.param_signature;
  return recipe;
}

static void capture_pending_access_recipe(THD *thd, SELECT_LEX *select_lex)
{
  if (!thd || !select_lex)
    return;

  Access_recipe recipe= make_access_recipe(thd->lex, select_lex, 0);
  clear_pending_access_recipe(select_lex);
  if (recipe.kind == Recipe_kind::NONE)
    return;

  Pending_access_recipe *pending= new (std::nothrow) Pending_access_recipe;
  if (!pending)
    return;
  pending->recipe= recipe;
  select_lex->plan_cache_pending_access_recipe= pending;
}

static Access_recipe consume_pending_access_recipe(SELECT_LEX *select_lex)
{
  Access_recipe recipe= empty_access_recipe();
  if (!select_lex || !select_lex->plan_cache_pending_access_recipe)
    return recipe;

  recipe= select_lex->plan_cache_pending_access_recipe->recipe;
  clear_pending_access_recipe(select_lex);
  return recipe;
}

static Item *real_item_or_self(Item *item)
{
  return item ? item->real_item() : 0;
}

static bool find_param_index(LEX *lex, Item_param *wanted, uint *index)
{
  if (!lex || !wanted || !index)
    return false;

  List_iterator_fast<Item_param> it(lex->param_list);
  Item_param *param;
  uint i= 0;
  while ((param= it++))
  {
    if (param == wanted)
    {
      *index= i;
      return true;
    }
    i++;
  }
  return false;
}

static bool split_field_param_eq(Item *cond, Item_field **field_item,
                                 Item_param **param_item)
{
  if (!cond || cond->type() != Item::FUNC_ITEM)
    return false;

  Item_func *func= static_cast<Item_func *>(cond);
  if (func->functype() != Item_func::EQ_FUNC || func->argument_count() != 2)
    return false;

  Item **args= func->arguments();
  Item *left= real_item_or_self(args[0]);
  Item *right= real_item_or_self(args[1]);

  if (left && left->type() == Item::FIELD_ITEM && right)
  {
    Settable_routine_parameter *srp= right->get_settable_routine_parameter();
    Item_param *param= srp ? srp->get_item_param() : 0;
    if (param)
    {
      *field_item= static_cast<Item_field *>(left);
      *param_item= param;
      return true;
    }
  }

  if (right && right->type() == Item::FIELD_ITEM && left)
  {
    Settable_routine_parameter *srp= left->get_settable_routine_parameter();
    Item_param *param= srp ? srp->get_item_param() : 0;
    if (param)
    {
      *field_item= static_cast<Item_field *>(right);
      *param_item= param;
      return true;
    }
  }

  return false;
}

static bool split_field_param_between(Item *cond, Item_field **field_item,
                                      Item_param **low_param,
                                      Item_param **high_param)
{
  if (!cond || cond->type() != Item::FUNC_ITEM)
    return false;

  Item_func *func= static_cast<Item_func *>(cond);
  if (func->functype() != Item_func::BETWEEN || func->argument_count() != 3)
    return false;

  Item_func_between *between= static_cast<Item_func_between *>(func);
  if (between->negated)
    return false;

  Item **args= func->arguments();
  Item *field= real_item_or_self(args[0]);
  Item *low= real_item_or_self(args[1]);
  Item *high= real_item_or_self(args[2]);
  if (!field || field->type() != Item::FIELD_ITEM || !low || !high)
    return false;

  Settable_routine_parameter *low_srp= low->get_settable_routine_parameter();
  Settable_routine_parameter *high_srp= high->get_settable_routine_parameter();
  Item_param *low_item= low_srp ? low_srp->get_item_param() : 0;
  Item_param *high_item= high_srp ? high_srp->get_item_param() : 0;
  if (!low_item || !high_item)
    return false;

  *field_item= static_cast<Item_field *>(field);
  *low_param= low_item;
  *high_param= high_item;
  return true;
}

static bool supports_sum_range_boundary(SELECT_LEX *select_lex)
{
  if (!select_lex ||
      !(select_lex->with_sum_func ||
        select_lex->n_sum_items ||
        select_lex->n_child_sum_items))
    return true;

  if (select_lex->item_list.elements != 1)
    return false;

  List_iterator_fast<Item> it(select_lex->item_list);
  Item *item= it++;
  if (!item || item->type() != Item::SUM_FUNC_ITEM)
    return false;

  Item_sum *sum_item= static_cast<Item_sum *>(item);
  if (sum_item->sum_func() != Item_sum::SUM_FUNC)
    return false;
  if (sum_item->get_arg_count() != 1 ||
      sum_item->get_arg(0)->type() != Item::FIELD_ITEM)
    return false;

  Item_field *field_item= 0;
  Item_param *low_param= 0;
  Item_param *high_param= 0;
  return split_field_param_between(select_lex->where, &field_item,
                                   &low_param, &high_param);
}

static bool supports_order_range_boundary(SELECT_LEX *select_lex)
{
  if (!select_lex || !select_lex->order_list.elements)
    return true;

  if (select_lex->order_list.elements != 1 ||
      select_lex->item_list.elements != 1)
    return false;

  ORDER *order= select_lex->order_list.first;
  if (!order || !order->item || !*order->item ||
      (*order->item)->type() != Item::FIELD_ITEM)
    return false;

  List_iterator_fast<Item> it(select_lex->item_list);
  Item *item= it++;
  if (!item || item->type() != Item::FIELD_ITEM ||
      !item->eq(*order->item, true))
    return false;

  Item_field *field_item= 0;
  Item_param *low_param= 0;
  Item_param *high_param= 0;
  return split_field_param_between(select_lex->where, &field_item,
                                   &low_param, &high_param);
}

static bool supports_distinct_order_range_boundary(SELECT_LEX *select_lex)
{
  if (!select_lex || !(select_lex->options & SELECT_DISTINCT))
    return true;

  if (!select_lex->order_list.elements)
    return false;

  return supports_order_range_boundary(select_lex);
}

static bool find_single_part_key(TABLE *table, Field *field, bool require_unique,
                                 uint *key_nr, KEY **key_info)
{
  if (!table || !table->s || !field || field->real_maybe_null() ||
      !key_nr || !key_info)
    return false;

  for (uint key= 0; key < table->s->keys; key++)
  {
    KEY *keyinfo= table->key_info + key;
    if (keyinfo->is_ignored ||
        (keyinfo->flags & HA_NULL_PART_KEY) ||
        (require_unique && !(keyinfo->flags & HA_NOSAME)) ||
        keyinfo->user_defined_key_parts != 1 ||
        !keyinfo->key_part)
      continue;

    if (keyinfo->key_part[0].fieldnr == field->field_index + 1)
    {
      *key_nr= key;
      *key_info= keyinfo;
      return true;
    }
  }
  return false;
}

static bool find_single_part_unique_key(TABLE *table, Field *field,
                                        uint *key_nr, KEY **key_info)
{
  return find_single_part_key(table, field, true, key_nr, key_info);
}

static bool find_single_part_ref_key(TABLE *table, Field *field,
                                     uint *key_nr, KEY **key_info)
{
  return find_single_part_key(table, field, false, key_nr, key_info);
}

static Access_recipe make_access_recipe(LEX *lex, SELECT_LEX *select_lex,
                                        JOIN *join)
{
  Access_recipe recipe= empty_access_recipe();
  TABLE *table= single_table(select_lex);
  Item *where= select_lex ? select_lex->where : 0;
  Item_field *field_item= 0;
  Item_param *param_item= 0;
  Item_param *high_param_item= 0;
  uint param_index= UINT_MAX;
  uint high_param_index= UINT_MAX;
  uint key_nr= MAX_KEY;
  KEY *keyinfo= 0;

  if (!where && join)
    where= join->conds;

  if (!table || !select_lex || !where)
    return recipe;

  if (split_field_param_eq(where, &field_item, &param_item))
  {
    if (!field_item->field || field_item->field->table != table)
      return recipe;

    if (!find_param_index(lex, param_item, &param_index))
      return recipe;

    if (param_item->null_value || param_item->has_no_value())
      return recipe;

    if (find_single_part_unique_key(table, field_item->field, &key_nr, &keyinfo))
      recipe.kind= Recipe_kind::UNIQUE_EQ_PARAM;
    else if (find_single_part_ref_key(table, field_item->field,
                                      &key_nr, &keyinfo))
      recipe.kind= Recipe_kind::REF_EQ_PARAM;
    else
      return recipe;
  }
  else if (split_field_param_between(where, &field_item, &param_item,
                                     &high_param_item))
  {
    if (!field_item->field || field_item->field->table != table)
      return recipe;

    if (!find_param_index(lex, param_item, &param_index) ||
        !find_param_index(lex, high_param_item, &high_param_index))
      return recipe;

    if (param_item->null_value || param_item->has_no_value() ||
        high_param_item->null_value || high_param_item->has_no_value())
      return recipe;

    if (find_single_part_ref_key(table, field_item->field, &key_nr, &keyinfo))
      recipe.kind= Recipe_kind::RANGE_BETWEEN_PARAM;
    else
      return recipe;
  }
  else
    return recipe;

  KEY_PART_INFO *key_part= keyinfo->key_part;
  recipe.key= key_nr;
  recipe.key_parts= keyinfo->user_defined_key_parts;
  recipe.key_flags= keyinfo->flags;
  recipe.fieldnr= key_part[0].fieldnr;
  recipe.field_length= key_part[0].length;
  recipe.field_type= field_item->field->type();
  recipe.field_charset= field_item->field->charset();
  recipe.param_index= param_index;
  recipe.high_param_index= high_param_index;
  recipe.param_item= param_item;
  recipe.high_param_item= high_param_item;
  recipe.param_signature= make_param_signature(param_item);
  recipe.high_param_signature= high_param_item ?
    make_param_signature(high_param_item) : recipe.high_param_signature;
  return recipe;
}

static const char *recipe_kind_name(Recipe_kind kind)
{
  switch (kind) {
  case Recipe_kind::NONE:
    return "none";
  case Recipe_kind::UNIQUE_EQ_PARAM:
    return "unique_eq_param";
  case Recipe_kind::REF_EQ_PARAM:
    return "ref_eq_param";
  case Recipe_kind::RANGE_BETWEEN_PARAM:
    return "range_between_param";
  }
  return "unknown";
}

static const char *invalidation_reason_name(Invalidation_reason reason)
{
  switch (reason) {
  case Invalidation_reason::NONE:
    return "none";
  case Invalidation_reason::DISABLED:
    return "disabled";
  case Invalidation_reason::NOT_ELIGIBLE:
    return "not_eligible";
  case Invalidation_reason::OPTIMIZER_SWITCH:
    return "optimizer_switch";
  case Invalidation_reason::CHARACTER_SET_CLIENT:
    return "character_set_client";
  case Invalidation_reason::TABLE_VERSION:
    return "table_version";
  case Invalidation_reason::TABLE_RECORDS:
    return "table_records";
  case Invalidation_reason::TABLE_RECORDS_REFRESH_FAILED:
    return "table_records_refresh_failed";
  case Invalidation_reason::PARAMETER_SHAPE:
    return "parameter_shape";
  case Invalidation_reason::ACCESS_SHAPE:
    return "access_shape";
  }
  return "unknown";
}

static Invalidation_reason validate_state(THD *thd, SELECT_LEX *select_lex,
                                          JOIN *join)
{
  DBUG_ASSERT(select_lex && select_lex->plan_cache_state);
  (void) join;

  if (!thd->variables.session_plan_cache)
    return Invalidation_reason::DISABLED;

  TABLE *table;
  if (!check_execute_eligibility(thd, select_lex, &table).candidate)
    return Invalidation_reason::NOT_ELIGIBLE;

  Cached_plan_state *state= select_lex->plan_cache_state;

  DBUG_ASSERT(table && table->s);

  if (state->optimizer_switch != thd->variables.optimizer_switch)
    return Invalidation_reason::OPTIMIZER_SWITCH;

  if (state->character_set_client != thd->variables.character_set_client)
    return Invalidation_reason::CHARACTER_SET_CLIENT;

  if (state->table_ref_version != table->s->get_table_ref_version())
    return Invalidation_reason::TABLE_VERSION;

  double records_change_ratio=
    thd->variables.session_plan_cache_allow_change_ratio;
  if (records_change_ratio > 0)
  {
    ha_rows table_records;
    if (!current_table_records(thd, table, &table_records))
      return Invalidation_reason::TABLE_RECORDS_REFRESH_FAILED;
    if (table_records_changed_sharply(state->table_records, table_records,
                                      records_change_ratio))
      return Invalidation_reason::TABLE_RECORDS;
  }

  if (!param_signatures_match(thd->lex, state->param_signatures))
    return Invalidation_reason::PARAMETER_SHAPE;

  return Invalidation_reason::NONE;
}

static Access_signature make_access_signature(JOIN *join)
{
  Access_signature signature;
  signature.table_count= join ? join->table_count : 0;
  signature.const_tables= join ? join->const_tables : 0;
  signature.top_join_tab_count= join ? join->top_join_tab_count : 0;
  signature.impossible_where= join ? join->impossible_where : false;
  signature.zero_result= join ? join->zero_result_cause != 0 : false;
  signature.join_type= JT_UNKNOWN;
  signature.ref_key= -1;
  signature.ref_key_parts= 0;
  signature.ref_key_length= 0;
  signature.ref_const_part_map= 0;
  signature.ref_null_rejecting= 0;
  signature.index= MAX_KEY;
  signature.use_quick= 0;
  signature.quick_type= -1;
  signature.quick_index= MAX_KEY;
  signature.quick_used_key_parts= 0;
  signature.quick_max_used_key_length= 0;
  signature.quick_records= 0;
  signature.quick_read_time= 0.0;
  signature.quick_mrr_flags= 0;
  signature.quick_mrr_buf_size= 0;

  if (!join || !join->join_tab || join->top_join_tab_count != 1)
    return signature;

  JOIN_TAB *tab= join->join_tab;
  signature.join_type= tab->type;
  signature.ref_key= tab->ref.key;
  signature.ref_key_parts= tab->ref.key_parts;
  signature.ref_key_length= tab->ref.key_length;
  signature.ref_const_part_map= tab->ref.const_ref_part_map;
  signature.ref_null_rejecting= tab->ref.null_rejecting;
  signature.index= tab->index;
  signature.use_quick= tab->use_quick;

  QUICK_SELECT_I *quick= tab->quick;
  if (!quick && tab->select)
    quick= tab->select->quick;
  if (quick)
  {
    signature.quick_type= quick->get_type();
    signature.quick_index= quick->index;
    signature.quick_used_key_parts= quick->used_key_parts;
    signature.quick_max_used_key_length= quick->max_used_key_length;
    signature.quick_records= quick->records;
    signature.quick_read_time= quick->read_time;
    if (quick->get_type() == QUICK_SELECT_I::QS_TYPE_RANGE)
    {
      QUICK_RANGE_SELECT *range_quick=
        static_cast<QUICK_RANGE_SELECT *>(quick);
      signature.quick_mrr_flags= range_quick->mrr_flags;
      signature.quick_mrr_buf_size= range_quick->get_mrr_buf_size();
    }
  }

  return signature;
}

static bool access_signature_allows_real_hit(const Cached_plan_state *state)
{
  if (!state || state->access_recipe.kind != Recipe_kind::UNIQUE_EQ_PARAM)
    return false;

  const Access_signature &signature= state->access_signature;
  const Access_recipe &recipe= state->access_recipe;
  return signature.table_count == 1 &&
         signature.const_tables == 1 &&
         signature.top_join_tab_count == 1 &&
         !signature.impossible_where &&
         !signature.zero_result &&
         signature.join_type == JT_CONST &&
         signature.ref_key == static_cast<int>(recipe.key) &&
         signature.ref_key_parts == recipe.key_parts &&
         signature.ref_const_part_map == 1 &&
         signature.use_quick == 0 &&
         signature.quick_type == -1;
}

static bool access_signature_allows_ref_hit(const Cached_plan_state *state)
{
  if (!state || state->access_recipe.kind != Recipe_kind::REF_EQ_PARAM)
    return false;

  const Access_signature &signature= state->access_signature;
  const Access_recipe &recipe= state->access_recipe;
  return signature.table_count == 1 &&
         signature.const_tables == 0 &&
         signature.top_join_tab_count == 1 &&
         !signature.impossible_where &&
         !signature.zero_result &&
         signature.join_type == JT_REF &&
         signature.ref_key == static_cast<int>(recipe.key) &&
         signature.ref_key_parts == recipe.key_parts &&
         signature.ref_const_part_map == 1 &&
         signature.use_quick == 0 &&
         signature.quick_type == -1;
}

static bool access_signature_allows_range_hit(const Cached_plan_state *state)
{
  if (!state || state->access_recipe.kind != Recipe_kind::RANGE_BETWEEN_PARAM)
    return false;

  const Access_signature &signature= state->access_signature;
  const Access_recipe &recipe= state->access_recipe;
  bool raw_range_type= signature.join_type == JT_RANGE ||
                       signature.join_type == JT_ALL;
  return signature.table_count == 1 &&
         signature.const_tables == 0 &&
         signature.top_join_tab_count == 1 &&
         !signature.impossible_where &&
         !signature.zero_result &&
         raw_range_type &&
         signature.ref_key == -1 &&
         (signature.use_quick == 0 || signature.use_quick == 1) &&
         signature.quick_type == QUICK_SELECT_I::QS_TYPE_RANGE &&
         signature.quick_index == recipe.key &&
         signature.quick_used_key_parts == recipe.key_parts;
}

static const Lex_select_limit *explicit_limit_params(SELECT_LEX *select_lex)
{
  if (!select_lex)
    return 0;

  if (select_lex->limit_params.explicit_limit)
    return &select_lex->limit_params;

  SELECT_LEX_UNIT *unit= select_lex->master_unit();
  SELECT_LEX *global= unit ? unit->global_parameters() : 0;
  if (global && global != select_lex && global->limit_params.explicit_limit)
    return &global->limit_params;

  return 0;
}

static bool supports_limit_boundary(SELECT_LEX *select_lex)
{
  const Lex_select_limit *limit_params= explicit_limit_params(select_lex);
  if (!limit_params)
    return true;

  Item *select_limit= limit_params->select_limit;
  Settable_routine_parameter *srp=
    select_limit ? select_limit->get_settable_routine_parameter() : 0;
  Item_param *limit_param= srp ? srp->get_item_param() : 0;

  if (!select_limit ||
      limit_params->offset_limit ||
      limit_params->is_fetch_first ||
      limit_params->with_ties ||
      (limit_param && limit_param->limit_clause_param) ||
      !select_limit->basic_const_item())
    return false;

  return select_limit->val_uint() == 1;
}

static bool supports_limit_recipe_boundary(LEX *lex, SELECT_LEX *select_lex)
{
  if (!explicit_limit_params(select_lex))
    return true;

  if (!supports_limit_boundary(select_lex))
    return false;

  Access_recipe recipe= make_access_recipe(lex, select_lex, 0);
  return recipe.kind == Recipe_kind::NONE ||
         recipe.kind == Recipe_kind::UNIQUE_EQ_PARAM;
}

const char *reason_name(Eligibility_reason reason)
{
  switch (reason) {
  case Eligibility_reason::CANDIDATE:
    return "candidate";
  case Eligibility_reason::DISABLED:
    return "disabled";
  case Eligibility_reason::NOT_PREPARED_STATEMENT:
    return "not_prepared_statement";
  case Eligibility_reason::NOT_SELECT:
    return "not_select";
  case Eligibility_reason::EXPLAIN_OR_ANALYZE:
    return "explain_or_analyze";
  case Eligibility_reason::NOT_TOP_LEVEL_SELECT:
    return "not_top_level_select";
  case Eligibility_reason::NOT_SINGLE_TABLE:
    return "not_single_table";
  case Eligibility_reason::NOT_BASE_TABLE:
    return "not_base_table";
  case Eligibility_reason::HAS_SET_OPERATION:
    return "has_set_operation";
  case Eligibility_reason::HAS_GROUP_ORDER_DISTINCT_OR_WINDOW:
    return "has_group_order_distinct_or_window";
  case Eligibility_reason::HAS_SUBQUERY:
    return "has_subquery";
  case Eligibility_reason::HAS_USER_VARIABLE:
    return "has_user_variable";
  case Eligibility_reason::HAS_LOCKING_CLAUSE:
    return "has_locking_clause";
  case Eligibility_reason::HAS_UNSUPPORTED_TABLE:
    return "has_unsupported_table";
  }
  return "unknown";
}

Eligibility check_eligibility(THD *thd, SELECT_LEX *select_lex, JOIN *join)
{
  if (!thd)
    return make_result(Eligibility_reason::NOT_PREPARED_STATEMENT);

  if (!thd->variables.session_plan_cache)
    return make_result(Eligibility_reason::DISABLED);

  if (!thd->stmt_arena ||
      thd->stmt_arena->type() != Query_arena::PREPARED_STATEMENT ||
      !thd->stmt_arena->is_stmt_execute())
    return make_result(Eligibility_reason::NOT_PREPARED_STATEMENT);

  if (!thd->lex || thd->lex->sql_command != SQLCOM_SELECT)
    return make_result(Eligibility_reason::NOT_SELECT);

  if (thd->lex->describe || thd->lex->analyze_stmt)
    return make_result(Eligibility_reason::EXPLAIN_OR_ANALYZE);

  if (!select_lex ||
      select_lex != thd->lex->first_select_lex() ||
      !select_lex->is_top_level_node() ||
      !thd->lex->is_single_level_stmt())
    return make_result(Eligibility_reason::NOT_TOP_LEVEL_SELECT);

  if (select_lex->is_part_of_union())
    return make_result(Eligibility_reason::HAS_SET_OPERATION);

  bool supports_sum_range= supports_sum_range_boundary(select_lex);
  bool supports_order_range= supports_order_range_boundary(select_lex);
  bool supports_distinct_order_range=
    supports_distinct_order_range_boundary(select_lex);
  if (((select_lex->options & SELECT_DISTINCT) &&
       !supports_distinct_order_range) ||
      (select_lex->options & OPTION_FOUND_ROWS) ||
      select_lex->group_list.elements ||
      (select_lex->order_list.elements && !supports_order_range) ||
      select_lex->having ||
      thd->lex->limit_rows_examined ||
      !supports_limit_recipe_boundary(thd->lex, select_lex) ||
      ((select_lex->with_sum_func ||
        select_lex->n_sum_items ||
        select_lex->n_child_sum_items) && !supports_sum_range) ||
      select_lex->have_window_funcs() ||
      select_lex->window_specs.elements ||
      select_lex->olap != UNSPECIFIED_OLAP_TYPE ||
      (join && join->group_list && !supports_distinct_order_range))
    return make_result(Eligibility_reason::HAS_GROUP_ORDER_DISTINCT_OR_WINDOW);

  if (select_lex->master_unit() &&
      (select_lex->master_unit()->is_unit_op() ||
       select_lex->master_unit()->first_select() != select_lex))
    return make_result(Eligibility_reason::HAS_SET_OPERATION);

  if (select_lex->leaf_tables.elements != 1 ||
      select_lex->table_list.elements != 1)
    return make_result(Eligibility_reason::NOT_SINGLE_TABLE);

  TABLE_LIST *table_list= select_lex->leaf_tables.head();
  if (!table_list)
    return make_result(Eligibility_reason::NOT_SINGLE_TABLE);

  if (table_list->placeholder() ||
      table_list->is_view_or_derived() ||
      table_list->belong_to_view ||
      table_list->belong_to_derived ||
      table_list->schema_table ||
      table_list->table_function ||
      table_list->sequence)
    return make_result(Eligibility_reason::NOT_BASE_TABLE);

  if (!table_list->table ||
      !table_list->table->s ||
      table_list->table->s->table_category != TABLE_CATEGORY_USER ||
      table_list->table->s->tmp_table != NO_TMP_TABLE)
    return make_result(Eligibility_reason::HAS_UNSUPPORTED_TABLE);

  if (select_lex->select_lock != st_select_lex::NONE)
    return make_result(Eligibility_reason::HAS_LOCKING_CLAUSE);

  if (thd->lex->set_var_list.elements)
    return make_result(Eligibility_reason::HAS_USER_VARIABLE);

  if (select_lex->uncacheable & UNCACHEABLE_SIDEEFFECT)
    return make_result(Eligibility_reason::HAS_USER_VARIABLE);

  if (select_lex->uncacheable & (UNCACHEABLE_DEPENDENT | UNCACHEABLE_RAND))
    return make_result(Eligibility_reason::HAS_SUBQUERY);

  if ((join && ((join->conds && join->conds->with_subquery()) ||
                (join->having && join->having->with_subquery()))) ||
      (select_lex->where && select_lex->where->with_subquery()) ||
      (select_lex->having && select_lex->having->with_subquery()))
    return make_result(Eligibility_reason::HAS_SUBQUERY);

  return make_result(Eligibility_reason::CANDIDATE);
}

static Eligibility check_execute_eligibility(THD *thd, SELECT_LEX *select_lex,
                                             TABLE **table_arg)
{
  if (table_arg)
    *table_arg= 0;

  if (!thd)
    return make_result(Eligibility_reason::NOT_PREPARED_STATEMENT);

  if (!thd->variables.session_plan_cache)
    return make_result(Eligibility_reason::DISABLED);

  if (!thd->stmt_arena ||
      thd->stmt_arena->type() != Query_arena::PREPARED_STATEMENT ||
      !thd->stmt_arena->is_stmt_execute())
    return make_result(Eligibility_reason::NOT_PREPARED_STATEMENT);

  if (!thd->lex || thd->lex->sql_command != SQLCOM_SELECT)
    return make_result(Eligibility_reason::NOT_SELECT);

  if (thd->lex->describe || thd->lex->analyze_stmt)
    return make_result(Eligibility_reason::EXPLAIN_OR_ANALYZE);

  if (!select_lex ||
      select_lex != thd->lex->first_select_lex() ||
      !select_lex->is_top_level_node() ||
      !thd->lex->is_single_level_stmt())
    return make_result(Eligibility_reason::NOT_TOP_LEVEL_SELECT);

  TABLE *table= single_table(select_lex);
  if (!table || !table->s)
    return make_result(Eligibility_reason::NOT_SINGLE_TABLE);

  if (table->s->table_category != TABLE_CATEGORY_USER ||
      table->s->tmp_table != NO_TMP_TABLE)
    return make_result(Eligibility_reason::HAS_UNSUPPORTED_TABLE);

  if (table_arg)
    *table_arg= table;
  return make_result(Eligibility_reason::CANDIDATE);
}

void trace_eligibility(THD *, const Eligibility &eligibility)
{
  DBUG_PRINT("plan_cache",
             ("eligibility=%s candidate=%d",
              reason_name(eligibility.reason), eligibility.candidate));
}

Execute_validation validate_state_for_execute(THD *thd, SELECT_LEX *select_lex,
                                              JOIN *join)
{
  if (!thd || !select_lex ||
      select_lex->plan_cache_state_status == State::UNCACHEABLE)
    return make_execute_validation(false, false, false);

  if (!select_lex->plan_cache_state)
  {
    if (select_lex->plan_cache_state_status == State::READY)
      select_lex->plan_cache_state_status= State::NONE;
    else if (select_lex->plan_cache_state_status == State::NONE)
      capture_pending_access_recipe(thd, select_lex);
    return make_execute_validation(false, false, false);
  }

  ulonglong profile_timer= profile_start(thd);
  Invalidation_reason reason= validate_state(thd, select_lex, join);
  profile_add(thd, profile_timer,
              &thd->status_var.cached_plan_profile_validate_us);
  if (reason == Invalidation_reason::NONE)
  {
    profile_timer= profile_start(thd);
    Cached_plan_state *state= select_lex->plan_cache_state;
    bool recipe_prevalidated= state->access_recipe.kind != Recipe_kind::NONE;
    if (recipe_prevalidated)
    {
      status_var_increment(thd->status_var.cached_plan_prevalidations);
      DBUG_PRINT("plan_cache",
                 ("prevalidate recipe select_lex=%p cached=%s matched=1",
                  select_lex, recipe_kind_name(state->access_recipe.kind)));
    }
    profile_add(thd, profile_timer,
                &thd->status_var.cached_plan_profile_prevalidate_us);
    return make_execute_validation(true, false, recipe_prevalidated);
  }

  DBUG_PRINT("plan_cache",
             ("invalidate state select_lex=%p reason=%s",
              select_lex, invalidation_reason_name(reason)));
  destroy_state(thd, select_lex,
                reason != Invalidation_reason::DISABLED &&
                reason != Invalidation_reason::NOT_ELIGIBLE);
  if (reason == Invalidation_reason::NOT_ELIGIBLE)
    mark_uncacheable(select_lex);
  else if (reason == Invalidation_reason::TABLE_RECORDS_REFRESH_FAILED)
    capture_pending_access_recipe(thd, select_lex);
  return make_execute_validation(true, true, false);
}

Execute_recipe_result
try_execute_cached_recipe(THD *thd, SELECT_LEX *select_lex, JOIN *join,
                          const Execute_validation &validation)
{
  ulonglong hit_path_timer= profile_start(thd);
  if (!validation.had_state || validation.invalidated ||
      !validation.recipe_prevalidated)
  {
    profile_add(thd, hit_path_timer,
                &thd->status_var.cached_plan_profile_hit_path_us);
    return Execute_recipe_result::FALLBACK;
  }

  Cached_plan_state *state= select_lex->plan_cache_state;

  if (access_signature_allows_real_hit(state))
  {
    DBUG_EXECUTE_IF("session_plan_cache_hit_path_fail",
    {
      DBUG_PRINT("plan_cache",
                 ("debug fallback before unique equality recipe hit "
                  "select_lex=%p", select_lex));
      profile_add(thd, hit_path_timer,
                  &thd->status_var.cached_plan_profile_hit_path_us);
      return Execute_recipe_result::FALLBACK;
    });

    DBUG_EXECUTE_IF("session_plan_cache_const_lookup_fail",
    {
      DBUG_PRINT("plan_cache",
                 ("debug const lookup fallback select_lex=%p", select_lex));
      profile_add(thd, hit_path_timer,
                  &thd->status_var.cached_plan_profile_hit_path_us);
      return Execute_recipe_result::FALLBACK;
    });

    /*
      Execute unique equality hits through the ref shape.  The old const-table
      shape reads the row while building the hit plan, which is expensive on
      every execute.  The ref shape preserves one-key lookup semantics and lets
      the normal executor perform the row read.
    */
    ulonglong build_timer= profile_start(thd);
    bool built= build_ref_eq_lookup_plan(
        thd, select_lex, join, state->access_recipe.key,
        state->access_recipe.param_item,
        &thd->status_var.cached_plan_profile_hit_unique_alloc_us,
        &thd->status_var.cached_plan_profile_hit_unique_setup_plan_us);
    ulonglong build_delta= profile_elapsed(build_timer);
    profile_add_delta(build_delta,
                      &thd->status_var.cached_plan_profile_hit_build_us);
    profile_add_delta(build_delta,
                      &thd->status_var.cached_plan_profile_hit_unique_build_us);
    if (!built)
    {
      DBUG_PRINT("plan_cache",
                 ("unique equality recipe hit path fallback select_lex=%p",
                  select_lex));
      profile_add(thd, hit_path_timer,
                  &thd->status_var.cached_plan_profile_hit_path_us);
      return thd->is_error() ? Execute_recipe_result::ERROR :
                               Execute_recipe_result::FALLBACK;
    }

    status_var_increment(thd->status_var.cached_plan_hits);
    if (profile_enabled(thd))
      status_var_increment(thd->status_var.cached_plan_profile_hit_unique_count);
    DBUG_PRINT("plan_cache",
               ("unique equality recipe hit select_lex=%p", select_lex));
    profile_add(thd, hit_path_timer,
                &thd->status_var.cached_plan_profile_hit_path_us);
    return Execute_recipe_result::HIT;
  }

  if (access_signature_allows_ref_hit(state))
  {
    DBUG_EXECUTE_IF("session_plan_cache_hit_path_fail",
    {
      DBUG_PRINT("plan_cache",
                 ("debug fallback before ref equality recipe hit "
                  "select_lex=%p", select_lex));
      profile_add(thd, hit_path_timer,
                  &thd->status_var.cached_plan_profile_hit_path_us);
      return Execute_recipe_result::FALLBACK;
    });

    ulonglong build_timer= profile_start(thd);
    bool built= build_ref_eq_lookup_plan(
        thd, select_lex, join, state->access_recipe.key,
        state->access_recipe.param_item,
        &thd->status_var.cached_plan_profile_hit_ref_alloc_us,
        &thd->status_var.cached_plan_profile_hit_ref_setup_us);
    ulonglong build_delta= profile_elapsed(build_timer);
    profile_add_delta(build_delta,
                      &thd->status_var.cached_plan_profile_hit_build_us);
    profile_add_delta(build_delta,
                      &thd->status_var.cached_plan_profile_hit_ref_build_us);
    if (!built)
    {
      DBUG_PRINT("plan_cache",
                 ("ref equality recipe hit path fallback select_lex=%p",
                  select_lex));
      profile_add(thd, hit_path_timer,
                  &thd->status_var.cached_plan_profile_hit_path_us);
      return thd->is_error() ? Execute_recipe_result::ERROR :
                               Execute_recipe_result::FALLBACK;
    }

    status_var_increment(thd->status_var.cached_plan_hits);
    if (profile_enabled(thd))
      status_var_increment(thd->status_var.cached_plan_profile_hit_ref_count);
    DBUG_PRINT("plan_cache",
               ("ref equality recipe hit select_lex=%p", select_lex));
    profile_add(thd, hit_path_timer,
                &thd->status_var.cached_plan_profile_hit_path_us);
    return Execute_recipe_result::HIT;
  }

  if (access_signature_allows_range_hit(state))
  {
    DBUG_EXECUTE_IF("session_plan_cache_hit_path_fail",
    {
      DBUG_PRINT("plan_cache",
                 ("debug fallback before range between recipe hit "
                  "select_lex=%p", select_lex));
      profile_add(thd, hit_path_timer,
                  &thd->status_var.cached_plan_profile_hit_path_us);
      return Execute_recipe_result::FALLBACK;
    });

    ulonglong build_timer= profile_start(thd);
    bool built= build_range_between_lookup_plan(
        thd, select_lex, join, state->access_recipe.key,
        state->access_recipe.fieldnr,
        state->access_recipe.param_item,
        state->access_recipe.high_param_item,
        state->access_signature.quick_records,
        state->access_signature.quick_read_time,
        state->access_signature.quick_mrr_flags,
        state->access_signature.quick_mrr_buf_size);
    ulonglong build_delta= profile_elapsed(build_timer);
    profile_add_delta(build_delta,
                      &thd->status_var.cached_plan_profile_hit_build_us);
    profile_add_delta(build_delta,
                      &thd->status_var.cached_plan_profile_hit_range_build_us);
    if (!built)
    {
      DBUG_PRINT("plan_cache",
                 ("range between recipe hit path fallback select_lex=%p",
                  select_lex));
      profile_add(thd, hit_path_timer,
                  &thd->status_var.cached_plan_profile_hit_path_us);
      return thd->is_error() ? Execute_recipe_result::ERROR :
                               Execute_recipe_result::FALLBACK;
    }

    status_var_increment(thd->status_var.cached_plan_hits);
    if (profile_enabled(thd))
      status_var_increment(thd->status_var.cached_plan_profile_hit_range_count);
    DBUG_PRINT("plan_cache",
               ("range between recipe hit select_lex=%p", select_lex));
    profile_add(thd, hit_path_timer,
                &thd->status_var.cached_plan_profile_hit_path_us);
    return Execute_recipe_result::HIT;
  }

  profile_add(thd, hit_path_timer,
              &thd->status_var.cached_plan_profile_hit_path_us);
  return Execute_recipe_result::FALLBACK;
}

void maybe_create_state(THD *thd, SELECT_LEX *select_lex, JOIN *join)
{
  if (!select_lex ||
      select_lex->plan_cache_state_status == State::UNCACHEABLE)
    return;

  Eligibility eligibility= check_eligibility(thd, select_lex, join);

  if (!eligibility.candidate)
  {
    clear_pending_access_recipe(select_lex);
    if (permanently_uncacheable(eligibility.reason))
      mark_uncacheable(select_lex);
    return;
  }

  if (select_lex->plan_cache_state)
  {
    Access_signature current_access= make_access_signature(join);
    if (!(select_lex->plan_cache_state->access_signature == current_access))
    {
      DBUG_PRINT("plan_cache",
                 ("invalidate state select_lex=%p reason=%s",
                  select_lex,
                  invalidation_reason_name(Invalidation_reason::ACCESS_SHAPE)));
      destroy_state(thd, select_lex, true);
    }
    else
    {
      select_lex->plan_cache_state_status= State::READY;
      return;
    }
  }

  if (select_lex->plan_cache_state_status == State::UNCACHEABLE)
    return;

  TABLE *table= single_table(select_lex);
  if (!table || !table->s)
  {
    clear_pending_access_recipe(select_lex);
    return;
  }

  Access_recipe access_recipe= consume_pending_access_recipe(select_lex);
  if (access_recipe.kind == Recipe_kind::NONE)
    access_recipe= make_access_recipe(thd->lex, select_lex, join);
  if (explicit_limit_params(select_lex) &&
      access_recipe.kind != Recipe_kind::UNIQUE_EQ_PARAM)
  {
    DBUG_PRINT("plan_cache",
               ("skip state for non-unique LIMIT recipe select_lex=%p "
                "recipe=%s",
                select_lex, recipe_kind_name(access_recipe.kind)));
    return;
  }
  if (access_recipe.kind == Recipe_kind::NONE)
  {
    DBUG_PRINT("plan_cache",
               ("skip state without access recipe select_lex=%p",
                select_lex));
    return;
  }

  DBUG_EXECUTE_IF("session_plan_cache_state_alloc_fail",
  {
    DBUG_PRINT("plan_cache",
               ("debug skip state allocation select_lex=%p", select_lex));
    return;
  });

  select_lex->plan_cache_state= new (std::nothrow)
    Cached_plan_state(thd, table, select_lex, join, access_recipe);
  if (!select_lex->plan_cache_state)
    return;
  if (!select_lex->plan_cache_state->init(thd))
  {
    delete select_lex->plan_cache_state;
    select_lex->plan_cache_state= 0;
    return;
  }

  cached_plan_live_count.fetch_add(1, std::memory_order_relaxed);
  select_lex->plan_cache_state_status= State::READY;
  DBUG_PRINT("plan_cache", ("created state select_lex=%p", select_lex));
}

ulong live_state_count()
{
  return cached_plan_live_count.load(std::memory_order_relaxed);
}

void invalidate_for_reprepare(THD *thd, LEX *lex)
{
  DBUG_PRINT("plan_cache", ("invalidate_for_reprepare lex=%p", lex));
  if (lex)
    destroy_state(thd, lex->first_select_lex(),
                  thd && thd->variables.session_plan_cache);
}

void destroy_for_deallocate(THD *thd, LEX *lex)
{
  DBUG_PRINT("plan_cache", ("destroy_for_deallocate lex=%p", lex));
  if (lex)
    destroy_state(thd, lex->first_select_lex(), false);
}

} // namespace plan_cache
