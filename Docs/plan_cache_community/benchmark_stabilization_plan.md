# Benchmark Stabilization Plan

## Problem Statement

The current local release sysbench results are not stable enough for a MariaDB
community performance claim. `oltp_read_only` is directionally positive across
1/2/4 threads, but `oltp_point_select` fluctuates across repeated runs even when
the server is below CPU saturation.

This is not acceptable evidence for a community PR. The benchmark package must
be changed before the feature is presented externally.

## Root-Cause Hypotheses

The current point-select evidence is unstable because several effects are mixed
into one closed-loop TPS number:

- point-select latency is extremely small, so scheduler and client-side jitter
  can dominate the measured delta;
- sysbench client and `mariadbd` run on the same host and compete for CPU;
- macOS performance/efficiency core scheduling and frequency changes are not
  controlled;
- closed-loop sysbench reports maximum completed events, which changes when
  either client or server scheduling changes;
- the plan-cache hit path saves optimizer work, but the remaining socket,
  protocol, prepared-statement, and handler overhead may dominate pure point
  select;
- AB/BA ordering affects warm state, branch prediction, adaptive index state,
  and client scheduling.

Therefore, pure point-select closed-loop TPS is a poor primary proof for this
feature unless the test is run on a controlled Linux host with repeated trials
and low variance.

## New Evidence Model

For direct TPS/QPS comparison, prefer the in-memory sysbench harness in
`in_memory_sysbench_harness.sh`. It keeps TPS/QPS as the primary metric,
uses a large buffer pool, runs point-select and read-only workloads at
concurrency 1/2/4/8/16, and supports Linux CPU-set separation for `mariadbd`
and `sysbench`.

Use two benchmark gates instead of one when investigating noisy microbenchmarks.

### Gate 1: Fixed-Rate Efficiency

Goal: prove that plan cache reduces server cost at the same offered workload.

Method:

1. Calibrate OFF and ON closed-loop throughput for each workload/thread pair.
2. Pick a fixed event rate below saturation, for example 60% to 70% of the lower
   calibrated throughput.
3. Run OFF and ON at the same fixed `--rate`.
4. Compare:
   - average `mariadbd` CPU;
   - CPU per event;
   - average/p95/p99 latency;
   - errors/reconnects;
   - `Cached_plan_hits` delta.

This avoids requiring TPS to increase before the server is saturated. The
expected value signal is lower CPU and equal or lower latency at the same load.

Acceptance:

- median CPU per event improves by at least 8% for `oltp_read_only`;
- at least 4 of 5 repeats are positive;
- coefficient of variation for CPU per event is below 3% after discarding the
  first repeat;
- no latency regression above 5%;
- `Cached_plan_invalidations=0`;
- `Cached_plan_hits` grows in every ON run.

### Gate 2: Saturation Throughput

Goal: prove that plan cache can increase maximum throughput when the server is
the bottleneck.

Method:

1. Sweep threads, for example 1, 2, 4, 8, 16, 32.
2. Use long windows, for example 120s warmup and 300s measured run.
3. Run at least 5 repeats with randomized or ABBA mode order.
4. Report median and p25/p75, not a single run.
5. Treat a result as publishable only if the coefficient of variation is low.

Acceptance:

- primary claim should be based on `oltp_read_only`, not pure point select;
- point-select can be included as secondary data only if repeated medians are
  positive and variance is low;
- if point-select remains noisy, publish it as "no stable improvement observed"
  and keep the feature claim focused on prepared read-only SELECT mixes.

## Required Environment

The current macOS laptop data is useful for debugging but should not be used as
final community evidence.

Recommended community benchmark host:

- dedicated Linux bare metal or isolated VM;
- performance governor enabled;
- fixed CPU frequency or turbo policy documented;
- `mariadbd` pinned to a CPU set;
- sysbench pinned to a separate CPU set;
- no concurrent builds, indexing, backups, or interactive workloads;
- stable storage with enough free space;
- NTP and background package jobs disabled during the run;
- raw `lscpu`, kernel version, sysbench version, MariaDB version, and git commit
  recorded with every run.

## Workloads

Primary:

