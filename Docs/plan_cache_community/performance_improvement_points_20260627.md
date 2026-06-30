# Plan Cache Performance Improvement Points

Recorded: 2026-06-27

This note summarizes where the current plan-cache implementation gets its
measured performance gain and where further optimization should focus.  The
data below is local release diagnostic evidence on macOS/Darwin without Linux
CPU-set isolation, so it is for engineering direction only.

## Evidence Inputs

Primary mixed read-only run:

```text
Artifact: /tmp/plan-cache-value-20260627-022352/plan-cache-primary-20260627-022352
Build: Release, ASAN OFF
Workload: oltp_read_only
Config: 64 tables, 25000 rows/table, 10G buffer pool, 60s, 3 repeats
```

Shape attribution smoke:

```text
Artifact: /tmp/plan-cache-shapes-20260627-030036
Build: Release, ASAN OFF
Workload: oltp_read_only shapes
Config: 16 tables, 10000 rows/table, 4G buffer pool, 15s, 1 repeat, 1 thread
```

Point-only follow-up:

```text
Artifact: /tmp/plan-cache-shapes-20260627-085700
Build: Release, ASAN OFF
Workload: oltp_read_only:point
Config: 16 tables, 10000 rows/table, 4G buffer pool, 20s, 3 repeats, 1 thread
Profile counters: disabled
```

## Main Finding

The strongest performance point is exact DISTINCT range:

```sql
SELECT DISTINCT c
FROM sbtestN
WHERE id BETWEEN ? AND ?
ORDER BY c
```

In the short shape attribution run:

```text
distinct_range: +81.71% QPS/TPS, -63.83% CPU/kQPS
OFF temporary tables: 98362
ON temporary tables: 35
ON hits: 178684
ON invalidations: 0
```

This matches the mixed `oltp_read_only` status pattern.  In the primary run,
OFF creates about one temporary table per transaction, while ON keeps temporary
tables near zero.  The cache hit path is not merely saving parse/optimizer CPU;
for this exact shape it also avoids the repeated temporary-table/group setup
that dominates the uncached path.

## Shape Ranking

The one-thread shape smoke ranks current value as:

```text
distinct_range  +81.71% QPS, -63.83% CPU/kQPS
simple_range     +7.32% QPS, -10.61% CPU/kQPS
sum_range        +7.07% QPS, -10.28% CPU/kQPS
order_range      +1.45% QPS,  -3.21% CPU/kQPS
point            -5.16% QPS,  -0.07% CPU/kQPS  (single 15s profile-on sample)
```

Interpretation:

- `distinct_range` is the feature-value proof and should be the first Linux
  attribution target.
- `simple_range` and `sum_range` are modest positive supporting cases.
- `order_range` is close to noise and should only be monitored.
- The single `point` row above is not a valid regression conclusion.  It was a
  one-repeat, 15-second, profile-enabled smoke sample.  A follow-up point-only
  run with profile counters disabled and 3 repeats showed positive median
  performance:

```text
point follow-up: +6.90% QPS/TPS, -19.84% CPU/kQPS
ON CV: 1.71%
ON hits median: 1799977
ON invalidations: 0
```

  Therefore point select is not proven to regress.  It is simply lower priority
  because its hit path is already cheap and its incremental gain is much smaller
  than `distinct_range`.

## Remaining Hit-Path Cost

Current per-hit profile costs from the shape smoke:

```text
distinct_range: hit_path 0.776 us, range_build 0.724 us, range_setup 0.545 us
order_range:    hit_path 0.633 us, range_build 0.585 us, range_setup 0.420 us
sum_range:      hit_path 0.595 us, range_build 0.546 us, range_setup 0.390 us
simple_range:   hit_path 0.507 us, range_build 0.461 us, range_setup 0.288 us
point:          hit_path 0.199 us, unique_build 0.162 us, explain 0.049 us
```

The remaining visible cost is range build/setup, especially DISTINCT range
post-setup.  However, earlier experiments already showed that broad shortcuts
around `build_explain()`, generic `make_aggr_tables_info()`, or complete quick
reuse are unsafe or too noisy.  Further code optimization should therefore be
narrow and data-triggered.

## Next Performance Work

1. Run Linux CPU-set `SUITE_MODE=value` with 5 repeats:

```bash
ARTIFACT_ROOT=/path/to/artifacts \
SUITE_MODE=value \
TABLES=250 TABLE_SIZE=25000 THREADS="1 2 4 8 16" \
SHAPE_THREADS="1 2 4 8" \
BUFFER_POOL_SIZE=10G PREWARM_TIME=120 RUN_TIME=300 REPEATS=5 \
SERVER_CPUSET=0-7 SYSBENCH_CPUSET=8-15 \
Docs/plan_cache_community/run_sysbench_benchmark_suite.sh
```

2. Treat `distinct_range` as the first attribution target.

3. Only consider a new production-code patch if Linux evidence shows a stable
   remaining DISTINCT range bottleneck with valid hits, zero invalidations, and
   low run-to-run variance.

4. If a patch is justified, keep it exact-shape and fail-closed:

```text
candidate area: exact DISTINCT range aggregate/explain metadata setup
avoid: generic DISTINCT/GROUP BY shortcuts
avoid: skipping build_explain() outright
avoid: complete QUICK_RANGE_SELECT or JOIN_TAB reuse
```

## Current Decision

The current performance improvement point has been found: plan cache provides
the strongest value by turning the sysbench read-only DISTINCT range query from
the repeated temporary-table/group setup path into a cheap cached exact-shape
range hit.  The next step is not speculative point-query tuning; it is Linux
CPU-set confirmation and, only if needed, a narrow DISTINCT range setup patch.
