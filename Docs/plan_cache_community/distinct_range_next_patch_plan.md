# DISTINCT Range Next Patch Plan

## Purpose

This note narrows the next possible performance patch for the sysbench
`distinct_range` shape. It is not approval to code the patch now. The coding
gate remains Linux CPU-set release evidence showing that this shape is a
stable blocker.

Target shape:

```sql
SELECT DISTINCT c
FROM sbtestN
WHERE id BETWEEN ? AND ?
ORDER BY c
```

Current short profile signal:

| Counter | 1 thread us/hit | 4 threads us/hit | Interpretation |
|---|---:|---:|---|
| range build | 0.630 | 0.789 | broad range-hit construction cost |
| range setup | 0.447 | 0.477 | execution-state setup remains visible |
| setup post | 0.144 | 0.147 | stable exact-shape candidate |
| setup alloc | 0.100 | 0.115 | stable but allocation-sensitive |
| setup distinct | 0.053 | 0.053 | too small to optimize alone |
| hit explain | 0.263 | 0.237 | stable exact-shape candidate, high risk |

## Current Code Path

The hit path enters `build_range_between_lookup_plan()` in `sql/sql_select.cc`.

The DISTINCT-specific early setup already does useful work before post setup:

- `plan_cache_distinct_range_uses_single_access_tab()` rejects broad DISTINCT
  cases and storage engines with `create_group_by` handlers.
- `create_plan_cache_single_distinct_group()` avoids the generic
  `create_distinct_group()` path for the exact one-field ORDER/DISTINCT shape.
- `count_field_types()` and `calc_group_buffer()` still run per hit.
- The code sets `join->group_list`, `join->group`, `join->simple_group`,
  `join->sort_and_group`, `join->send_group_parts`, and clears temporary field
  lists before entering post setup.

Post setup then calls:

```text
join->setup_plan_cache_aggr_tables_info()
  -> JOIN::make_aggr_tables_info()
```

This generic function handles many cases that the exact sysbench shape has
already ruled out: storage-engine group-by pushdown, temporary tables, HAVING,
window functions, multiple aggregation tables, group field allocation, filesort
attachment, item ref array changes, and tracker wiring.

Explain setup currently goes through `JOIN::build_plan_cache_hit_explain()`.
That lightweight path deliberately returns fallback for grouped or DISTINCT
plans:

```text
need_tmp || group || group_list || select_distinct
```

So the exact DISTINCT range shape still pays full `build_explain()` cost.

## Candidate Patch A: Exact DISTINCT Range Post Setup

Add a new exact-shape helper, for example:

```text
JOIN::setup_plan_cache_distinct_range_aggr_tables_info()
```

It should only run when all of these are true:

- `plan_cache_distinct_range_uses_single_access_tab()` accepted the shape.
- `top_join_tab_count == 1` and `aggr_tables == 0`.
- `need_tmp == false`.
- `group == true`, `group_list != nullptr`, `order == nullptr`,
  `select_distinct == false`, `simple_group == true`,
  `sort_and_group == true`.
- no HAVING, no procedure, no rollup, no window functions, no derived/pushdown.
- storage engine `create_group_by` was already rejected.

The helper may then do the minimal work that the exact shape needs:

- ensure the single access tab exposes `fields` and `all_fields`;
- keep `items0` as the active ref array unless a proven execution path needs a
  new slice;
- attach grouping/filesort metadata equivalent to the generic path;
- call only the group-field or filesort setup that is required by this exact
  shape;
- return false to the existing generic fallback on any mismatch.

Risk:

- `make_aggr_tables_info()` is broad and has many side effects. The patch must
  not copy a partial subset by inspection only.
- Filesort/tracker initialization is observable through execution,
  EXPLAIN/ANALYZE, and slow-query explain paths.
- MTR must include normal result correctness, EXPLAIN/ANALYZE fallback, debug
  fault fallback, and at least one storage-engine group-by rejection case.

Expected upside:

- Direct target is `setup_post ~= 0.145 us/hit`.
- It may also reduce some explain/tracker setup if it simplifies the state that
  later `build_explain()` sees, but that is not guaranteed.

## Candidate Patch B: DISTINCT-Aware Lightweight Explain

Extend `JOIN::build_plan_cache_hit_explain()` only for the exact DISTINCT range
shape after Candidate A or equivalent state audit proves the grouped plan state
is minimal and tracker-safe.

