# Known Limitations

This document is intentionally conservative. Unsupported shapes must execute
through the normal optimizer/executor path without changing results, counters,
or cached-state lifetime.

## Unsupported SQL Scope

| Area | Current behavior | Rationale |
|---|---|---|
| Multi-table joins | fail-closed | Join-order and dependency state are outside recipe rebuild scope. |
| Derived tables and views | fail-closed | Table and item ownership differs from base-table recipes. |
| UNION/EXCEPT/INTERSECT | fail-closed | Multiple query blocks and fake select blocks are not modeled. |
| Correlated subqueries | fail-closed | Outer references and item rebinding need a separate design. |
| Scalar subqueries | fail-closed in MariaDB port | Restricted scalar-subquery reuse needs a dedicated MariaDB design. |
| General `GROUP BY` | fail-closed | Temporary table and aggregate state is not generally reconstructed. |
| General aggregates | fail-closed except narrow sysbench `SUM(field)` range | Multiple aggregate functions and expression args need more executor state. |
| General `ORDER BY` | fail-closed except one-field sysbench range | Broader filesort state and hidden item substitutions are not modeled. |
| General `DISTINCT` | fail-closed except one-field `DISTINCT ... ORDER BY` range | DISTINCT temporary table state is high risk. |
| Window functions | fail-closed | Window setup has known wrong-result risk in full-plan-cache designs. |
| `EXPLAIN` and `ANALYZE` | fail-closed | Explain output and runtime analysis should describe the normal optimizer path until trace support is designed. |
| Locking clauses | fail-closed | Locking read semantics need explicit executor-state validation. |
| User variables and side-effect expressions | fail-closed | Repeated execution must not skip side effects or alter evaluation order. |
| `RAND()` and nondeterministic expressions | fail-closed | Cached access recipes must not freeze nondeterministic behavior. |
| DML and transaction control | fail-closed/out of hook | Current hook is `JOIN::optimize()` for `SELECT`. |
| `SQL_CALC_FOUND_ROWS` | fail-closed | Found-row accounting needs preserved execution context. |
| `LIMIT 1` outside unique equality | fail-closed | Broader LIMIT handling changes executor accounting and row goals. |
| Temporary/system/schema tables | fail-closed | Community patch should avoid non-user table categories first. |
| Fulltext | fail-closed | Fulltext access is not represented by current recipes. |
| Stored procedure/function context | not opened | Routine state and statement lifetime need separate validation. |

## Differences From Broader Prior Implementations

Broader prior implementations support broader plan reuse by cloning or
preserving more optimizer/executor state. That includes Item clone tracking,
ORDER/GROUP list cloning, temp table parameters, QEP tab reinit, ICP, covering
index state, index merge, scalar subquery support, and more aggregate coverage.

The MariaDB port intentionally does not claim parity. It currently aims to be a
safe first-stage plan cache with a smaller supported surface.

## TaurusDB / MySQL Delta

| Area | Broader TaurusDB/MySQL-style implementation | Current MariaDB stage |
|---|---|---|
| Reuse model | Fuller `JOIN`/QEP/execution-context reuse with clone/rebind support. | Compact recipe capture and per-hit rebuild. |
| Joins | Broader join plan reuse. | Single user base table only. |
| Item handling | Item clone tracking and rebinding. | Parameter signature and narrow expression acceptance only. |
| Temporary tables | More temp-table metadata can be retained. | General temp-table state is not cached. |
| ICP / covering / index merge | Broader access-path metadata support. | Narrow unique/ref/range recipes only. |
| Scalar subqueries | Supported in restricted forms. | Fail-closed. |
| ORDER/GROUP/DISTINCT | Broader executor-state coverage. | Exact sysbench-shaped ORDER and DISTINCT range recipes only. |
| Aggregates | Broader aggregate support. | Narrow `SUM(field)` range recipe only. |

## Expansion Candidates

Recommended order after the current community-prep stage:

1. Table scan and index scan recipes.
2. Covering index and ICP metadata in access signatures.
3. Index merge recipe with strict access-path validation.
4. Broader aggregate support: `COUNT`, `COUNT(not null)`, `AVG`.
5. Restricted scalar subquery support.
6. Broader ORDER/GROUP/DISTINCT after dedicated executor-state design.
