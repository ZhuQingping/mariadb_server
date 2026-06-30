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

#ifndef SQL_PLAN_CACHE_INCLUDED
#define SQL_PLAN_CACHE_INCLUDED

class JOIN;
class THD;
class Item_param;
struct LEX;
typedef class st_select_lex SELECT_LEX;

namespace plan_cache
{

struct Cached_plan_state;

enum class Eligibility_reason
{
  CANDIDATE,
  DISABLED,
  NOT_PREPARED_STATEMENT,
  NOT_SELECT,
  EXPLAIN_OR_ANALYZE,
  NOT_TOP_LEVEL_SELECT,
  NOT_SINGLE_TABLE,
  NOT_BASE_TABLE,
  HAS_SET_OPERATION,
  HAS_GROUP_ORDER_DISTINCT_OR_WINDOW,
  HAS_SUBQUERY,
  HAS_USER_VARIABLE,
  HAS_LOCKING_CLAUSE,
  HAS_UNSUPPORTED_TABLE
};

struct Eligibility
{
  bool candidate;
  Eligibility_reason reason;
};

struct Execute_validation
{
  bool had_state;
  bool invalidated;
  bool recipe_prevalidated;
};

enum class Execute_recipe_result
{
  FALLBACK,
  HIT,
  ERROR
};

const char *reason_name(Eligibility_reason reason);
Eligibility check_eligibility(THD *thd, SELECT_LEX *select_lex, JOIN *join);
void trace_eligibility(THD *thd, const Eligibility &eligibility);
Execute_validation validate_state_for_execute(THD *thd, SELECT_LEX *select_lex,
                                              JOIN *join);
Execute_recipe_result
try_execute_cached_recipe(THD *thd, SELECT_LEX *select_lex, JOIN *join,
                          const Execute_validation &validation);
bool build_unique_eq_const_lookup_plan(THD *thd, SELECT_LEX *select_lex,
                                       JOIN *join, uint key_nr,
                                       Item_param *param_item);
bool build_ref_eq_lookup_plan(THD *thd, SELECT_LEX *select_lex, JOIN *join,
                              uint key_nr, Item_param *param_item,
                              ulonglong *alloc_counter,
                              ulonglong *setup_counter);
bool build_range_between_lookup_plan(THD *thd, SELECT_LEX *select_lex,
                                     JOIN *join, uint key_nr,
                                     field_index_t fieldnr,
                                     Item_param *low_param,
                                     Item_param *high_param,
                                     ha_rows quick_records,
                                     double quick_read_time,
                                     uint quick_mrr_flags,
                                     uint quick_mrr_buf_size);
void maybe_create_state(THD *thd, SELECT_LEX *select_lex, JOIN *join);
void invalidate_for_reprepare(THD *thd, LEX *lex);
void destroy_for_deallocate(THD *thd, LEX *lex);
ulong live_state_count();

} // namespace plan_cache

#endif