Possible boundary:

- one access tab;
- no temp table;
- grouped by the access table's single output field;
- no EXPLAIN/ANALYZE, no slow-query explain/engine verbosity, no subquery,
  no derived, no pushdown;
- filesort tracker object is created when the access tab owns filesort.

Risk:

- This is higher risk than Candidate A. `build_explain()` creates execution-time
  tracker objects, not just user-visible EXPLAIN rows.
- Skipping it broadly has already been rejected by MTR in earlier experiments.

Expected upside:

- Direct target is `hit_explain ~= 0.24-0.26 us/hit`.
- This should not be attempted unless `hit_explain` dominates a stable Linux
  regression or fixed-rate efficiency miss.

## Do Not Start With

- Generic DISTINCT/GROUP BY optimization.
- Reusing a complete `QUICK_RANGE_SELECT` or `SQL_SELECT` across executions.
- Skipping `build_explain()` for all plan-cache hits.
- Optimizing `create_plan_cache_single_distinct_group()` alone; its measured
  `setup_distinct` cost is only about `0.053 us/hit`.
- Parameter validation shortcuts; validation is not the current DISTINCT
  hotspot.

## Required Evidence Before Coding

1. Linux CPU-set release shape benchmark shows `distinct_range` is weak,
   negative, or CPU/kQPS inefficient by median.
2. ON runs have `Cached_plan_hits` growth, live plan count, and zero
   invalidations.
3. `compare_profile_status.py` or `profile_status_analysis.md` still shows
   `setup_post`, `setup_alloc`, or `hit_explain` above `0.10 us/hit`.
4. A focused MTR plan is written before implementation.
5. The first patch changes only one of Candidate A or Candidate B, not both.

## Existing MTR Coverage

Current focused tests already cover the basic exact shape and several rollback
boundaries:

- `main.session_plan_cache_sysbench_coverage` verifies that
  `SELECT DISTINCT c FROM sbtest1 WHERE id BETWEEN ? AND ? ORDER BY c` creates
  one cached state, produces repeated hits, records prevalidations, and releases
  the state on deallocate.
- The same test verifies that the `LIMIT 1` variants for ref/range/order/
  distinct remain outside the current sysbench recipe boundary.
- `main.session_plan_cache_debug_fault_injection` verifies fallback/recovery for
  `session_plan_cache_distinct_range_setup_fail`,
  `session_plan_cache_distinct_range_group_fail`, and
  `session_plan_cache_distinct_range_aggr_setup_fail`.
- `main.session_plan_cache_explain_analyze_boundary` verifies that prepared
  `EXPLAIN SELECT` and prepared `ANALYZE SELECT` do not create plan-cache state.
- `main.session_plan_cache_distinct_range_result` verifies result equivalence
  across different `BETWEEN` ranges with duplicate `c` values, proving DISTINCT
  and ORDER BY are preserved on the first execution and subsequent hits. It
  also directly checks that the second and third executions are real hits with
  no invalidations.
- `main.session_plan_cache_distinct_range_boundary` verifies that non-exact
  DISTINCT range shapes remain fail-closed for an extra selected column,
  explicit GROUP BY, HAVING, a window function, and aggregate GROUP BY.
- `main.session_plan_cache_distinct_range_profile` verifies normal execution
  after exact DISTINCT range hits with `session_plan_cache_profile=ON`, and
  checks that range hit, post setup, and hit explain profile counters grow.

## Missing MTR Coverage Before Candidate A

Before implementing exact DISTINCT range post setup, add or extend focused MTR
coverage for:

- debug fallback for the new helper before it mutates JOIN state, analogous to
  the existing setup/group fault hooks;
- EXPLAIN/ANALYZE or slow-explain safety if the helper changes any state later
  consumed by `build_explain()`.

## Missing MTR Coverage Before Candidate B

Before changing `JOIN::build_plan_cache_hit_explain()` for DISTINCT, add or
extend focused MTR coverage for:

- `EXPLAIN` / `ANALYZE` boundary behavior remains uncached and unchanged;
- slow-query explain/engine verbosity still falls back to full `build_explain()`;
- a grouped/DISTINCT boundary case outside the exact sysbench shape still uses
  full explain construction;
- debug fault injection for lightweight explain allocation failure, if a new
  allocation path is added.
