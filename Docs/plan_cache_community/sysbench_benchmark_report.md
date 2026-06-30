# Sysbench Benchmark Report

## Status

`sysbench 1.0.20` is available locally at `/opt/homebrew/bin/sysbench`.

Preliminary local InnoDB release benchmarks were collected on 2026-06-25 CST.
A longer in-memory release benchmark was collected on 2026-06-26 CST with
10 GB buffer pool, larger table/open-definition caches, 300 second measured
windows, and three complete repeats for `oltp_point_select` and
`oltp_read_only`.

The latest local result is strong enough to show feature value for sysbench
`oltp_read_only`: plan cache ON improved median QPS at every tested concurrency
from 1 to 16 threads, with no invalidations and clear hit growth. Pure
`oltp_point_select` is positive at 1/2/4/8 threads but still too noisy at
16 threads for a broad community claim.

This is still local macOS evidence without CPU set isolation. It is suitable as
engineering evidence and as the basis for the community benchmark method, but a
community PR should still repeat the same harness on a dedicated Linux host with
separate `mariadbd` and sysbench CPU sets.

## Current HEAD 60s x 3 Repeat Primary Check

After splitting unique/ref hit profile counters, the current HEAD was retested
with the release benchmark harness and profile collection disabled.  This run
uses one data load, then three alternating OFF/ON repeats for
`oltp_read_only` at 1/2/4/8 threads.

Environment:

```text
date: 2026-06-26 CST
output: /tmp/plan-cache-primary-20260626-205939
HEAD: a5d6053bff242f23689578357f409ed26024bf58
server: build_plan_cache_release/sql/mariadbd
CMAKE_BUILD_TYPE: Release
WITH_ASAN: OFF
sysbench: 1.0.20
buffer_pool_size: 4G
tables: 64
table_size: 10000
workload: oltp_read_only
read_only_extra_args: --skip-trx=1
prepared statements: --db-ps-mode=auto
prewarm: 30s
measure: 60s per case
repeats: 3
CPU binding: not available on this macOS host
```

Results:

| Threads | OFF median TPS/QPS | ON median TPS/QPS | QPS Change | CPU/kQPS Change | Positive repeats | ON hit median | Invalidations |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 2260.77 / 31650.76 | 2930.79 / 41031.11 | +29.64% | -34.31% | 3/3 | 2461594 | 0 |
| 2 | 4330.76 / 60630.69 | 5256.68 / 73593.58 | +21.38% | -24.12% | 3/3 | 4415072 | 0 |
| 4 | 4991.50 / 69881.01 | 5663.86 / 79294.02 | +13.47% | -18.12% | 3/3 | 4756522 | 0 |
| 8 | 7041.47 / 98580.58 | 8042.32 / 112592.48 | +14.21% | -15.64% | 3/3 | 6753672 | 0 |

Final plan-cache status returned to `Cached_plan_count=0`, cumulative
`Cached_plan_hits=55015764`, and `Cached_plan_invalidations=0`.

Interpretation:

- `oltp_read_only` remains the clearest current performance improvement point.
- ON improved QPS and CPU per kQPS in every tested repeat at every tested
  concurrency.
- The local primary gate failed only because t4 was classified as supporting
  rather than primary: ON QPS CV was 5.13%, slightly above the 5.0% low-variance
  threshold.  This is a repeatability warning for community publishing, not a
  throughput regression.
- OFF scaling is already non-linear on this host, especially from 4 to 8
  threads.  The non-linearity should be treated as a host/shared-resource
  effect until a Linux CPU-set run proves otherwise.

## Current HEAD Distinct Range Attribution Check

After adding sample-validity filtering to the benchmark harness, the strongest
single SELECT shape was retested with a focused release run.  This artifact
uses the new `valid`, `elapsed_sec`, `expected_sec`, and `invalid_samples`
fields and has no excluded samples.

Environment:

```text
date: 2026-06-27 CST
output: /tmp/plan-cache-shapes-20260627-005244
HEAD: 407ab07827be39692fc4935ed344e7f846b6d390
server: build_plan_cache_release/sql/mariadbd
CMAKE_BUILD_TYPE: Release
WITH_ASAN: OFF
sysbench: 1.0.20
buffer_pool_size: 4G
tables: 64
table_size: 10000
workload: oltp_read_only:distinct_range
prepared statements: --db-ps-mode=auto
prewarm: 20s
measure: 30s per case
repeats: 3
CPU binding: not available on this macOS host
```

