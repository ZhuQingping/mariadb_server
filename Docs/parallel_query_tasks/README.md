# MariaDB Parallel Query Prototype

This directory contains the review-facing material for the MariaDB Parallel
Query prototype. It is intentionally small and excludes historical task logs,
agent prompts, and day-by-day development notes.

The current branch is a staged prototype, not a complete Parallel Query
implementation. The supported demonstration scope is:

- TPC-H Q6-style single-table scan, filter, and scalar aggregation.
- TPC-H Q1-style constrained single-table grouped aggregation.
- Worker-side scan/filter/partial aggregation.
- Leader-side result merge and finalization.
- Explicit fallback for unsupported query shapes.
- MariaDB traditional and JSON EXPLAIN visibility for supported paths.

Review documents:

- `parallel-query-high-level-design.md`: scope, user-visible behavior,
  execution model, and non-goals.
- `parallel-query-low-level-design.md`: SQL, handler, and InnoDB boundaries.
- `parallel-query-performance.md`: local TPC-H SF10 Q1/Q6 release-build
  measurements and interpretation.
- `parallel-query-roadmap.md`: staged follow-up work and refactoring plan.

The performance numbers are local engineering evidence only. They are useful
for judging whether the prototype exercises real parallel execution, but they
are not official MariaDB benchmark results.