- `oltp_read_only`: covers sysbench prepared SELECT templates and gives a more
  realistic mix of point, range, sum, order, and distinct SELECTs.

Secondary:

- `oltp_point_select`: keep as a narrow microbenchmark, but do not use it as the
  only value proof unless it becomes stable under the formal harness.

Regression guard:

- `oltp_read_write`: verify DML stays on the normal path and no regression or
  wrong result appears. Do not expect DML plan-cache hits.

## 12-Hour Execution Plan

The short-window deliverable should use `in_memory_sysbench_harness.sh` as
the primary TPS/QPS artifact generator.  It already enforces a release build,
uses a 10GB buffer pool by default, records plan-cache status deltas, and can
separate `mariadbd` and sysbench CPU sets on Linux through `SERVER_CPUSET` and
`SYSBENCH_CPUSET`.

Recommended command template:

Before starting a long run, validate the benchmark host and release build:

```bash
ROOT_DIR=/path/to/server-plan-cache \
BUILD_DIR=/path/to/server-plan-cache/build_plan_cache_release \
WORKLOADS="oltp_read_only" \
SERVER_CPUSET=0-7 \
SYSBENCH_CPUSET=8-15 \
PREFLIGHT_ONLY=1 \
Docs/plan_cache_community/in_memory_sysbench_harness.sh
```

`PREFLIGHT_ONLY=1` checks the release build, sysbench command, OLTP Lua script
directory, Python summary dependency, and requested CPU set tooling.  It exits
before starting `mariadbd` or importing data.

The same preflight can be run through the suite wrapper:

```bash
SERVER_CPUSET=0-7 SYSBENCH_CPUSET=8-15 \
SUITE_MODE=preflight \
Docs/plan_cache_community/run_sysbench_benchmark_suite.sh
```

For `preflight`, `primary`, `shapes`, `point`, and `fixed`, the suite wrapper
requires non-empty, non-overlapping `SERVER_CPUSET` and `SYSBENCH_CPUSET` by
default.  Override with `FORMAL_CPUSET_REQUIRED=0` only for local smoke or
diagnostic work; do not use such runs as formal community performance evidence.

When the host window is large enough, run the formal sequence in one pass:

```bash
ARTIFACT_ROOT=/path/to/artifacts \
SUITE_MODE=formal \
TABLES=250 TABLE_SIZE=25000 THREADS="1 2 4 8 16" \
SHAPE_THREADS="1 2 4 8" \
BUFFER_POOL_SIZE=10G PREWARM_TIME=120 RUN_TIME=300 REPEATS=5 \
SERVER_CPUSET=0-7 SYSBENCH_CPUSET=8-15 \
Docs/plan_cache_community/run_sysbench_benchmark_suite.sh
```

This runs preflight, primary, shape attribution, and fixed-rate evidence, then
writes a top-level `plan-cache-formal-*/benchmark_artifact_summary.md`.

For the shorter value decision path, run only primary read-only and
`distinct_range` attribution:

```bash
ARTIFACT_ROOT=/path/to/artifacts \
SUITE_MODE=value \
TABLES=250 TABLE_SIZE=25000 THREADS="1 2 4 8 16" \
SHAPE_THREADS="1 2 4 8" \
BUFFER_POOL_SIZE=10G PREWARM_TIME=120 RUN_TIME=300 REPEATS=5 \
SERVER_CPUSET=0-7 SYSBENCH_CPUSET=8-15 \
Docs/plan_cache_community/run_sysbench_benchmark_suite.sh
```

This writes `plan-cache-value-*/benchmark_artifact_summary.md` and should be the
first unattended Linux run when the goal is to decide whether the feature has a
community-facing performance value case within one workday.

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

Equivalent suite-wrapper command:

```bash
ARTIFACT_ROOT=/path/to/artifacts \
SUITE_MODE=primary \
TABLES=250 TABLE_SIZE=25000 THREADS="1 2 4 8 16" \
BUFFER_POOL_SIZE=10G PREWARM_TIME=120 RUN_TIME=300 REPEATS=5 \
SERVER_CPUSET=0-7 SYSBENCH_CPUSET=8-15 \
Docs/plan_cache_community/run_sysbench_benchmark_suite.sh
```