Results:

| Threads | OFF median QPS | ON median QPS | QPS Change | CPU/kQPS Change | Positive repeats | Invalid samples | ON hit median | Invalidations |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 6450.75 | 11675.14 | +80.99% | -51.25% | 3/3 | 0 | 350204 | 0 |
| 4 | 17744.31 | 34496.18 | +94.41% | -52.17% | 3/3 | 0 | 1034724 | 0 |

Final plan-cache status returned to `Cached_plan_count=0`, cumulative
`Cached_plan_hits=3909535`, and `Cached_plan_invalidations=0`.

Interpretation:

- `distinct_range` is the clearest current per-template performance improvement
  point and should be the first attribution case in the community benchmark.
- The benefit remains strong after alternating OFF/ON order and after adding
  invalid-sample filtering.
- This does not replace the required Linux CPU-set formal run, but it narrows
  the recommended evidence path: prove `oltp_read_only` primary first, then
  `distinct_range` attribution, before spending time on noisier point/select
  shapes.

## Current HEAD Primary Check With Sample Validity

After the invalid-sample gate was added, the mixed `oltp_read_only` primary
case was rerun on the same local macOS host.  This confirms that the main
workload remains positive when the new `valid` / `elapsed_sec` / `invalid_samples`
artifact path is active.

Environment:

```text
date: 2026-06-27 CST
output: /tmp/plan-cache-primary-20260627-010323
HEAD: 3478723cceb38e50d977da4a075c3de2742e7eb4
server: build_plan_cache_release/sql/mariadbd
CMAKE_BUILD_TYPE: Release
WITH_ASAN: OFF
sysbench: 1.0.20
buffer_pool_size: 4G
tables: 64
table_size: 10000
workload: oltp_read_only
prepared statements: --db-ps-mode=auto
prewarm: 20s
measure: 45s per case
repeats: 3
CPU binding: not available on this macOS host
```

Results:

| Threads | OFF median QPS | ON median QPS | QPS Change | CPU/kQPS Change | Positive repeats | Invalid samples | ON hit median | Invalidations |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 32286.60 | 41106.80 | +27.32% | -30.91% | 3/3 | 0 | 1849528 | 0 |
| 2 | 51854.20 | 61696.02 | +18.98% | -22.55% | 3/3 | 0 | 2775784 | 0 |
| 4 | 65475.82 | 75095.08 | +14.69% | -18.95% | 3/3 | 0 | 3378208 | 0 |
| 8 | 91380.79 | 101092.39 | +10.63% | -12.96% | 3/3 | 0 | 4547258 | 0 |

Final plan-cache status returned to `Cached_plan_count=0`, cumulative
`Cached_plan_hits=37786062`, and `Cached_plan_invalidations=0`.

Interpretation:

- Mixed `oltp_read_only` remains positive across all tested local concurrency
  levels after invalid-sample filtering.
- The automated primary gate returned non-zero only because t2 was classified
  as noisy positive: ON QPS CV was 9.07%, above the 5.0% low-variance threshold.
  Repeat-level evidence still shows 3/3 positive QPS and CPU/kQPS repeats.
- This artifact strengthens the engineering case, but it still has review
  signals for missing Linux CPU-set isolation and should not be used as final
  community-facing performance evidence.

## Current HEAD Read-Only Confirmation

After the read-only template split in `performance_root_cause_report.md`, the
current HEAD was retested with the committed in-memory release harness. This run
uses a single data load and then compares plan cache OFF/ON for
`oltp_read_only` at 1/2/4/8 threads. It is still local macOS engineering
evidence, not final community benchmark evidence.

Environment:

```text
date: 2026-06-26 CST
output: /tmp/plan-cache-read-only-60s-20260626-173638
HEAD: 8f3e0115258f16bd372adf5bc455aec933bc6dc3
server: build_plan_cache_release/sql/mariadbd
CMAKE_BUILD_TYPE: Release
WITH_ASAN: OFF
sysbench: 1.0.20
buffer_pool_size: 10G
tables: 64
table_size: 50000
workload: oltp_read_only
read_only_extra_args: --skip-trx=1
prepared statements: --db-ps-mode=auto
prewarm: 60s
measure: 60s per case
CPU binding: not available on this macOS host
```

Results:

| Threads | OFF TPS/QPS | ON TPS/QPS | Change | ON hit delta | Invalidations | Server CPU avg change |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 2166.72 / 30334.11 | 2698.15 / 37774.15 | +24.53% | 2266168 | 0 | -16.03% |
| 2 | 3498.14 / 48973.96 | 4345.55 / 60837.75 | +24.22% | 3649706 | 0 | -5.34% |
| 4 | 4089.59 / 57254.29 | 4798.08 / 67173.18 | +17.32% | 4029306 | 0 | -4.59% |
| 8 | 6148.01 / 86072.14 | 6728.14 / 94193.94 | +9.44% | 5649618 | 0 | -4.40% |

Interpretation:

- `oltp_read_only` remains the strongest local value proof for this feature.
- ON improves QPS/TPS at every tested concurrency and does so while average
  `mariadbd` CPU is lower than OFF.
- The improvement tapers at 8 threads on this laptop because the server CPU
  average is already above five cores and macOS cannot isolate sysbench/server
  CPU sets in the same way as the planned Linux benchmark.
- This result supports freezing risky optimizer changes for now and moving the
  performance effort to repeatability: Linux CPU-set runs, longer windows, and
  multiple repeats.

## Current HEAD Shape Matrix

The committed in-memory harness was then used to split `oltp_read_only` into
individual SELECT shapes. This run is still macOS engineering evidence, but it
uses the same script path intended for the Linux benchmark and samples live
plan-cache status while sysbench is running.

Environment:

```text
date: 2026-06-26 CST
output: /tmp/plan-cache-shape-matrix-20260626-180554
HEAD: f0cae999261c6c606d361c04a8f7ecf65fe6ac14
server: build_plan_cache_release/sql/mariadbd
CMAKE_BUILD_TYPE: Release
WITH_ASAN: OFF
sysbench: 1.0.20
buffer_pool_size: 4G
tables: 32
table_size: 20000
workload: oltp_read_only
read_only_shapes: point simple_range sum_range order_range distinct_range
threads: 1, 4
prewarm: 30s
measure: 20s per case
repeats: 1
CPU binding: not available on this macOS host
```

Results:

| Shape | Threads | OFF QPS | ON QPS | Change | ON hit delta | ON live count max | Invalidations | CPU/kQPS change |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| point | 1 | 83840.09 | 91831.80 | +9.53% | 1836665 | 32 | 0 | -38.57% |
| point | 4 | 153687.72 | 152818.06 | -0.57% | 3056399 | 128 | 0 | +1.67% |
| simple_range | 1 | 21029.95 | 23178.91 | +10.22% | 463561 | 32 | 0 | -21.19% |
| simple_range | 4 | 61548.25 | 63568.20 | +3.28% | 1271302 | 128 | 0 | -3.16% |
| sum_range | 1 | 40823.75 | 47060.77 | +15.28% | 941217 | 32 | 0 | -21.36% |
| sum_range | 4 | 101138.35 | 91120.56 | -9.91% | 1822380 | 128 | 0 | -6.36% |
| order_range | 1 | 12012.53 | 12487.43 | +3.95% | 249725 | 32 | 0 | -11.56% |
| order_range | 4 | 29268.68 | 29796.35 | +1.80% | 595830 | 128 | 0 | +0.05% |
| distinct_range | 1 | 6543.74 | 11839.37 | +80.93% | 236763 | 32 | 0 | -53.33% |
| distinct_range | 4 | 17763.14 | 28381.18 | +59.78% | 567535 | 128 | 0 | -41.17% |

Interpretation:

- `distinct_range` is the strongest current value case and should be the first
  template highlighted in community performance material.
- `simple_range`, `sum_range`, and `order_range` are useful supporting SELECT
  shapes. Their CPU-per-kQPS deltas are generally better with plan cache ON.
