# Test Report

## Latest Evidence Snapshot: 2026-06-27

Current documentation snapshot is based on the rewritten
`plan_cache_community_series` branch. The code and test file contents match the
original `plan_cache` development branch after `d48e0842d77d`, but final
verification must be rerun on the rewritten branch before PR.

Current tree inventory:

- 29 `mysql-test/main/session_plan_cache*.test` files;
- 2 `mysql-test/suite/sys_vars/t/session_plan_cache*.test` files;
- final-HEAD focused MTR, broader prepared-statement regression, and ASAN/LSAN
  still need to be rerun and recorded before a MariaDB PR.

Performance evidence status:

- local release `oltp_read_only` evidence is positive and shows plan-cache hits;
- the 2026-06-27 local value run used profile collection and is diagnostic, not
  a publishable headline run;
- publishable performance evidence still requires Linux release runs with
  separated server/sysbench CPU sets, longer duration, repeated off/on pairs,
  and captured environment.

## Current Local Evidence

Repository:

```text
/Users/zhuqingping/Work/Database/MariaDB/server-plan-cache
```

Branch:

```text
plan_cache
```

Recorded:

```text
2026-06-26 19:56 CST
```

HEAD at validation time:

```text
20cd20c36a3
```

Working tree at validation time:

```text
 m storage/duckdb/third_parties/duckdb
?? build_plan_cache_release/
```

The tracked source and MTR files were clean before this documentation refresh.
The only pre-existing unrelated dirty state was
`storage/duckdb/third_parties/duckdb`. The release build directory was local
test output and is not part of the patch.

The focused validation was rerun after the public variables and MTR names were
renamed to the neutral `session_plan_cache` prefix.

## Build

Command:

```bash
cmake --build build_plan_cache_debug --target mariadbd --parallel 16
```

Result:

```text
PASS
[100%] Built target mariadbd
```

## Release Build For Benchmark

Configure command:

```bash
cmake -S . -B build_plan_cache_release \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/Users/zhuqingping/Work/Database/MariaDB/server-plan-cache/install_release \
  -DBISON_EXECUTABLE=/opt/homebrew/opt/bison/bin/bison \
  -DWITH_SSL=system \
  -DWITH_UNIT_TESTS=OFF \
  -DWITH_ASAN=OFF
```

Build commands:

```bash
cmake --build build_plan_cache_release --target mariadbd mariadb mariadb-admin --parallel 16
cmake --build build_plan_cache_release --target my_print_defaults --parallel 16
```

Result:

```text
PASS: release mariadbd, mariadb, mariadb-admin, my_print_defaults built
CMAKE_BUILD_TYPE=Release
WITH_ASAN=OFF
CMAKE_HOME_DIRECTORY=/Users/zhuqingping/Work/Database/MariaDB/server-plan-cache
mariadbd version: 13.1.0-MariaDB for osx10.21 on arm64
```

## Focused Plan-Cache MTR

Command:

```bash
cd build_plan_cache_debug/mysql-test
(
  MTR_BASE=/tmp/mariadb-mtr-plan-cache-all-$(date +%Y%m%d-%H%M%S)-$$
  trap 'rm -rf "$MTR_BASE"' EXIT
  mkdir -p "$MTR_BASE/tmp" "$MTR_BASE/var"
  TESTS=($(cd ../../mysql-test/main && ls session_plan_cache*.test | \
    sed 's/\.test$//' | sed 's/^/main./'))
  TMPDIR="$MTR_BASE/tmp" ./mtr \
    sys_vars.session_plan_cache_basic \
    sys_vars.session_plan_cache_allow_change_ratio \
    "${TESTS[@]}" \
    --parallel=1 --vardir="$MTR_BASE/var" --tmpdir="$MTR_BASE/tmp"
)
```

Result:

```text
PASS: all 27 main.session_plan_cache* tests at the historical validation HEAD
PASS: sys_vars.session_plan_cache_basic
PASS: sys_vars.session_plan_cache_allow_change_ratio
Completed: All 29 tests were successful.
```

The run used an isolated `/tmp` MTR base directory and removed it on exit.

Latest recorded rerun:

```text
PASS: all 27 main.session_plan_cache* tests plus 2 sys_vars tests at the
historical validation HEAD
Server restarts during run: 1
MTR base: /tmp/mariadb-mtr-plan-cache-all-20260626-195434-95075
Cleanup: temporary MTR base removed after run
```

## Help Output MTR

Command:

```bash
cd build_plan_cache_debug/mysql-test
TMPDIR="$MTR_BASE/tmp" ./mtr main.mysqld--help \
  --vardir="$MTR_BASE/var" --tmpdir="$MTR_BASE/tmp"
```

Result:

```text
PASS: main.mysqld--help
Completed: All 1 tests were successful.
```

## Sysbench Smoke

Command shape:

```bash
sysbench /opt/homebrew/share/sysbench/oltp_point_select.lua \
  --db-driver=mysql \
  --mysql-socket=<MTR socket> \
  --mysql-user=root \
  --mysql-db=sbtest \
  --tables=1 \
  --table-size=1000 \
  --mysql-storage-engine=MyISAM \
  --threads=1 \
  --events=100 \
  --time=0 \
  --db-ps-mode=auto \
  run
```

Result:

```text
PASS: plan cache off Cached_plan_hits=0
PASS: plan cache on Cached_plan_hits=99
PASS: Cached_plan_count returned to 0 after sysbench disconnect
off smoke summary: 100 transactions, 100 queries, avg latency 0.04 ms
on smoke summary: 100 transactions, 100 queries, avg latency 0.04 ms
```

This is a functional smoke test on an MTR server using MyISAM because the
minimal `main.1st` MTR server configuration used for the smoke did not load
InnoDB. It is not a substitute for formal InnoDB sysbench evidence.

## Release Sysbench Benchmark

Command shape:

```bash
sysbench /opt/homebrew/share/sysbench/<workload>.lua \
  --mysql-socket=<release socket> \
  --mysql-user=root \
  --mysql-db=sbtest \
  --mysql-ignore-errors=all \
  --db-driver=mysql \
  --db-ps-mode=auto \
  --mysql-storage-engine=innodb \
  --tables=4 \
  --table-size=100000 \
  --rand-type=uniform \
  --threads=<1 or 8> \
  --time=30 \
  --events=0 \
  run
```

Server:

```text
build_plan_cache_release/sql/mariadbd
Release build, WITH_ASAN=OFF
Temporary base: /tmp/mariadb-plan-cache-release-sysbench-<timestamp>-<pid>
Cleanup: shutdown server and removed temporary base on exit
```

First release result summary:

| Workload | Threads | OFF TPS | ON TPS | TPS change | ON hit delta |
|---|---:|---:|---:|---:|---:|
| `oltp_point_select` | 1 | 79769.61 | 96174.50 | +20.57% | 3843465 |
| `oltp_point_select` | 8 | 198562.67 | 192031.84 | -3.29% | 7773101 |
| `oltp_read_only` | 1 | 2215.34 | 2568.79 | +15.96% | 1455946 |
| `oltp_read_only` | 8 | 6152.32 | 6214.34 | +1.01% | 3549478 |

Interpretation:

- The release benchmark confirms the feature is exercised by sysbench prepared
  SELECT workloads and produces large hit growth in ON cases.
- Single-thread point select and read-only cases show clear preliminary
  throughput improvement.
- The 8-thread point-select case regressed in this single local run and needs
  repeated longer-duration profiling before making a broad performance claim.
- No debug or ASAN binary was used for the performance data above.

Isolated rerun summary:

| Workload | Threads | OFF TPS | ON TPS | TPS change | CPU avg change | ON hit delta |
|---|---:|---:|---:|---:|---:|---:|
| `oltp_point_select` | 1 | 88432.67 | 90161.32 | +1.95% | -4.70% | 4057290 |
| `oltp_point_select` | 2 | 120488.29 | 115318.30 | -4.29% | -2.08% | 5189367 |
| `oltp_point_select` | 4 | 116932.99 | 125256.19 | +7.12% | +3.87% | 5636564 |
| `oltp_read_only` | 1 | 2063.07 | 2633.41 | +27.65% | -2.76% | 1659030 |
| `oltp_read_only` | 2 | 2886.17 | 3535.63 | +22.50% | -3.66% | 2227404 |
| `oltp_read_only` | 4 | 4186.46 | 4769.84 | +13.93% | -4.17% | 3004926 |

Additional point-select repeat median:

| Threads | Median TPS change | Median CPU avg change |
|---:|---:|---:|
| 1 | +9.08% | -1.82% |
| 2 | -1.18% | -2.66% |
| 4 | +4.67% | -1.47% |

Latest interpretation:

- `oltp_read_only` shows consistent positive pre-saturation gain at 1/2/4
  threads.
- `oltp_point_select` is still noisy and does not yet prove consistent TPS
  improvement across all low-concurrency levels.
- No debug or ASAN binary was used for either release benchmark.
- These results are not yet community-grade performance evidence. The next
  benchmark round should use the fixed-rate and repeated-run harness documented
  in `benchmark_stabilization_plan.md`.

In-memory release rerun, 3 repeats:

```text
date: 2026-06-26 CST
artifact directory: /tmp/plan-cache-sysbench-20260626-113731
HEAD: ae7c726320ba299f615a8fb16c623bee12ef7ef4
server: build_plan_cache_release/sql/mariadbd
CMAKE_BUILD_TYPE: Release
WITH_ASAN: OFF
sysbench: 1.0.20
tables: 250
table_size: 25000
buffer_pool_size: 10G
prewarm: 120s
measure: 300s per case
repeats: 3 complete repeats recorded
threads: 1, 2, 4, 8, 16
server cache options: table_open_cache=65536, table_definition_cache=65536,
  table_open_cache_instances=16, thread_cache_size=512
CPU set isolation: not set on macOS
sysbench SQL ignore errors: not set
```

`oltp_read_only` summary:

| Threads | OFF avg QPS | ON avg QPS | Median QPS change | Per-repeat QPS change range | Min ON hit delta | ON invalid delta |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 30022.70 | 35622.93 | +21.66% | +10.06%..+24.32% | 9957580 | 0 |
| 2 | 44876.87 | 53964.34 | +18.77% | +16.99%..+25.55% | 15590714 | 0 |
| 4 | 51534.17 | 58172.35 | +11.80% | +11.69%..+15.21% | 17007380 | 0 |
| 8 | 68992.17 | 77135.06 | +11.28% | +10.75%..+13.42% | 22540080 | 0 |
| 16 | 71109.34 | 76804.48 | +7.88% | +7.71%..+8.43% | 22846998 | 0 |