Template-level follow-up, using the same data load and server options:

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

The shape matrix writes workload labels such as `oltp_read_only:point` and
`oltp_read_only:distinct_range` into `results.tsv` and `summary.tsv`.  Use it to
explain which prepared SELECT recipes contribute to the mixed `oltp_read_only`
gain.  Do not replace the mixed workload claim with shape-only results, because
the mixed workload is closer to real sysbench read-only behavior.

Point-select follow-up should run after the primary read-only result is already
captured:

```bash
ROOT_DIR=/path/to/server-plan-cache \
BUILD_DIR=/path/to/server-plan-cache/build_plan_cache_release \
OUT_DIR=/path/to/artifacts/plan-cache-point-select-$(date +%Y%m%d-%H%M%S) \
TABLES=250 \
TABLE_SIZE=25000 \
THREADS="1 2 4 8 16" \
WORKLOADS="oltp_point_select" \
BUFFER_POOL_SIZE=10G \
PREWARM_TIME=120 \
RUN_TIME=300 \
REPEATS=5 \
SERVER_CPUSET=0-7 \
SYSBENCH_CPUSET=8-15 \
Docs/plan_cache_community/in_memory_sysbench_harness.sh
```

Do not spend the first long benchmark window on pure point select.  It is useful
for the noise boundary and for proving prepared point-select hits work, but the
current value claim should be made from the mixed read-only workload first.

If QPS scaling is not linear before CPU saturation, use
`linearity_diagnostic_harness.sh` only as a diagnostic pass to collect
client/server CPU and table-cache counters.  It runs one configured
`PLAN_CACHE_MODE` at a time and is not a replacement for the ON/OFF benchmark
harnesses above.

If the host has fewer cores, keep CPU sets disjoint and reduce the maximum
thread count before allowing the server to saturate.  On macOS, where hard CPU
affinity is unavailable through the script, treat the result as engineering
evidence rather than final community proof.

Twelve-hour pass criteria:

- `oltp_read_only` is the primary claim.
- ON runs must show `Cached_plan_hits` growth and
  `Cached_plan_invalidations=0`.
- Prefer 5 repeats.  If the wall-clock budget forces a shorter run, use at
  least 3 repeats and label the result as pre-submission evidence.
- For threads 1/2/4, median QPS or TPS should be positive versus OFF.  If 8/16
  are already CPU-saturated or noisy, report them as saturation behavior rather
  than as the primary proof.
- `oltp_point_select` is supporting evidence only.  If repeated medians are not
  stable, do not use it as the headline value claim.
- Preserve raw `results.tsv`, raw sysbench output, `environment.txt`,
  `run_manifest.txt`, `summary.tsv`, `summary_analysis.md`, `mariadbd.err`,
  `mariadbd_error_summary.txt`, per-case `raw/*plan_cache_status.tsv`,
  `final_plan_cache_status.tsv`, and the exact git commit.
- The harness does not ignore sysbench SQL errors by default.  Only set
  `SYSBENCH_IGNORE_ERRORS` for diagnostic runs, and do not use those runs as
  formal performance evidence unless error counts are reported explicitly.
- `summary.tsv` includes `on_live_count_max_median`, derived from running-state
  `Cached_plan_count` samples.  This proves live cached statements existed
  during ON runs before sysbench disconnected.
- `final_plan_cache_status.tsv` records `Cached_plan%` after all sysbench
  clients have disconnected, so the report can show `Cached_plan_count` returned
  to baseline.
- `mariadbd_error_summary.txt` extracts warning/error-like lines from the error
  log for quick report review; inspect the full `mariadbd.err` if it is non-empty.
- `run_manifest.txt` records the actual release build, server option skeleton,
  sysbench common arguments, workload list, thread list, timing, repeats, CPU
  sets, and gate-related parameters used for the run.

After each run, inspect the generated summary analysis before editing the public
report:

```bash
less /path/to/artifacts/plan-cache-sysbench-*/summary_analysis.md
```

To create a compact review draft from one or more artifact directories:

```bash
Docs/plan_cache_community/summarize_benchmark_artifacts.py \
  /path/to/artifacts/plan-cache-primary-* \
  /path/to/artifacts/plan-cache-shapes-* \
  > /path/to/artifacts/benchmark_artifact_summary.md
```

Add `--fail-on-review-signals` when the command is used as a CI/nightly gate
instead of a report draft generator.  It exits non-zero if any summarized
artifact has Review Signals.

`run_sysbench_benchmark_suite.sh` writes `benchmark_artifact_summary.md`
automatically for `primary`, `shapes`, `point`, and `fixed` runs.  Use the
manual command when combining several artifact directories into one review
draft.

For the primary `oltp_read_only` run, use the analyzer as a hard evidence gate
before writing community-facing claims:

```bash
Docs/plan_cache_community/analyze_sysbench_summary.py \
  --require-primary-threads "1 2 4 8" \
  --detail-results /path/to/artifacts/plan-cache-primary-*/results.tsv \
  --min-positive-repeats 4 \
  /path/to/artifacts/plan-cache-primary-*/summary.tsv
```

`SUITE_MODE=primary` runs this gate automatically after the harness finishes and
writes `primary_gate_analysis.md` into the artifact directory.  Set
`PRIMARY_GATE_THREADS` to change the required non-saturated thread list.  Set
`PRIMARY_GATE_MIN_POSITIVE_REPEATS` only when the run uses a repeat count other
than the default 5.  Set `PRIMARY_GATE_THREADS=` only for local smoke or
diagnostic runs; do not disable the gate for formal primary evidence.

Add `16` to `--require-primary-threads` only when that concurrency is still
below server CPU saturation on the test host.  The command exits non-zero if a
required thread count lacks primary evidence, if plan-cache hits/live cache
evidence is missing, if invalidations are present, or if the repeat-level gate
does not have enough positive ON-vs-OFF QPS repeats.

Use the `Primary Candidates` section for the headline claim, `Strong Supporting
Cases` for template-level explanation, and `Risk Or Regression Cases` as the
next performance-debug queue.  The analyzer accepts multiple summary files and
prints a `Source` column so mixed, shape, fixed-rate, and closed-loop artifacts
can be classified together.

For `reproducible_sysbench_harness.sh` fixed-rate output, a primary candidate
means CPU/kQPS improved at the same offered load. For closed-loop output, a
primary candidate means median QPS/TPS improved with low variance.

## Reporting Rules

Do not publish a single-run TPS table as evidence.

Every report must include:

- exact commit;
- build type and `WITH_ASAN`;
- server options;
- sysbench command line;
- `run_manifest.txt`;
- warmup and measured duration;
- repeat count;
- mode order;
- median, p25, p75, min, max;
- coefficient of variation;
- CPU per event;
- `Cached_plan_hits`, `Cached_plan_count`, `Cached_plan_invalidations`;
- `valid`, `sample_warning`, `elapsed_sec`, `expected_sec`, and
  `invalid_samples` from the benchmark artifacts;
- error log warnings from `mariadbd_error_summary.txt`;
- raw result artifacts.

The in-memory harness marks a sysbench sample invalid when it cannot parse
throughput or when sysbench's reported `total time` exceeds
`RUN_TIME * MAX_SYSBENCH_ELAPSED_FACTOR` (`1.5` by default).  Summary generation
uses only repeat pairs where both OFF and ON samples are valid, and records the
number of excluded samples in `invalid_samples`.  Any non-zero
`invalid_samples` value is a review signal and the affected row must not be used
as community-facing evidence until rerun.

## Next Engineering Work

Before claiming point-select improvement:

1. Profile point-select OFF and ON at 2 and 4 threads with fixed rate.
2. Compare hot functions in:
   - plan-cache lookup;
   - recipe rebuild;
   - prepared-statement execute state transitions;
   - handler open/positioning path;
   - protocol send path.
3. If ON saves optimizer CPU but loses wall TPS, optimize hit-path overhead
   before expanding the public claim.

Until this is resolved, community wording should be:

```text
The current release benchmark shows stable value for prepared sysbench
read-only SELECT mixes under fixed/repeated conditions. Pure point-select TPS is
still under investigation and is not used as the primary performance claim.
```