- Pure `point` is too short to be the headline benchmark. It is positive at
  one thread but effectively flat at four threads on this host.
- Every ON case sampled a non-zero live cached-plan count and zero
  invalidations, so these results are real plan-cache hits rather than status
  artifacts after disconnect.

The only negative QPS result that needed immediate follow-up was
`sum_range` at four threads. A focused three-repeat rerun showed the single
negative result was not stable:

```text
output: /tmp/plan-cache-sumrange-repeat-20260626-181349
shape: sum_range
threads: 4
measure: 20s per case
repeats: 3
```

| Shape | Threads | OFF median QPS | ON median QPS | Change | OFF CV | ON CV | CPU/kQPS change | ON hit median | Invalidations |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| sum_range | 4 | 71543.61 | 88938.65 | +24.31% | 17.89% | 9.58% | -22.73% | 1778762 | 0 |

This keeps `sum_range` in the supporting-benefit set, but the high macOS
variance means the formal benchmark must use longer Linux runs with repeated
median statistics.

## Required Formal Benchmark

Use a dedicated server instance and data directory, not an MTR debug server.
The formal benchmark should use the committed
`Docs/plan_cache_community/in_memory_sysbench_harness.sh` script so the raw
results, live plan-cache status samples, environment details, and summary
statistics are generated in one artifact directory.

Primary matrix:

| Workload | Threads | Time | Modes |
|---|---:|---:|---|
| `oltp_read_only --skip-trx=1` | 1, 2, 4, 8, 16 | 120s warmup + 300s run | plan cache off/on |

Supporting matrices:

| Workload | Threads | Time | Purpose |
|---|---:|---:|---|
| `oltp_read_only:distinct_range` | 1, 2, 4, 8 | 120s warmup + 300s run | explain strongest gain source |
| `oltp_read_only:sum_range` | 1, 2, 4, 8 | 120s warmup + 300s run | supporting range/aggregate gain |
| `oltp_read_only:order_range` | 1, 2, 4, 8 | 120s warmup + 300s run | supporting range/order gain |
| `oltp_read_only:simple_range` | 1, 2, 4, 8 | 120s warmup + 300s run | low-amplitude supporting data |
| `oltp_read_only:point` | 1, 2, 4, 8 | 120s warmup + 300s run | noise boundary, not headline |
| `oltp_point_select` | 1, 2, 4, 8, 16 | 120s warmup + 300s run | supporting microbenchmark only |
| `oltp_read_write` | 8, 16, 32 | 120s warmup + 300s run | regression guard only |

Recommended data:

```text
tables=250
table_size=25000
buffer_pool_size=10G
db-ps-mode=auto
repeats=5
mode order=AB/BA alternating
```

Primary command:

```bash
ROOT_DIR=/path/to/server-plan-cache \
BUILD_DIR=/path/to/server-plan-cache/build_plan_cache_release \
OUT_DIR=/path/to/artifacts/plan-cache-sysbench-$(date +%Y%m%d-%H%M%S) \
TABLES=250 \
TABLE_SIZE=25000 \
THREADS="1 2 4 8 16" \
WORKLOADS="oltp_read_only" \
BUFFER_POOL_SIZE=10G \
PREWARM_TIME=120 \
RUN_TIME=300 \
REPEATS=5 \
SERVER_CPUSET=0-7 \
SYSBENCH_CPUSET=8-15 \
Docs/plan_cache_community/in_memory_sysbench_harness.sh
```

Shape command:

```bash
ROOT_DIR=/path/to/server-plan-cache \
BUILD_DIR=/path/to/server-plan-cache/build_plan_cache_release \
OUT_DIR=/path/to/artifacts/plan-cache-sysbench-shapes-$(date +%Y%m%d-%H%M%S) \
TABLES=250 \
TABLE_SIZE=25000 \
THREADS="1 2 4 8" \
WORKLOADS="oltp_read_only" \
READ_ONLY_SHAPES="distinct_range sum_range order_range simple_range point" \
BUFFER_POOL_SIZE=10G \
PREWARM_TIME=120 \
RUN_TIME=300 \
REPEATS=5 \
SERVER_CPUSET=0-7 \
SYSBENCH_CPUSET=8-15 \
Docs/plan_cache_community/in_memory_sysbench_harness.sh
```