`oltp_point_select` summary:

| Threads | OFF avg QPS | ON avg QPS | Median QPS change | Per-repeat QPS change range | Min ON hit delta | ON invalid delta |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 76519.79 | 88576.36 | +18.20% | +10.80%..+19.12% | 25502462 | 0 |
| 2 | 101475.58 | 107749.50 | +8.57% | +1.45%..+9.22% | 31241001 | 0 |
| 4 | 103216.79 | 108796.08 | +5.32% | +1.81%..+9.55% | 31860099 | 0 |
| 8 | 136365.95 | 140109.52 | +2.37% | +1.80%..+4.08% | 40535088 | 0 |
| 16 | 132201.42 | 133382.77 | +0.98% | -2.99%..+4.80% | 38854773 | 0 |

Latest release-performance conclusion:

- `oltp_read_only` is consistently positive at 1/2/4/8/16 threads across all
  three repeats and is the current primary value evidence.
- `oltp_point_select` is positive at 1/2/4/8 threads, but the 16-thread range
  includes one negative repeat. Keep it as supporting evidence, not the headline
  claim.
- ON cases show large `Cached_plan_hits` and `Cached_plan_invalidations=0`.
- The run used the release build only. It still lacks Linux CPU-set isolation,
  so it is engineering evidence rather than final community-grade evidence.

