# Parallel Query High-Level Design

## Goal

The prototype adds a narrow Parallel Query path for common analytical scans.
The immediate goal is to demonstrate worker-side parallel execution and
leader-side result merge for Q1/Q6-style TPC-H workloads.

The branch should be reviewed as a staged contribution proposal. It is not a
complete TaurusDB Parallel Query port and it does not claim general SQL
parallel execution.

## Supported Scope

The current implementation supports selected single-table InnoDB read-only
queries:

- Q6-style scalar aggregation:

```sql
SELECT SUM(l_extendedprice * l_discount)
FROM lineitem
WHERE l_shipdate >= DATE '1994-01-01'
  AND l_shipdate < DATE '1995-01-01'
  AND l_discount BETWEEN 0.05 AND 0.07
  AND l_quantity < 24;
```

- Q1-style constrained grouped aggregation:

```sql
SELECT l_returnflag, l_linestatus,
       SUM(l_quantity), SUM(l_extendedprice),
       SUM(l_extendedprice * (1 - l_discount)),
       SUM(l_extendedprice * (1 - l_discount) * (1 + l_tax)),
       AVG(l_quantity), AVG(l_extendedprice), AVG(l_discount),
       COUNT(*)
FROM lineitem
WHERE l_shipdate <= DATE '1998-09-02'
GROUP BY l_returnflag, l_linestatus
ORDER BY l_returnflag, l_linestatus;
```

The same worker scan model also supports ordinary count and selected
raw-copy-safe projection cases.

## Execution Model

1. The leader evaluates query-shape eligibility in the SQL layer.
2. Unsupported shapes use the existing serial execution path.
3. For an eligible query, the leader chooses a supported scan provider.
4. Worker threads open their own table instances.
5. Workers use a statement snapshot cloned from the leader transaction.
6. Workers scan disjoint ranges and build partial results.
7. The leader joins workers, handles cancellation and errors, and merges
   scalar or grouped partial results.
8. The final result is returned through the normal MariaDB result path.

This design keeps the prototype opt-in and fallback-oriented. It avoids
partial parallel execution for query shapes that cannot be handled safely.

## User-Visible Controls

The branch adds explicit controls for staged testing and review:

- PQ optimizer switch and feature switch controls.
- `PQ(N)` and `NO_PQ` hint handling compatible with the current prototype
  surface.
- DOP limits and worker queue timeout controls.
- EXPLAIN, optimizer trace, status counter, and slow-log observability.

## Non-Goals

The current branch does not implement:

- general joins or hash joins;
- UNION, derived tables, recursive CTE, or correlated subqueries;
- write-select, CTAS, or DML parallel execution;
- full worker JOIN/TABLE/Item plan cloning;
- TaurusDB message-queue transport;
- complete InnoDB B-tree/subtree split;
- broad secondary-index, ref, reverse, or ICP parity;
- MySQL/TaurusDB `EXPLAIN FORMAT=TREE` parity.

These are follow-up topics for staged review.