Record and preserve:

- QPS/TPS;
- average and p95 latency from sysbench;
- server CPU average and max;
- CPU per kQPS from `summary.tsv`;
- `Cached_plan_hits`, `Cached_plan_count`, and `Cached_plan_invalidations`;
- running-state `raw/*plan_cache_status.tsv` samples;
- `environment.txt`, `mariadbd.err`, raw sysbench outputs, `results.tsv`, and
  `summary.tsv`.

Publishable community wording should be based on `oltp_read_only` median
results. Shape-only data explains where the mixed-workload gain comes from, but
should not replace the mixed workload as the headline claim. Pure point-select
data should remain supporting evidence unless repeated Linux results become
both positive and low variance.

## Expected Functional Coverage

The current feature should hit for the sysbench 1.0.20 OLTP prepared SELECT
templates listed here:

- point selects;
- secondary-key point selects when using a non-unique `id` index;
- simple ranges;
- sum ranges;
- order ranges;
- distinct ranges.

`oltp_read_write` should not cache prepared DML or transaction-control
statements. It is useful as a regression guard because read-only SELECTs may hit
while writes remain on the normal execution path.

## Minimum Pass Criteria

- Feature branch with `session_plan_cache=OFF` should not regress by more than 5%
  versus the upstream/base branch with the same workload and server options.
- Feature branch with `session_plan_cache=ON` should show repeatable hit growth and
  measurable CPU or QPS improvement versus the same feature branch with
  `session_plan_cache=OFF` for prepared point/range SELECT workloads.
- `Cached_plan_count` must return to baseline after clients disconnect.
- No wrong results, crashes, or server warnings attributable to plan cache.

## Local Smoke Command Template

```bash
sysbench /opt/homebrew/share/sysbench/oltp_point_select.lua \
  --db-driver=mysql \
  --mysql-socket=<socket> \
  --mysql-user=root \
  --mysql-db=sbtest \
  --tables=1 \
  --table-size=10000 \
  --threads=1 \
  --time=30 \
  --db-ps-mode=auto \
  run
```

Set `GLOBAL session_plan_cache=ON` for the feature-on run and `OFF` for the
baseline run before opening new sysbench connections.

## Local Smoke Result

Environment:

```text
sysbench: 1.0.20
server: build_plan_cache_debug MTR server
engine: MyISAM
tables: 1
table_size: 1000
threads: 1
events: 100
prepared statements: --db-ps-mode=auto
```

Result:

```text
plan cache off: Cached_plan_hits=0
plan cache on:  Cached_plan_hits=99
Cached_plan_count after sysbench disconnect: 0

off smoke summary: 100 transactions, 100 queries, avg latency 0.04 ms
on smoke summary:  100 transactions, 100 queries, avg latency 0.04 ms
```

Interpretation:

- The smoke confirms sysbench can exercise the prepared point-select path.
- The first feature-on execution builds the cached state; the remaining 99
  executions hit.
- Disconnect cleanup releases the live cached state.
- This smoke is not performance evidence. A community PR still needs a formal
  InnoDB benchmark with longer runtime, warmup, CPU/RSS observation, and
  repeated runs.

## Preliminary Release InnoDB Benchmark

This run uses the release build only. The earlier debug/MTR smoke above remains
functional evidence and is not used for performance conclusions.

Environment:

```text
date: 2026-06-25 CST
repository: /Users/zhuqingping/Work/Database/MariaDB/server-plan-cache
branch: plan_cache
HEAD: 388a69edc932c7264fd98745f9dd33651589c789
server: build_plan_cache_release/sql/mariadbd
version: 13.1.0-MariaDB for osx10.21 on arm64
CMAKE_BUILD_TYPE: Release
WITH_ASAN: OFF
sysbench: 1.0.20
engine: InnoDB
tables: 4
table_size: 100000
prepared statements: --db-ps-mode=auto
warmup: 10s per case
measure: 30s per case
```

Server options:

```text
--innodb-buffer-pool-size=512M
--innodb-flush-log-at-trx-commit=2
--innodb-doublewrite=0
--performance-schema=OFF
--skip-log-bin
```