Current HEAD sanity run:

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
```

| Workload | Threads | OFF QPS | ON QPS | QPS change | CPU avg change | ON hit delta | ON invalid delta |
|---|---:|---:|---:|---:|---:|---:|---:|
| `oltp_point_select` | 1 | 80387.03 | 92153.99 | +14.64% | -13.39% | 5529219 | 0 |
| `oltp_point_select` | 2 | 131272.14 | 129388.52 | -1.43% | -2.80% | 7763252 | 0 |
| `oltp_point_select` | 4 | 126250.37 | 127168.23 | +0.73% | -0.82% | 7629929 | 0 |
| `oltp_read_only` | 1 | 31591.15 | 39142.31 | +23.90% | -8.11% | 2348264 | 0 |
| `oltp_read_only` | 2 | 53882.76 | 62622.95 | +16.22% | -5.90% | 3756820 | 0 |
| `oltp_read_only` | 4 | 61209.01 | 69168.41 | +13.00% | -6.74% | 4149020 | 0 |

This run is a short release sanity check after the latest range workspace
cleanup. It confirms the current HEAD preserves the main `oltp_read_only`
benefit and keeps `Cached_plan_invalidations=0`; it is not a replacement for
Linux CPU-set isolated community evidence.

## Broader Prepared-Statement Regression

Command:

```bash
cd build_plan_cache_debug/mysql-test
(
  MTR_BASE=/tmp/mariadb-mtr-plan-cache-broader-ps-$(date +%Y%m%d-%H%M%S)-$$
  trap 'rm -rf "$MTR_BASE"' EXIT
  mkdir -p "$MTR_BASE/tmp" "$MTR_BASE/var"
  TMPDIR="$MTR_BASE/tmp" ./mtr \
    main.prepare \
    main.ps \
    main.ps_1general \
    main.ps_2myisam \
    main.ps_3innodb \
    main.ps_4heap \
    main.ps_5merge \
    main.ps_10nestset \
    main.ps_11bugs \
    main.ps_ddl \
    main.ps_ddl1 \
    main.ps_error \
    main.ps_grant \
    main.ps_innodb \
    main.ps_missed_cmds \
    main.ps_missed_cmds_not_embedded \
    main.ps_not_windows \
    main.information_schema_prepare \
    main.show_explain_ps \
    --parallel=1 --force --vardir="$MTR_BASE/var" --tmpdir="$MTR_BASE/tmp"
)
```

Result:

```text
PASS: all 19 prepared-statement related tests
Completed: All 19 tests were successful.
Server restarts during run: 3
MTR base: /tmp/mariadb-mtr-plan-cache-broader-ps-<timestamp>-<pid>
Cleanup: trap removed MTR base on exit
```

## Benchmark Harness Smoke

On 2026-06-26 CST, the committed release sysbench harness was run with a tiny
dataset to verify the artifact chain only. This is not performance evidence.

Command shape:

```bash
OUT_DIR=/tmp/plan-cache-harness-smoke-20260626-183322 \
TABLES=2 TABLE_SIZE=1000 THREADS="1" WORKLOADS="oltp_read_only" \
BUFFER_POOL_SIZE=256M PREWARM_TIME=1 RUN_TIME=3 REPEATS=1 REPORT_INTERVAL=1 \
Docs/plan_cache_community/in_memory_sysbench_harness.sh
```

Result:

```text
summary.tsv generated
summary_analysis.md generated
ON live Cached_plan_count max: 10
ON Cached_plan_hits grew during the run
ON Cached_plan_invalidations: 0
temporary datadir cleanup: verified
```

`summary_analysis.md` classified `oltp_read_only:t1` as a `Primary Candidate`.
The classification is useful as a harness sanity check; the numbers are too
short and too small to publish.

The fixed-rate harness was also smoke-tested with the same tiny dataset:

```bash
OUT_DIR=/tmp/plan-cache-fixed-harness-smoke-20260626-183709 \
TABLES=2 TABLE_SIZE=1000 THREADS="1" WORKLOADS="oltp_read_only" \
BUFFER_POOL_SIZE=256M CALIBRATE_TIME=2 WARMUP_TIME=1 MEASURE_TIME=3 REPEATS=1 \
Docs/plan_cache_community/reproducible_sysbench_harness.sh
```

Result:

```text
fixed_rate_summary.tsv generated
fixed_rate_analysis.md generated
closed_loop_summary.tsv generated
closed_loop_analysis.md generated
fixed-rate ON live Cached_plan_count max: 10
fixed-rate ON Cached_plan_invalidations: 0
temporary datadir cleanup: verified
```

The smoke confirmed the analyzer can classify fixed-rate efficiency: at the
same offered load, CPU/kQPS decreased in the ON case and the row was classified
as a `Primary Candidate`. This validates the artifact pipeline only; the run is
too short to publish.

The suite wrapper was then smoke-tested for the remaining modes:

```text
SUITE_MODE=shapes     -> /tmp/plan-cache-shapes-20260626-185129
SUITE_MODE=fixed      -> /tmp/plan-cache-fixed-20260626-185149
SUITE_MODE=diagnostic -> /tmp/plan-cache-linearity-20260626-185222
```

Result:

```text
shapes summary_analysis.md generated
fixed fixed_rate_analysis.md and closed_loop_analysis.md generated
diagnostic results.tsv generated
temporary datadir cleanup: verified
```

The shapes smoke classified `oltp_read_only:distinct_range:t1` as a strong
supporting case, confirming that the wrapper passes `READ_ONLY_SHAPES` through
to the underlying harness. The fixed-rate smoke produced a positive
CPU/kQPS-efficiency signal but stayed below the default primary threshold,
which is expected for a tiny two-second run.

After adding the formal primary evidence gate, the suite wrapper was smoke-tested
again with a tiny primary run and the gate explicitly disabled for smoke only:

```bash
ARTIFACT_ROOT=/tmp \
FORMAL_CPUSET_REQUIRED=0 STRICT_CPUSET=0 \
SUITE_MODE=primary PRIMARY_GATE_THREADS= \
TABLES=1 TABLE_SIZE=100 THREADS="1" \
BUFFER_POOL_SIZE=256M PREWARM_TIME=1 RUN_TIME=2 REPEATS=1 REPORT_INTERVAL=1 \
Docs/plan_cache_community/run_sysbench_benchmark_suite.sh
```

The first run exposed that an explicitly empty `PRIMARY_GATE_THREADS` was still
replaced by the formal default.  The wrapper was fixed to preserve an explicit
empty value, and the rerun completed with exit code 0.

Result:

```text
Artifact directory: /tmp/plan-cache-primary-20260626-200923
primary_gate_analysis.md: not generated because PRIMARY_GATE_THREADS was empty
final_plan_cache_status.tsv generated
final Cached_plan_count: 0
final Cached_plan_invalidations: 0
mariadbd_error_summary.txt generated and empty
temporary datadir cleanup: verified
```

This smoke validates the artifact chain and smoke-only gate override.  It is not
performance evidence.

After adding `run_manifest.txt`, the same tiny primary smoke was rerun:

```text
Artifact directory: /tmp/plan-cache-primary-20260626-201232
run_manifest.txt generated
manifest build_type: Release
manifest WITH_ASAN: OFF
manifest formal_cpuset_required: 0
manifest sysbench_common includes --db-ps-mode=auto and InnoDB settings
final Cached_plan_count: 0
mariadbd_error_summary.txt generated and empty
temporary artifact directory cleanup: verified
```

This validates that the harness records the command and environment skeleton
needed for later Linux benchmark review.

The artifact summary helper was smoke-tested with a synthetic primary artifact
directory containing `run_manifest.txt`, `summary.tsv`,
`primary_gate_analysis.md`, `final_plan_cache_status.tsv`, and an empty
`mariadbd_error_summary.txt`.

Result:

```text
summarize_benchmark_artifacts.py generated Markdown
Primary gate: PASS
Final plan-cache status: count=0, hits=10000, invalidations=0
Error-log summary: empty
```

The helper was then smoke-tested with a synthetic fixed-rate artifact that
contains both `fixed_rate_summary.tsv` and `closed_loop_summary.tsv`.

Result:

```text
fixed_rate_summary.tsv section generated
closed_loop_summary.tsv section generated
fixed:oltp_read_only:t1:rate1000 row generated
closed:oltp_read_only:t1:rate0 row generated
```

The helper was also smoke-tested with synthetic detail files to verify
repeat-level stability output:

```text
results.tsv repeat-level signals generated
fixed_rate.tsv repeat-level signals generated
closed_loop.tsv repeat-level signals generated
QPS positive and CPU/kQPS positive counts matched the synthetic inputs
```

The helper was then smoke-tested with synthetic risk and clean artifacts to
verify `Review Signals`:

```text
risk artifact: gate failure, invalidations, missing hits/live count, QPS
  regression, CPU/kQPS regression, final count leak, and non-empty error
  summary were reported
