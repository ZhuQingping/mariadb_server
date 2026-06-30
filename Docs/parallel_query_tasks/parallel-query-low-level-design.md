# Parallel Query Low-Level Design

## Main Boundaries

The prototype touches three main layers:

- SQL execution and result merge: `sql/sql_select.cc`
- Handler contract and scan descriptor API: `sql/handler.h`
- First InnoDB provider hooks:
  `storage/innobase/handler/ha_innodb.*`,
  `storage/innobase/read/read0read.cc`, and
  `storage/innobase/row/row0sel.cc`

Control and observability surfaces are in:

- hints: `sql/opt_hints.*`
- sysvars: `sql/sys_vars.cc`
- status/logging/trace: `sql/mysqld.*`, `sql/log.cc`, `sql/opt_trace.*`
- EXPLAIN output: `sql/sql_explain.*`

## Admission

The SQL layer admits only bounded single-table shapes. The checks reject
unsupported joins, subqueries, write-select forms, unsafe grouped expressions,
unsupported isolation or locking combinations, and query shapes that cannot be
merged by the current leader.

Fallback is intentional behavior. The prototype should return serial results
for unsupported shapes instead of trying to execute a partially parallel plan.

## Worker Lifecycle

The leader owns worker admission, thread creation, cancellation, and final
cleanup. Workers open independent table instances and do not share the leader
handler or table object.

The worker path is responsible for:

- opening the target table;
- attaching the leader statement snapshot;
- scanning assigned ranges;
- applying supported predicates;
- building scalar, grouped, count, or projection partial results;
- reporting errors and cancellation state to the leader.

The leader is responsible for:

- deciding final success or fallback behavior;
- joining workers;
- freeing worker state;
- merging partial results;
- sending the final result through the normal executor result path.

## MVCC Boundary

Workers use the leader statement snapshot instead of creating an independent
read view. This is required for statement-level consistency across worker
threads.

The current focused MTR coverage includes Q1/Q6 snapshot behavior under
REPEATABLE READ and READ COMMITTED scenarios. This remains a key review area
because it is part of the correctness boundary, not only an optimization.

## Scan Provider Boundary

The first provider is intentionally conservative. It supports the current
Q1/Q6 demonstration through clustered primary-key oriented range splitting and
row-buffer scan handoff.

The prototype can show a gather plan even when the underlying table access is
`type=ALL`. For Q6 on the SF10 standard model used in the local benchmark,
there is no secondary index on `l_shipdate`, so workers still perform
predicate filtering during scan.

## Refactoring Notes

The current code is a prototype. Before a formal upstream merge request, the
largest SQL-layer helpers should be split into smaller functions or dedicated
source files. The immediate refactoring targets are:

- extract worker lifecycle helpers out of `sql/sql_select.cc`;
- extract scalar aggregate and grouped aggregate merge helpers;
- isolate scan descriptor construction and fallback diagnostics;
- keep comments in the surrounding MariaDB style and avoid unrelated comment
  format churn;
- reduce invasive edits around existing executor code.

These refactors should be made in reviewable slices with focused MTR after
each slice.