Raw result:

| Workload | Threads | Mode | TPS | QPS | Avg latency ms | p95 latency ms | Cached_plan_hits cumulative |
|---|---:|---|---:|---:|---:|---:|---:|
| `oltp_point_select` | 1 | OFF | 79769.61 | 79769.61 | 0.01 | 0.00 | 0 |
| `oltp_point_select` | 1 | ON | 96174.50 | 96174.50 | 0.01 | 0.00 | 3843465 |
| `oltp_point_select` | 8 | OFF | 198562.67 | 198562.67 | 0.04 | 0.00 | 3843465 |
| `oltp_point_select` | 8 | ON | 192031.84 | 192031.84 | 0.04 | 0.00 | 11616566 |
| `oltp_read_only` | 1 | OFF | 2215.34 | 35445.48 | 0.45 | 0.00 | 11616566 |
| `oltp_read_only` | 1 | ON | 2568.79 | 41100.70 | 0.39 | 0.00 | 13072512 |
| `oltp_read_only` | 8 | OFF | 6152.32 | 98437.09 | 1.30 | 0.00 | 13072512 |
| `oltp_read_only` | 8 | ON | 6214.34 | 99429.44 | 1.29 | 0.00 | 16621990 |

Calculated OFF/ON comparison:

| Workload | Threads | TPS change | QPS change | Avg latency change | Cached_plan_hits delta in ON case |
|---|---:|---:|---:|---:|---:|
| `oltp_point_select` | 1 | +20.57% | +20.57% | 0.00% | 3843465 |
| `oltp_point_select` | 8 | -3.29% | -3.29% | 0.00% | 7773101 |
| `oltp_read_only` | 1 | +15.96% | +15.96% | -13.33% | 1455946 |
| `oltp_read_only` | 8 | +1.01% | +1.01% | -0.77% | 3549478 |

Notes:

- `Cached_plan_hits` is a global cumulative counter in this build. The delta
  column above is computed from adjacent OFF/ON cases rather than treating the
  raw value as per-case.
- `Cached_plan_count` was `0` after each sysbench case because sysbench closed
  its prepared-statement connections before the status read.
- `Cached_plan_invalidations` stayed `0` during the benchmark.
- Sysbench reported `p95 latency ms` as `0.00` for these local runs, so p95 is
  not useful evidence from this run.
- The 8-thread point-select case regressed by 3.29% despite high hit growth.
  This needs repeated runs, CPU profiling, and longer sampling before any
  community performance claim.
- The strongest preliminary value signal is single-thread prepared point select
  and read-only SELECT execution, where ON improved throughput by 20.57% and
  15.96% respectively.

## Isolated Release Rerun

The first release run above was collected while other local work may have been
active. The benchmark was rerun after isolating the environment.

Environment:

```text
date: 2026-06-25 17:42 CST
HEAD: cd40bdc1e984d070ae53084f73400b1bb1c93a3c
server: build_plan_cache_release/sql/mariadbd
CMAKE_BUILD_TYPE: Release
WITH_ASAN: OFF
sysbench: 1.0.20
engine: InnoDB
tables: 8
table_size: 100000
prepared statements: --db-ps-mode=auto
warmup: 15s per main-matrix case
measure: 45s per main-matrix case
machine: 10 logical CPUs, 4 performance physical CPUs reported by sysctl
```

Main isolated matrix:

| Workload | Threads | OFF TPS | ON TPS | TPS change | CPU avg change | ON hit delta |
|---|---:|---:|---:|---:|---:|---:|
| `oltp_point_select` | 1 | 88432.67 | 90161.32 | +1.95% | -4.70% | 4057290 |
| `oltp_point_select` | 2 | 120488.29 | 115318.30 | -4.29% | -2.08% | 5189367 |
| `oltp_point_select` | 4 | 116932.99 | 125256.19 | +7.12% | +3.87% | 5636564 |
| `oltp_read_only` | 1 | 2063.07 | 2633.41 | +27.65% | -2.76% | 1659030 |
| `oltp_read_only` | 2 | 2886.17 | 3535.63 | +22.50% | -3.66% | 2227404 |
| `oltp_read_only` | 4 | 4186.46 | 4769.84 | +13.93% | -4.17% | 3004926 |