clean artifact: "No immediate risk signals detected" was reported
```

The helper was then smoke-tested with synthetic manifest variants to verify
formal benchmark audit signals:

```text
risk manifest: formal CPU-set gate disabled, overlapping CPU sets, non-Release
  build, and ASAN enabled were reported
clean manifest: Release, ASAN off, formal CPU-set gate enabled, and disjoint
  CPU sets produced no immediate risk signal
```

The summary helper exit-code gate was smoke-tested with synthetic clean and
risk artifacts:

```text
default summary mode on risk artifact: exit 0
--fail-on-review-signals on clean artifact: exit 0
--fail-on-review-signals on risk artifact: exit 4
```

The helper was also smoke-tested with a synthetic shape artifact to verify
`Opportunity Signals`:

```text
Strongest QPS Gains included oltp_read_only:distinct_range:t1
Best CPU/kQPS Improvements included oltp_read_only:distinct_range:t1
Weakest Valid Cases included oltp_read_only:point:t1
```

The helper was then smoke-tested with synthetic positive and risk artifacts to
verify `Next Actions`:

```text
positive artifact: recommended updating the benchmark report, using
  distinct_range as the first attribution case, and using fixed-rate CPU/kQPS
  data as efficiency evidence
risk artifact: recommended resolving Review Signals first and treating the weak
  valid point case as the next profiling queue before production-code changes
