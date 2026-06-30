# Community Design Proposal: Session Plan Cache

## Summary

This proposal introduces a default-off, session-level plan cache for prepared
single-table `SELECT` statements in MariaDB. The current implementation targets
high-frequency OLTP prepared statements and uses a conservative access-recipe
rebuild model instead of caching and restoring a full `JOIN` tree.

The design is informed by broader prior MySQL plan-cache work, but the first
MariaDB stage is deliberately narrower to reduce wrong-result and memory
lifetime risk during community review.

## Motivation

Prepared statements still run optimizer work on every `EXECUTE`. For OLTP
workloads that repeatedly execute the same statement shape with different
parameter values, that optimizer work can become visible CPU overhead.

The primary value cases are:

- sysbench `point_selects` and `point_selects --secondary`;
- simple indexed range lookups;
- sysbench read-only aggregate/order/distinct range templates;
- application workloads with repeated single-table prepared `SELECT` access.

## Public Scope

The first community stage should be described as:

- cache state is per prepared statement and per session;
- prepared statements only;
- `SELECT` only;
- one top-level query block;
- one user base table;
- default off through `session_plan_cache`;
- `session_plan_cache` has session scope and can also be set globally as the
  default for new sessions;
- no cross-session sharing;
- no full plan object reuse.

Supported executable recipes:

| Recipe | Shape |
|---|---|
| `UNIQUE_EQ_PARAM` | `field = ?` or `? = field` on a non-null single-column unique key |
| `REF_EQ_PARAM` | `field = ?` or `? = field` on a non-null single-column indexed key |
| `RANGE_BETWEEN_PARAM` | `field BETWEEN ? AND ?` on a non-null single-column indexed key |
| Sysbench `SUM` range | `SELECT SUM(field) ... WHERE indexed_field BETWEEN ? AND ?` |
| Sysbench `ORDER BY` range | one selected field, matching one `ORDER BY` field |
| Sysbench `DISTINCT ORDER BY` range | one selected field, `DISTINCT`, matching one `ORDER BY` field |

Literal `LIMIT 1` is supported only for the unique-equality recipe. It remains
fail-closed for ref/range/order/distinct recipes.

## Architecture

The MariaDB implementation stores a compact declarative recipe and validation
signature in `SELECT_LEX`, then rebuilds the executable access state on a cache
hit.

Key properties:

- The cached state does not retain handler runtime objects or old optimizer
  runtime structures.
- Each hit reconstructs the `JOIN_TAB`, ref/range buffers, quick range access,
  and the narrow upper executor state needed by supported recipes.
- If validation fails, the cached state is invalidated or the execution falls
  back to normal optimization.
- If a failure happens after the rebuilt `JOIN` has been committed for DISTINCT
  upper setup, the hit reports an error instead of falling back through a
  partially mutated `JOIN`.

This differs from broader full-plan-cache designs, which cache and reapply a
full `JOIN`/`Exec_context` and have broad Item clone/rebinding logic.

## Validation Model

Before a hit can be used, the implementation checks:

- feature variable and prepared-statement execution context;
- table version;
- row-count change ratio only when
  `session_plan_cache_allow_change_ratio` is positive; the default `0` disables
  row-count-change invalidation;
- optimizer switch;
- client character set;
- parameter signature and runtime null/no-value state;
- access recipe compatibility;
- access signature compatibility.

Counters:

- `Cached_plan_hits`: successful rebuilt-plan hits;
- `Cached_plan_prevalidations`: recipe matches before a hit attempt;
- `Cached_plan_invalidations`: semantic invalidations;
- `Cached_plan_count`: global live cached states; session status currently
  reports `0`.

## Safety and Fail-Closed Boundary

| Case | First-stage behavior |
|---|---|
| `EXPLAIN` / `ANALYZE` | fail-closed |
| Locking clauses | fail-closed |
| User variables or side-effect expressions | fail-closed |
| `RAND()` and other nondeterministic expressions | fail-closed |
| Dependent/correlated subqueries | fail-closed |
| Temporary, system, schema, or non-user tables | fail-closed |
| Views and derived tables | fail-closed |
| Multi-table joins | fail-closed |
| Set operations | fail-closed |
| Window functions | fail-closed |
| `LIMIT` outside unique equality | fail-closed |

## Why Not Full Plan Clone First

Broader full-plan-cache implementations store execution context including QEP
state, ORDER/GROUP state, transient Item clones, range/index-merge details, and
temporary-table metadata. MariaDB's optimizer and executor internals differ
enough that a direct full clone port would be high-risk and hard to review in
one community patch.

The recipe-rebuild design makes the first stage easier to audit:

- smaller memory lifetime surface;
- less retained execution state;
- easier fail-closed behavior;
- targeted MTR assertions for every supported SQL shape.

The tradeoff is narrower feature coverage and lower parity with broader
full-plan-cache designs.

## Community Review Questions

1. The public variables now use neutral MariaDB names:
   `session_plan_cache` and `session_plan_cache_allow_change_ratio`.
2. Should sysbench `SUM`/`ORDER BY`/`DISTINCT` range support be included in the
   first functional PR, or kept for a later patch after equality/range access
   lands?
3. Should optimizer trace output be added before PR submission, or after the
   initial recipe model is accepted?
4. What minimum benchmark evidence is required for a default-off server feature?