The 4-thread `oltp_read_only` run used less than three cores on average
(`mariadbd` ps CPU average 288.59% OFF and 276.56% ON), so it is still useful
as a pre-saturation multi-concurrency data point on this host.

Additional `oltp_point_select` repeat:

```text
workload: oltp_point_select
threads: 1, 2, 4
repeats: 3
warmup: 10s per case
measure: 30s per case
mode order: repeat 1 OFF->ON, repeat 2 ON->OFF, repeat 3 OFF->ON
```

| Threads | Repeat 1 TPS change | Repeat 2 TPS change | Repeat 3 TPS change | Median TPS change | Median CPU avg change |
|---:|---:|---:|---:|---:|---:|
| 1 | +9.08% | -1.06% | +18.42% | +9.08% | -1.82% |
| 2 | -13.93% | +8.51% | -1.18% | -1.18% | -2.66% |
| 4 | +23.73% | +4.67% | -17.35% | +4.67% | -1.47% |

Isolated-rerun conclusion:

- `oltp_read_only` shows consistent pre-saturation improvement at 1/2/4
  threads, with ON improving TPS by 13.93% to 27.65% and reducing average
  `mariadbd` CPU.
- `oltp_point_select` confirms high cache-hit growth, but TPS is not yet
  consistently improved across repeated pre-saturation runs. The 2-thread
  median is -1.18% despite lower average CPU.
- The current evidence supports the feature value for sysbench read-only SELECT
  mixes. It does not yet prove that pure point-select TPS improves consistently
  across all low-concurrency levels.
- The next performance task should profile the point-select hit path under
  2-thread and 4-thread runs, especially cache lookup, recipe rebuild, THD
  state transitions, and prepared-statement client scheduling overhead.

Publication status:

- Do not publish the current point-select data as evidence of stable gain.
- The `oltp_read_only` result is promising but still needs the fixed-rate
  repeated harness before it is community-grade.
- The next report should include median, p25/p75, coefficient of variation, CPU
  per event, and raw artifacts from a controlled Linux host.

## In-Memory Release Benchmark, 3 Repeats

This run follows the in-memory TPS/QPS plan: one data import, repeated ON/OFF
measurement, 10 GB buffer pool, and cache sizing intended to avoid table-cache
or definition-cache bottlenecks.

Environment:

```text
date: 2026-06-26 CST
artifact directory: /tmp/plan-cache-sysbench-20260626-113731
HEAD: ae7c726320ba299f615a8fb16c623bee12ef7ef4
server: build_plan_cache_release/sql/mariadbd
CMAKE_BUILD_TYPE: Release
WITH_ASAN: OFF
sysbench: 1.0.20
engine: InnoDB
tables: 250
table_size: 25000
buffer_pool_size: 10G
prepared statements: --db-ps-mode=auto
prewarm: 120s
measure: 300s per case
repeats: 3 complete repeats recorded
threads: 1, 2, 4, 8, 16
read_only_extra_args: --skip-trx=1
mode order: odd repeats OFF->ON, even repeats ON->OFF
sysbench SQL ignore errors: not set
CPU set isolation: not set on macOS
```

Server options:

```text
--innodb-buffer-pool-size=10G
--table-open-cache=65536
--table-definition-cache=65536
--table-open-cache-instances=16
--thread-cache-size=512
```

Aggregated `oltp_read_only` result:

| Workload | Threads | OFF avg QPS | ON avg QPS | Median QPS change | Per-repeat QPS change range | Min ON hit delta | ON invalid delta |
|---|---:|---:|---:|---:|---:|---:|---:|
| `oltp_read_only` | 1 | 30022.70 | 35622.93 | +21.66% | +10.06%..+24.32% | 9957580 | 0 |
| `oltp_read_only` | 2 | 44876.87 | 53964.34 | +18.77% | +16.99%..+25.55% | 15590714 | 0 |
| `oltp_read_only` | 4 | 51534.17 | 58172.35 | +11.80% | +11.69%..+15.21% | 17007380 | 0 |
| `oltp_read_only` | 8 | 68992.17 | 77135.06 | +11.28% | +10.75%..+13.42% | 22540080 | 0 |
| `oltp_read_only` | 16 | 71109.34 | 76804.48 | +7.88% | +7.71%..+8.43% | 22846998 | 0 |

