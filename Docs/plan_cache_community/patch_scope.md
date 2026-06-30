# Patch Scope and Review Plan

## Recommended Patch Series

The current branch is useful for local integration, but it should be reshaped
before a community PR. Recommended review units:

1. **Infrastructure**
   - system variables;
   - status variables;
   - `SELECT_LEX` cached-state lifecycle;
   - no real hit path yet or only disabled scaffolding.

2. **Eligibility and lifecycle**
   - prepared `SELECT` only;
   - one top-level user table;
   - deallocate, reprepare, disconnect, `COM_CHANGE_USER`;
   - no-op and fail-closed MTR coverage.

3. **Unique equality recipe**
   - `UNIQUE_EQ_PARAM`;
   - literal `LIMIT 1` only under this recipe;
   - DDL, parameter-shape, charset, optimizer-switch invalidation.

4. **Ref/range recipes**
   - `REF_EQ_PARAM`;
   - `RANGE_BETWEEN_PARAM`;
   - sysbench point-secondary and simple range MTR coverage.

5. **Sysbench read-only upper-state recipes**
   - narrow `SUM(field)`;
   - narrow `ORDER BY` range;
   - narrow `DISTINCT ORDER BY` range;
   - debug fault-injection coverage for upper-state setup failures.

6. **Community evidence package**
   - design proposal;
   - known limitations;
   - invalidation matrix;
   - test report;
   - benchmark report.

## Files That Should Stay Together

- `sql/sql_plan_cache.cc` and `sql/sql_plan_cache.h` should be reviewed with
  the corresponding `sql/sql_select.cc` hook changes.
- Each supported SQL recipe should be committed with its MTR test and result
  file.
- Community documentation should be kept in a separate commit so reviewers can
  inspect the design without reading mechanical test-result churn.

## Files To Avoid In Community PRs

- Development-only phase logs unless explicitly useful.
- Local build directory notes.
- Generated logs or temporary benchmark data.
- Unrelated workspace state such as `storage/duckdb/third_parties/duckdb`.

## Current Branch Status

The local branch is integration-oriented. It already contains multiple small
commits for the feature phases. Before opening a PR, consider squashing or
reordering into the review units above.