```

After wiring the artifact summary helper into `run_sysbench_benchmark_suite.sh`,
the tiny primary smoke was rerun with the primary gate disabled for smoke only.

Result:

```text
Artifact directory: /tmp/plan-cache-primary-20260626-202830
benchmark_artifact_summary.md generated automatically
summary contained Opportunity Signals, Next Actions, and Review Signals
final Cached_plan_count: 0
mariadbd_error_summary.txt generated and empty
temporary artifact directory cleanup: verified
```

The in-memory harness profile/status collection mode was smoke-tested with a
tiny single-shape run:

```bash
COLLECT_PROFILE_STATUS=1 \
ARTIFACT_ROOT=/tmp \
SUITE_MODE=shapes \
TABLES=1 TABLE_SIZE=1000 SHAPE_THREADS="1" READ_ONLY_SHAPES="simple_range" \
BUFFER_POOL_SIZE=256M PREWARM_TIME=1 RUN_TIME=2 REPEATS=1 STRICT_CPUSET=0 \
Docs/plan_cache_community/run_sysbench_benchmark_suite.sh
```

Result:

```text
output: /tmp/plan-cache-shapes-20260626-190310
raw/*.status_before.tsv generated
raw/*.status_after.tsv generated
raw/*.status_delta.tsv generated
ON Cached_plan_hits delta: 48444
ON Cached_plan_invalidations delta: 0
ON profile counters included Cached_plan_profile_hit_range_* fields
ON status counters included Handler_read_*, Created_tmp_*, and table-cache fields
```

The profile-status analyzer was then wired into the harness and smoke-tested
with another tiny run:

```text
output: /tmp/plan-cache-shapes-20260626-190647
profile_status_analysis.md generated
top ON hotspot: Cached_plan_profile_hit_path_us ~= 0.514 us/hit
next ON hotspots: range_build ~= 0.467 us/hit, range_setup ~= 0.287 us/hit
```

The same analyzer was used for a short current-HEAD shape profile matrix:

```text
output: /tmp/plan-cache-shape-profile-20260626-190913
HEAD: d71c08d0a23
shapes: point simple_range sum_range order_range distinct_range
threads: 1
measure: 5s per case
COLLECT_PROFILE_STATUS=1
```

Result:

```text
profile_status_analysis.md generated
all ON cases had Cached_plan_hits growth and zero invalidations
top remaining per-hit costs were range build/setup, especially DISTINCT/ORDER
point hit path was much cheaper than range hit path
```

The analyzer advice section classified the same run as:

```text
distinct_range: data-triggered-distinct-design
order_range:    order-range-monitor
point:          point-low-priority
simple/sum:     range-low-risk-exhausted
```

This validates the root-cause artifact chain only. `COLLECT_PROFILE_STATUS=1`
enables `session_plan_cache_profile` and should remain disabled for headline
QPS/TPS performance runs.

A matching 4-thread current-HEAD shape profile was also collected:

```text
output: /tmp/plan-cache-shape-profile-t4-20260626-191644
HEAD: d71c08d0a23
shapes: point simple_range sum_range order_range distinct_range
threads: 4
measure: 5s per case
COLLECT_PROFILE_STATUS=1
```

Result:

```text
profile_status_analysis.md generated
all ON cases had Cached_plan_hits growth and zero invalidations
QPS deltas:
  point:          +5.12%
  simple_range:  +12.04%
  sum_range:     +7.14%
  order_range:   +1.59%
  distinct_range:+59.57%
top remaining per-hit costs remained range build/setup, especially DISTINCT
```

The 4-thread profile preserves the 1-thread optimization priority: DISTINCT
range is the only current data-triggered design candidate, ORDER range should
be monitored with longer Linux data, and point/ref micro-optimizations should
not be prioritized before final benchmark evidence.

After adding `SUITE_MODE=formal`, the suite wrapper was smoke-tested with a
tiny release run to verify the orchestration flow only:

```bash
ARTIFACT_ROOT=/tmp FORMAL_CPUSET_REQUIRED=0 STRICT_CPUSET=0 \
SUITE_MODE=formal PRIMARY_GATE_THREADS= \
TABLES=1 TABLE_SIZE=100 THREADS="1" SHAPE_THREADS="1" \
READ_ONLY_SHAPES="point" \
BUFFER_POOL_SIZE=256M PREWARM_TIME=1 RUN_TIME=1 REPEATS=1 \
REPORT_INTERVAL=1 CALIBRATE_TIME=1 \
Docs/plan_cache_community/run_sysbench_benchmark_suite.sh
```

Result:

```text
formal artifact root: /tmp/plan-cache-formal-20260626-203619
child primary, shape, and fixed-rate artifact directories generated
top-level benchmark_artifact_summary.md generated
summary included primary, shape, fixed-rate, closed-loop, Opportunity Signals,
  Next Actions, and Review Signals sections
temporary artifact directory cleanup: verified
```

The fixed-rate and closed-loop analyzers reported invalid evidence rows in this
one-second smoke, which is expected and confirms that the review signals remain
visible.  This run used smoke-only CPU-set overrides and is not performance
evidence.

The profile comparison helper was smoke-tested with a synthetic pair and then
used against the real 1-thread and 4-thread profile outputs:

```bash
Docs/plan_cache_community/compare_profile_status.py \
  --top 25 \
  --label-a t1 /tmp/plan-cache-shape-profile-20260626-190913/raw/*_ON_*.status_delta.tsv \
  --label-b t4 /tmp/plan-cache-shape-profile-t4-20260626-191644/raw/*_ON_*.status_delta.tsv
```

Result:

```text
PASS: normalized t1/t4 cases were matched by shape
PASS: per-hit deltas were generated for range build/setup/explain counters
PASS: candidate signals highlighted DISTINCT setup/explain and point low-priority
PASS: --top 5 still emitted candidate signals outside the displayed top rows
```

## DISTINCT Range Candidate Gate

After narrowing the next possible code candidate to exact DISTINCT range
setup/explain, the focused MTR gate was rerun at:

```text
HEAD: 4f990c34c41
build: build_plan_cache_debug
MTR base: /tmp/mariadb-mtr-distinct-gate-agg-20260626-195242-94878
cleanup: temporary MTR base removed after run
```

Command:

```bash
cd build_plan_cache_debug/mysql-test
TMPDIR="$MTR_BASE/tmp" ./mtr \
  main.session_plan_cache_sysbench_coverage \
  main.session_plan_cache_distinct_range_result \
  main.session_plan_cache_distinct_range_boundary \
  main.session_plan_cache_distinct_range_profile \
  main.session_plan_cache_explain_analyze_boundary \
  main.session_plan_cache_debug_fault_injection \
  --parallel=1 --vardir="$MTR_BASE/var" --tmpdir="$MTR_BASE/tmp"
```

Result:

```text
PASS: main.session_plan_cache_debug_fault_injection
PASS: main.session_plan_cache_distinct_range_boundary
PASS: main.session_plan_cache_distinct_range_profile
PASS: main.session_plan_cache_distinct_range_result
PASS: main.session_plan_cache_explain_analyze_boundary
PASS: main.session_plan_cache_sysbench_coverage
Completed: All 6 tests were successful.
Server restarts during run: 0
```

This gate now covers exact DISTINCT range result correctness, real hit counts,
profile counter growth, fail-closed non-exact shapes including extra selected
columns, GROUP BY, HAVING, window functions, and aggregate GROUP BY,
EXPLAIN/ANALYZE no-cache boundaries, and existing DISTINCT fault-injection
rollback paths.

## Unique/Ref Hit Profile Gate

After the point/ref hit path was identified as the next profiling target,
diagnostic counters were added for unique/ref hit rebuild attribution:

```text
Cached_plan_profile_hit_unique_alloc_us
Cached_plan_profile_hit_unique_setup_plan_us
Cached_plan_profile_hit_ref_alloc_us
Cached_plan_profile_hit_ref_setup_us
```

Validation:

```bash
cd build_plan_cache_debug/mysql-test
TMPDIR="$MTR_BASE/tmp" ./mtr \
  main.session_plan_cache_unique_profile \
  main.session_plan_cache_ref_profile \
  main.session_plan_cache_status \
  main.session_plan_cache_sysbench_coverage \
  --parallel=1 --vardir="$MTR_BASE/var" --tmpdir="$MTR_BASE/tmp"
```

Result:

```text
PASS: main.session_plan_cache_ref_profile
PASS: main.session_plan_cache_sysbench_coverage
PASS: main.session_plan_cache_unique_profile
PASS: main.session_plan_cache_status
Completed: All 4 tests were successful.
Server restarts during run: 1
MTR base: /tmp/mariadb-mtr-hit-profile-split-20260626-204923-5508
Cleanup: temporary MTR base removed after run
```

The counters are active only when `session_plan_cache_profile=ON`; headline
sysbench QPS/TPS runs should keep profile disabled.

## Short Release Profile Sanity

After adding the unique/ref profile split, a short release-only shape check was
run twice: first with `COLLECT_PROFILE_STATUS=1`, then with profile collection
disabled.  This was a diagnostic run only, not community-grade evidence.

Profile-enabled artifact:

```text
/tmp/plan-cache-shapes-20260626-205135
```

Profile-disabled artifact:

```text
/tmp/plan-cache-shapes-20260626-205416
```

Common setup:

```text
Build: Release
ASAN: OFF
tables: 8
table_size: 5000
threads: 1 4
run_time: 15s
repeats: 1
read_only_shapes: point simple_range
```

Profile-enabled result:

```text
point:t1        +6.96% QPS
point:t4       -16.42% QPS
simple_range:t1 +10.21% QPS
simple_range:t4  +1.27% QPS
```

Profile hotspots showed point hit-path cost below 0.28 us/hit and unique alloc
below 0.10 us/hit, while the point t4 row regressed.  The no-profile rerun
changed point t4 back to a positive QPS result:

```text
point:t1        +24.28% QPS, -52.69% CPU/kQPS
point:t4        +12.07% QPS,  +3.23% CPU/kQPS
simple_range:t1 +10.70% QPS, -23.06% CPU/kQPS
simple_range:t4  +3.90% QPS,  -1.24% CPU/kQPS
```

Current interpretation: profile collection can perturb very small point-query
measurements.  A point/ref code optimization should require a matching
profile-disabled or fixed-rate regression, not a profile-enabled QPS regression
alone.

## Current HEAD Primary Release Check

A profile-disabled release primary benchmark was run after the unique/ref
profile split to verify that the default performance path still shows value.
This is local macOS engineering evidence, not community-grade Linux CPU-set
evidence.

Artifact:

```text
/tmp/plan-cache-primary-20260626-205939
```

Setup:

```text
Build: Release
ASAN: OFF
tables: 64
table_size: 10000
buffer_pool_size: 4G
threads: 1 2 4 8
run_time: 60s
repeats: 3
workload: oltp_read_only
profile collection: OFF
CPU binding: not available on this macOS host
```

Median result:

```text
t1  +29.64% QPS, -34.31% CPU/kQPS, 3/3 positive repeats
t2  +21.38% QPS, -24.12% CPU/kQPS, 3/3 positive repeats
t4  +13.47% QPS, -18.12% CPU/kQPS, 3/3 positive repeats
t8  +14.21% QPS, -15.64% CPU/kQPS, 3/3 positive repeats
```

Plan-cache status evidence:

```text
ON hit median by thread: 2461594, 4415072, 4756522, 6753672
Cached_plan_invalidations: 0
Final Cached_plan_count: 0
Final Cached_plan_hits: 55015764
Error-log summary: empty
```

The automated primary gate returned non-zero because t4 was categorized as a
supporting/noisy positive row instead of a primary row: ON QPS CV was 5.13%,
slightly above the 5.0% low-variance threshold.  The repeat-level evidence
still shows 3/3 positive QPS and CPU/kQPS repeats for t4.

## Benchmark Sample Validity Gate

During shape attribution, one local macOS `distinct_range:t4` sample reported a
sysbench `total time` far above the configured run time.  That artifact is
diagnostic only and must not be used as community-facing evidence.

The benchmark harness was updated so future `results.tsv` files include:

```text
valid
sample_warning
elapsed_sec
expected_sec
```

`summarize_sysbench_results.py` now writes `invalid_samples` and summarizes only
repeat pairs where both OFF and ON are valid.  `summarize_benchmark_artifacts.py`
prints `Invalid samples` and adds a Review Signal when any invalid sample was
excluded.

Validation:

```bash
python3 Docs/plan_cache_community/tests/test_summarize_sysbench_results.py
bash -n Docs/plan_cache_community/in_memory_sysbench_harness.sh
python3 -m py_compile \
  Docs/plan_cache_community/summarize_sysbench_results.py \
  Docs/plan_cache_community/summarize_benchmark_artifacts.py \
  Docs/plan_cache_community/tests/test_summarize_sysbench_results.py
```

Tiny smoke artifact:

```text
/tmp/plan-cache-shapes-20260627-005025
```

The smoke verified that `valid=1`, `elapsed_sec`, `expected_sec`, and
`invalid_samples=0` are emitted and consumed by the artifact summary path.

## Current HEAD Distinct Range Release Check

After the sample-validity gate was committed, a focused release run retested
the strongest single sysbench SELECT shape.

Artifact:

```text
/tmp/plan-cache-shapes-20260627-005244
```

Setup:

```text
Build: Release
ASAN: OFF
tables: 64
table_size: 10000
buffer_pool_size: 4G
threads: 1 4
run_time: 30s
repeats: 3
workload: oltp_read_only:distinct_range
profile collection: OFF
```

Median result:

```text
t1  +80.99% QPS, -51.25% CPU/kQPS, 3/3 positive repeats, invalid_samples=0
t4  +94.41% QPS, -52.17% CPU/kQPS, 3/3 positive repeats, invalid_samples=0
```

Plan-cache status evidence:

```text
ON hit median by thread: 350204, 1034724
Cached_plan_invalidations: 0
Final Cached_plan_count: 0
Final Cached_plan_hits: 3909535
Error-log summary: empty
```

This is the clearest current performance-improvement point.  It should be the
first shape attribution case rerun on Linux with CPU-set isolation.

## Current HEAD Primary Release Check With Validity Gate

The mixed `oltp_read_only` primary benchmark was rerun after adding invalid
sample filtering.

Artifact:

```text
/tmp/plan-cache-primary-20260627-010323
```

Setup:

```text
Build: Release
ASAN: OFF
tables: 64
table_size: 10000
buffer_pool_size: 4G
threads: 1 2 4 8
run_time: 45s
repeats: 3
workload: oltp_read_only
profile collection: OFF
```

Median result:

```text
t1  +27.32% QPS, -30.91% CPU/kQPS, 3/3 positive repeats, invalid_samples=0
t2  +18.98% QPS, -22.55% CPU/kQPS, 3/3 positive repeats, invalid_samples=0
t4  +14.69% QPS, -18.95% CPU/kQPS, 3/3 positive repeats, invalid_samples=0
t8  +10.63% QPS, -12.96% CPU/kQPS, 3/3 positive repeats, invalid_samples=0
```

Plan-cache status evidence:

```text
ON hit median by thread: 1849528, 2775784, 3378208, 4547258
Cached_plan_invalidations: 0
Final Cached_plan_count: 0
Final Cached_plan_hits: 37786062
Error-log summary: empty
```

The primary gate returned non-zero because t2 was classified as noisy positive:
ON QPS CV was 9.07%, above the 5.0% low-variance threshold.  This is a local
repeatability warning, not a negative performance result.

## Fast Value Suite Gate

`run_sysbench_benchmark_suite.sh` now supports `SUITE_MODE=value`.  It runs:

```text
preflight
primary oltp_read_only
shapes with READ_ONLY_SHAPES=distinct_range
```

The mode writes a top-level `plan-cache-value-*/benchmark_artifact_summary.md`
and is intended for a quick Linux CPU-set value decision path.  It avoids the
longer full shape matrix and fixed-rate runs until the primary and strongest
attribution cases are known.

Validation:

```bash
python3 Docs/plan_cache_community/tests/test_run_sysbench_suite_modes.py
bash -n Docs/plan_cache_community/run_sysbench_benchmark_suite.sh
```

## 2026-06-27 Release Value Run

Artifact:

```text
/tmp/plan-cache-value-20260627-022352/plan-cache-primary-20260627-022352
```

Environment:

```text
Build: Release
ASAN: OFF
platform: local macOS/Darwin arm64, no Linux CPU-set isolation
tables: 64
table_size: 25000
buffer_pool_size: 10G
threads: 1 2 4 8 16
run_time: 60s
repeats: 3
workload: oltp_read_only
profile collection: ON (diagnostic; not a publishable headline run)
```

Median result:

```text
t1   +26.32% QPS/TPS, -28.97% CPU/kQPS, 3/3 positive repeats, ON CV 2.27%
t2   +18.79% QPS/TPS, -20.57% CPU/kQPS, 3/3 positive repeats, ON CV 1.85%
t4   +12.99% QPS/TPS, -17.67% CPU/kQPS, 3/3 positive repeats, ON CV 3.61%
t8   +16.87% QPS/TPS, -17.58% CPU/kQPS, 3/3 positive repeats, ON CV 2.82%
t16  +11.74% QPS/TPS, -16.56% CPU/kQPS, 3/3 positive repeats, ON CV 0.75%
```

Plan-cache status evidence:

```text
ON hit median by thread: 2324800, 3454196, 3848608, 5464762, 5505854
Cached_plan_invalidations: 0
Cached_plan_count max median by thread: 320, 640, 1280, 2560, 5120
```

Interpretation:

- The release build shows consistent positive median QPS/TPS and CPU/kQPS for
  all tested `oltp_read_only` concurrencies.
- The run proves the cache is active: ON runs have millions of hits, non-zero
  live cached plan counts while clients run, and zero invalidations.
- The automated primary gate exited non-zero because this diagnostic run used
  `REPEATS=3` while the suite default gate expected 4 positive repeats for
  formal 5-repeat runs.  The suite was fixed in commit `be08973bba3` to cap the
  effective positive-repeat requirement at the actual repeat count.
- Replaying the gate with `--min-positive-repeats 3` still classifies t2 as
  supporting/noisy under the default 5% CV threshold because its OFF samples had
  8.10% CV.  With `--max-cv 10`, all 1/2/4/8/16 rows classify as primary and
  the gate has no failures.
- This is strong local value evidence, but it is not community-final because
  macOS cannot provide the Linux server/sysbench CPU-set isolation required by
  the benchmark plan.

## Gaps Before Community PR

- Full MariaDB MTR has not been rerun after the latest plan-cache commits.
- ASAN/LSAN evidence is not yet recorded for the final branch state.
- Linux CPU-set isolated repeated InnoDB sysbench performance data is not yet
  recorded in this package. The current 3-repeat release run is strong local
  engineering evidence, but not final community-grade evidence.
- Point-select high-concurrency TPS still needs Linux confirmation because the
  historical 16-thread run was not consistently positive even though cache hits
  were high. A later 1-thread profile-off point-only follow-up is positive, but
  it does not replace the formal Linux multi-concurrency gate.
- Formal fixed-rate efficiency data is not yet recorded.
- Optimizer trace parity with TaurusDB/MySQL is not implemented.

## Recommended Pre-PR Gate

1. Debug build and focused `session_plan_cache*` MTR.
2. Broader prepared-statement subset.
3. ASAN focused MTR or prepare/deallocate stress loop.
4. Sysbench point/read-only benchmark with feature off/on.
5. `git diff --check`.