Aggregated `oltp_point_select` result:

| Workload | Threads | OFF avg QPS | ON avg QPS | Median QPS change | Per-repeat QPS change range | Min ON hit delta | ON invalid delta |
|---|---:|---:|---:|---:|---:|---:|---:|
| `oltp_point_select` | 1 | 76519.79 | 88576.36 | +18.20% | +10.80%..+19.12% | 25502462 | 0 |
| `oltp_point_select` | 2 | 101475.58 | 107749.50 | +8.57% | +1.45%..+9.22% | 31241001 | 0 |
| `oltp_point_select` | 4 | 103216.79 | 108796.08 | +5.32% | +1.81%..+9.55% | 31860099 | 0 |
| `oltp_point_select` | 8 | 136365.95 | 140109.52 | +2.37% | +1.80%..+4.08% | 40535088 | 0 |
| `oltp_point_select` | 16 | 132201.42 | 133382.77 | +0.98% | -2.99%..+4.80% | 38854773 | 0 |

Interpretation:

- `oltp_read_only` is now the strongest value proof. It is positive in every
  repeat and at every tested concurrency, and ON cases show millions of
  `Cached_plan_hits` with `Cached_plan_invalidations=0`.
- `oltp_point_select` is useful supporting evidence at low concurrency, but it
  should not be the headline claim. The 16-thread range includes one negative
  repeat, and the median gain is only +0.98%.
- The ON/OFF comparison is more useful than cross-thread linearity on this
  host. sysbench and `mariadbd` run on the same macOS machine without hard CPU
  partitioning, so client/server scheduling and shared hot paths affect scaling.
- The community-ready benchmark should repeat this exact method on Linux with
  `SERVER_CPUSET` and `SYSBENCH_CPUSET` set in
  `in_memory_sysbench_harness.sh`.

## Current HEAD Sanity Benchmark

After the range workspace cleanup commits, a short release sanity benchmark was
run to check that the main ON/OFF direction still holds. This is not a formal
publication result; it uses one repeat and 60 second windows.

Environment:

```text
date: 2026-06-26 CST
artifact directory: /tmp/plan-cache-sanity-20260626-165943
HEAD: ef0145b71830705fcc28820f7a067cfc07992627
server: build_plan_cache_release/sql/mariadbd
CMAKE_BUILD_TYPE: Release
WITH_ASAN: OFF
tables: 64
table_size: 50000
buffer_pool_size: 10G
prewarm: 30s
measure: 60s per case
threads: 1, 2, 4
sysbench SQL ignore errors: not set
CPU set isolation: not set on macOS
```

| Workload | Threads | OFF QPS | ON QPS | QPS change | OFF avg latency ms | ON avg latency ms | CPU avg change | ON hit delta | ON invalid delta |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `oltp_point_select` | 1 | 80387.03 | 92153.99 | +14.64% | 0.01 | 0.01 | -13.39% | 5529219 | 0 |
| `oltp_point_select` | 2 | 131272.14 | 129388.52 | -1.43% | 0.02 | 0.02 | -2.80% | 7763252 | 0 |
| `oltp_point_select` | 4 | 126250.37 | 127168.23 | +0.73% | 0.03 | 0.03 | -0.82% | 7629929 | 0 |
| `oltp_read_only` | 1 | 31591.15 | 39142.31 | +23.90% | 0.44 | 0.36 | -8.11% | 2348264 | 0 |
| `oltp_read_only` | 2 | 53882.76 | 62622.95 | +16.22% | 0.52 | 0.45 | -5.90% | 3756820 | 0 |
| `oltp_read_only` | 4 | 61209.01 | 69168.41 | +13.00% | 0.91 | 0.81 | -6.74% | 4149020 | 0 |

Sanity conclusion:

- The current HEAD still shows clear `oltp_read_only` value at 1/2/4 threads.
- `oltp_point_select` remains noisy and should stay supporting evidence only.
- ON cases have hit growth and `Cached_plan_invalidations=0`.
