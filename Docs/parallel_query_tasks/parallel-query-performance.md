# Parallel Query Performance Evidence

## Status

The numbers below are local engineering measurements for the prototype. They
show that the Q1/Q6 paths execute through Parallel Query and can improve
elapsed time on the tested host. They are not official MariaDB benchmark
results and should not be presented as a general TPC-H claim.

## Test Context

- Dataset: TPC-H SF10 standard model subset required by LINEITEM foreign keys:
  `orders`, `partsupp`, and `lineitem`.
- Row counts:
  - `orders`: 15,000,000
  - `partsupp`: 8,000,000
  - `lineitem`: 59,986,052
- Server binary: `build_release_pq/sql/mariadbd`
- Buffer pool: 12G
- Networking: disabled for the local measurement run
- Table charset/collation: default `utf8mb4_uca1400_ai_ci`
- Host CPU topology reported by the local machine:
  4 performance cores and 6 efficiency cores

Import timings:

| Table | Time |
| --- | ---: |
| `orders` | 22.72s |
| `partsupp` | 14.36s |
| `lineitem` | 119.52s |

Adding the two LINEITEM foreign keys took 265.19s.

## Schema Notes

The benchmark uses the TPC-H `lineitem` columns and the standard primary key:

```sql
PRIMARY KEY (l_orderkey, l_linenumber)
```

It also adds the two standard LINEITEM foreign keys:

```sql
CONSTRAINT lineitem_fk1 FOREIGN KEY (l_orderkey)
  REFERENCES orders(o_orderkey),
CONSTRAINT lineitem_fk2 FOREIGN KEY (l_partkey, l_suppkey)
  REFERENCES partsupp(ps_partkey, ps_suppkey)
```

InnoDB creates a supporting secondary index for `lineitem_fk2`:

```sql
KEY lineitem_fk2 (l_partkey, l_suppkey)
```

No secondary index is created on `l_shipdate`. Therefore Q6 measures
clustered-primary full scan plus predicate filtering and aggregation, not a
secondary-index range scan.

## Results

Q1/Q6 verification included EXPLAIN checks and `Parallel_query_count`.

| Query | Serial | PQ(2) | PQ(4) | PQ(8) | Notes |
| --- | ---: | ---: | ---: | ---: | --- |
| Q1 full grouped aggregate | 36.44s / 33.92s | not rerun | 9.28s / 9.25s | not rerun | `Parallel_query_count=1`; about 3.7x at DOP 4 |
| Q6 scalar aggregate | 4.93s / 5.43s warm repeat | 2.45s / 2.52s | 1.85s / 1.87s | 2.62s / 2.69s | `Parallel_query_count=1`; DOP 4 was best on this host |

The first Q6 serial run immediately after the foreign-key ALTER took 15.93s.
The table then warmed to 4.93s and 5.43s in repeated serial runs. The table
above reports the warm repeat values.

## Q1 Interpretation

Q1 enters the PQ path on the realistic SF10 collation:

- EXPLAIN shows `<gather1>` with
  `Parallel execute (4 workers, tpch.lineitem); Using temporary; Using filesort`.
- Optimizer trace shows `query_shape="grouped_aggregate"` and
  `worker_scan_api="row_pq_record_buffer"`.
- `Parallel_query_count=1`.

The measured local speedup is about 3.7x at DOP 4 for the constrained Q1 full
grouped aggregate shape.

## Q6 Interpretation

Q6 does not scale linearly beyond DOP 4 on this host:

- Serial Q6 EXPLAIN shows `type=ALL`, `possible_keys=NULL`, `key=NULL`, and
  `Using where`.
- PQ Q6 EXPLAIN shows `<gather1>` with
  `Parallel execute (4 workers, tpch.lineitem)`.
- The underlying `lineitem` scan remains `type=ALL`.
- PQ(4) worker ranges are balanced and complete in about 1.75s per worker.
- PQ(8) and PQ(16) launch workers and split rows evenly, but each worker slows
  to about 2.6s to 2.8s.

The evidence does not indicate hint parsing failure, fallback, or split
imbalance. The likely bottleneck is the current row record-buffer scan path:
InnoDB page scan, row materialization, predicate evaluation, decimal
aggregation, memory bandwidth, and CPU scheduling all contribute.

Recommended wording for review:

- The prototype demonstrates useful local speedup at an appropriate DOP.
- DOP is a resource-control parameter, not a linear-speedup guarantee.
- On this host, Q6 is best demonstrated with `PQ(4)` or
  `parallel_max_threads=4`.
- Larger-machine results need a separate benchmark table with hardware,
  dataset, warmup/cache state, and a repeated DOP sweep.
