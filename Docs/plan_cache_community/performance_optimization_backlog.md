# Plan Cache Performance Optimization Backlog

## Decision

当前不建议继续盲目修改生产代码。已有证据显示 plan cache 的主要收益已经从
`oltp_read_only` 和 range 类 SELECT 中体现出来；剩余明显热点集中在每次 HIT 后
重建执行态 `JOIN` / `QUICK` / `Explain` 结构。这些方向有优化空间，但风险已经高于
当前社区准备阶段可接受的小补丁范围。

下一步性能推进应采用数据触发：

1. 先跑 Linux CPU set 隔离的 release 长稳 benchmark。
2. 如果某个 shape 仍稳定劣化，再针对该 shape 打开 `session_plan_cache_profile`
   做短 profile。
3. 只有 profile 指向单一低风险开销点时才改代码。

## Current Proven Value Points

| Scenario | Current Evidence | Use In Community Claim |
|---|---|---|
| `oltp_read_only` | 本地 release 10GB buffer pool 长窗口多并发均为正收益 | Yes, primary after Linux rerun |
| `distinct_range` | shape matrix 1/4 线程收益最大，CPU/kQPS 明显下降 | Yes, attribution |
| `sum_range` | 单轮波动后 3-repeat median 转正 | Yes, supporting |
| `simple_range` | 低到中等正收益，CPU/kQPS 改善 | Supporting |
| `order_range` | 小正收益，受 filesort/tracker 边界限制 | Supporting |
| `oltp_point_select` | 单线程正向，多并发噪声大 | No, supporting only |

## Remaining Hotspots

| Hotspot | Files / Functions | Risk | Trigger To Work On It |
|---|---|---|---|
| DISTINCT/ORDER range HIT rebuilds `QUICK_RANGE_SELECT` / `SQL_SELECT` every execute | `sql/sql_select.cc`, `build_range_between_lookup_plan()`; `sql/opt_range.cc`, `get_quick_select_for_between()` | Medium to high | Linux shape data shows stable range regression or fixed-rate CPU/kQPS fails |
| Range DISTINCT / ORDER / SUM post setup | `build_range_between_lookup_plan()`, `create_distinct_group()`, `setup_plan_cache_*_aggr_tables_info()` | Medium to high | One shape has stable negative median and profile shows setup/post dominates |
| DISTINCT HIT light explain / tracker setup | `JOIN::build_plan_cache_hit_explain()` | High | `hit_explain_us` dominates a stable DISTINCT regression and an MTR-safe tracker split design exists |
| Ref/unique HIT workspace allocation and `map2table` clear | `build_ref_eq_lookup_plan()` | Low to medium, low expected gain | Point/ref fixed-rate CPU stays worse after Linux CPU isolation |
| Full parameter signature validation | `validate_state()`, `param_signatures_match()` | Medium, safety boundary | Real workload has many unused params and `validate_us` dominates profile |
| Table row-count refresh when ratio enabled | `current_table_records()` | Low, config-specific | User enables non-zero `session_plan_cache_allow_change_ratio` in perf path |

## Short-Term Do-Not-Do List

Do not spend the next performance block on these unless a new reproducible
profile contradicts the current evidence:

- Cross-execute reuse of `QUICK_RANGE_SELECT`, `SQL_SELECT`, or complete `JOIN_TAB`.
- Skipping or replacing `build_explain()` with an incomplete explain node.
- Reducing parameter shape validation from all params to only recipe params.
- Shrinking or partially clearing `map2table` without a full execution-path audit.
- Rewriting DISTINCT/SUM/ORDER aggregate setup as a broad shortcut.
- Optimizing profile counters; profile is diagnostic and disabled by default.

## Data-Triggered Candidate Patch

If the Linux shape or fixed-rate benchmark identifies a stable DISTINCT range
issue, the next code-design candidate should be narrow and exact:

```text
Shape:
  SELECT DISTINCT c FROM sbtestN
  WHERE id BETWEEN ? AND ?
  ORDER BY c

Current remaining costs:
  range_build ~= 0.630 us/hit
  range_setup ~= 0.447 us/hit
  setup_post ~= 0.144 us/hit
  setup_alloc ~= 0.100 us/hit
  setup_distinct ~= 0.053 us/hit
  hit_explain ~= 0.263 us/hit
```

The 4-thread short profile confirmed the same shape and cost distribution:

```text
range_build ~= 0.789 us/hit
range_setup ~= 0.477 us/hit
setup_post ~= 0.147 us/hit
setup_alloc ~= 0.115 us/hit
setup_distinct ~= 0.053 us/hit
hit_explain ~= 0.237 us/hit
```

Candidate direction:

- cache or precompute the exact single-field DISTINCT range metadata captured
  after normal optimization;
- keep the existing fail-closed boundary from
  `plan_cache_distinct_range_uses_single_access_tab()`;
- reduce repeated `count_field_types()`, `calc_group_buffer()`, item-ref-array
  setup, and full explain/tracker setup only for that exact shape;
- retain full fallback to `make_aggr_tables_info()` and `build_explain()` for
  any shape drift.

Risk notes from the current code path:

- `setup_post` currently enters generic aggregate setup through
  `make_aggr_tables_info()`, which also handles storage-engine group-by
  handlers, temporary tables, item ref arrays, and tracker wiring.
- `hit_explain` cannot be skipped outright because MariaDB uses explain objects
  to initialize execution-time trackers.
- `setup_distinct` is already relatively small after the single-field group
  fast path, so a standalone `create_distinct_group()` micro-optimization is
  unlikely to move QPS by itself.

Required proof before coding:

- Linux repeated shape data shows DISTINCT range has a stable negative or weak
  fixed-rate efficiency result despite valid hits and zero invalidations.
- `profile_status_analysis.md` shows DISTINCT range setup or explain dominates
  the ON cost on that host.
- A focused MTR exists for exact DISTINCT range output, EXPLAIN/ANALYZE
  boundary behavior, storage-engine `create_group_by` fallback, and fault
  injection.

Do not start this patch from generic DISTINCT, generic GROUP BY, or complete
`QUICK_RANGE_SELECT` reuse. Those are different features with much larger
executor-state risk.

See `distinct_range_next_patch_plan.md` for the exact setup/explain candidate
boundaries and the required evidence gate before coding.

### 2026-06-27 Short Profile With Split Setup Counters

Artifact:

```text
/tmp/plan-cache-shapes-20260627-014434
```

Scope:

- Release build, ASAN OFF.
- `READ_ONLY_SHAPES=distinct_range`.
- `THREADS="1 4"`, `RUN_TIME=30`, `REPEATS=3`.
- `COLLECT_PROFILE_STATUS=1`.
- No CPU set isolation, so this is diagnostic only.

Result:

| Threads | QPS delta | CPU/kQPS delta | Invalid samples | Hits | Invalidations |
|---:|---:|---:|---:|---:|---:|
| 1 | +80.89% | -51.15% | 0 | 354582 | 0 |
| 4 | +67.54% | -45.35% | 0 | 874387 | 0 |

The new split counters show that exact DISTINCT range post setup is mostly
aggregate setup, not item-ref-array setup:

| Threads | Counter | Approx us/hit |
|---:|---|---:|
| 1 | `Cached_plan_profile_hit_range_setup_aggr_us` | 0.115 |
| 1 | `Cached_plan_profile_hit_range_setup_ref_array_us` | 0.024 |
| 4 | `Cached_plan_profile_hit_range_setup_aggr_us` | 0.146-0.189 |
| 4 | `Cached_plan_profile_hit_range_setup_ref_array_us` | 0.029-0.037 |

Interpretation:

- Do not optimize `init_items_ref_array()` first; it is too small.
- The next plausible code candidate is an exact-shape DISTINCT range aggregate
  setup fast path.
- The fast path must preserve `group_fields`, `sort_and_group`,
  `send_group_parts`, `items3`/`ref_array`, `fields`, final
  `set_items_ref_array(items0)`, and `next_select` semantics.
- Generic `make_aggr_tables_info()` still covers storage-engine group-by,
  temp-table, HAVING, window, rollup, and non-exact DISTINCT cases.  Any fast
  path must fail closed to the generic path when those are present.

### 2026-06-27 Exact DISTINCT Range Fast Path Smoke

Artifact:

```text
/tmp/plan-cache-shapes-20260627-021156
```

Scope:

- Release build, ASAN OFF.
- `READ_ONLY_SHAPES=distinct_range`.
- `THREADS="1 4"`, `RUN_TIME=20`, `REPEATS=2`.
- `COLLECT_PROFILE_STATUS=1`.
- No CPU set isolation, so this is a smoke/diagnostic run only.
- Artifact manifest records HEAD before the uncommitted fast-path patch; the
  measured binary included the exact DISTINCT range aggregate setup fast path.
  Treat this artifact as non-authoritative engineering evidence, not a
  community-facing reproducible benchmark.  Community evidence must be
  regenerated from a committed tree with Linux CPU-set isolation.

Result:

| Threads | QPS delta | CPU/kQPS delta | Invalid samples | Hits | Invalidations |
|---:|---:|---:|---:|---:|---:|
| 1 | +81.88% | -54.04% | 0 | 238530 | 0 |
| 4 | +63.56% | -43.92% | 0 | 679591 | 0 |

Profile evidence:

- `Cached_plan_profile_hit_range_setup_distinct_fast_us` increments on the
  ON runs, proving the exact fast path is active.
- The fast path preserves the existing DISTINCT range setup flow: the earlier
  range rebuild code first converts the exact `SELECT DISTINCT c ... ORDER BY c`
  shape into a single-column group list, then the fast path rebuilds only that
  exact grouped tail.
- The implementation intentionally fails closed for non-exact DISTINCT,
  HAVING, temp-table, storage-engine group-by, window, rollup, custom aggregate,
  procedure, and buffer-result cases.

Verification:

- `cmake --build build_plan_cache_debug --target mariadbd --parallel 16`
- `main.session_plan_cache_distinct_range_profile`
- `main.session_plan_cache_status`
- `main.session_plan_cache_distinct_range_result`
- `main.session_plan_cache_distinct_range_boundary`
- `main.session_plan_cache_debug_fault_injection`
- `cmake --build build_plan_cache_release --target mariadbd --parallel 16`

Interpretation:

- The patch is directionally positive on the strongest attribution shape.
- This still does not replace the required Linux CPU-set release run for a
  community-facing performance claim.
- The next decision gate is the full `SUITE_MODE=value` Linux run with
  `SERVER_CPUSET` and `SYSBENCH_CPUSET` separated.

### 2026-06-27 Committed Exact DISTINCT Range Fast Path Smoke

Artifact:

```text
/tmp/plan-cache-shapes-20260627-021931
```

Scope:

- Release build, ASAN OFF.
- Source HEAD: `f5406f17cdbe43c6a9cc361ca0c2ee4398c5648b`.
- `READ_ONLY_SHAPES=distinct_range`.
- `THREADS="1 4"`, `RUN_TIME=20`, `REPEATS=2`.
- `COLLECT_PROFILE_STATUS=1`.
- No CPU set isolation, so this remains diagnostic rather than
  community-facing benchmark evidence.

Result:

| Threads | QPS delta | CPU/kQPS delta | Invalid samples | Hits | Invalidations |
|---:|---:|---:|---:|---:|---:|
| 1 | +79.50% | -52.38% | 0 | 235069 | 0 |
| 4 | +63.63% | -44.01% | 0 | 712694 | 0 |

The committed-tree smoke confirms the fast-path direction after code review:

- ON QPS is positive in all repeat-level samples.
- ON CPU/kQPS improves in all repeat-level samples.
- `Cached_plan_hits` grows and invalidations remain 0.
- `Cached_plan_profile_hit_range_setup_distinct_fast_us` increments in ON
  profile status, confirming the exact fast path is active.

## Next Data To Collect

### Primary Linux Benchmark

Use this to decide whether performance is already good enough to stop optimizing:

```bash
ARTIFACT_ROOT=/path/to/artifacts \
SUITE_MODE=primary \
TABLES=250 TABLE_SIZE=25000 THREADS="1 2 4 8 16" \
BUFFER_POOL_SIZE=10G PREWARM_TIME=120 RUN_TIME=300 REPEATS=5 \
SERVER_CPUSET=0-7 SYSBENCH_CPUSET=8-15 \
Docs/plan_cache_community/run_sysbench_benchmark_suite.sh
```

Acceptance:

- `oltp_read_only` ON median QPS/TPS positive at 1/2/4 and preferably 8/16.
- ON CPU/kQPS improves.
- `Cached_plan_hits` grows, live `Cached_plan_count` is non-zero, invalidations stay 0.

### Shape Attribution

Use this to decide which shape deserves any further profile-driven optimization:

```bash
ARTIFACT_ROOT=/path/to/artifacts \
SUITE_MODE=shapes \
TABLES=250 TABLE_SIZE=25000 SHAPE_THREADS="1 2 4 8" \
BUFFER_POOL_SIZE=10G PREWARM_TIME=120 RUN_TIME=300 REPEATS=5 \
SERVER_CPUSET=0-7 SYSBENCH_CPUSET=8-15 \
Docs/plan_cache_community/run_sysbench_benchmark_suite.sh
```

Prioritize follow-up only when a shape has:

- negative ON median QPS/TPS;
- no CPU/kQPS improvement;
- valid hits and zero invalidations;
- low enough CV to trust the regression.

### Fixed-Rate Efficiency

Use this when closed-loop QPS is noisy:

```bash
ARTIFACT_ROOT=/path/to/artifacts \
SUITE_MODE=fixed \
TABLES=250 TABLE_SIZE=25000 THREADS="1 2 4 8 16" \
BUFFER_POOL_SIZE=10G PREWARM_TIME=120 RUN_TIME=300 REPEATS=5 \
SERVER_CPUSET=0-7 SYSBENCH_CPUSET=8-15 \
Docs/plan_cache_community/run_sysbench_benchmark_suite.sh
```

Acceptance:

- ON median CPU/kQPS improves by at least 8% for `oltp_read_only`.
- At least 4 of 5 repeats are positive.
- No latency regression above 5%.
- Hits grow and invalidations remain 0.

## Profile-Driven Debug Queue

Only run these after a benchmark identifies a suspect shape.

| Queue | Test | Purpose |
|---|---|---|
| Point/ref | `oltp_point_select`, 2/4 threads, fixed-rate, 30-60s, profile ON | Separate optimizer savings from protocol/handler/client overhead |
| Range shapes | `point simple_range sum_range order_range distinct_range`, 1/4 threads, AB/BA, 3 repeats, profile ON | Find whether build/setup/explain dominates |
| Prepared-loop micro | 2000-10000 executes per shape, profile ON | Compare per-hit counters without sysbench scheduler noise |
| Scaling diagnostic | `SUITE_MODE=diagnostic`, 60s | Check CPU, handler, table cache, and concurrency scaling only |

Latest short release check after splitting unique/ref hit profile counters:

```text
profile ON artifact:  /tmp/plan-cache-shapes-20260626-205135
profile OFF artifact: /tmp/plan-cache-shapes-20260626-205416
shapes: point simple_range
threads: 1 4
tables: 8
table_size: 5000
run_time: 15s
```

The profile-ON run showed `oltp_read_only:point:t4` regressing, but the same
matrix with profile disabled showed positive QPS for all tested rows:

```text
point:t1        +24.28% QPS, -52.69% CPU/kQPS
point:t4        +12.07% QPS,  +3.23% CPU/kQPS
simple_range:t1 +10.70% QPS, -23.06% CPU/kQPS
simple_range:t4  +3.90% QPS,  -1.24% CPU/kQPS
```

Interpretation: point/ref profile counters are useful for attribution, but they
can perturb very small point-query measurements.  Do not start a point/ref
production-code optimization from a profile-ON QPS regression alone.  Require a
matching profile-OFF regression or fixed-rate CPU/kQPS regression first.

The sysbench harnesses can collect the counters below with:

```bash
COLLECT_PROFILE_STATUS=1 \
SUITE_MODE=shapes \
TABLES=32 TABLE_SIZE=20000 SHAPE_THREADS="1 4" \
BUFFER_POOL_SIZE=4G PREWARM_TIME=30 RUN_TIME=30 REPEATS=3 \
Docs/plan_cache_community/run_sysbench_benchmark_suite.sh
```

When enabled, each case writes raw files under `raw/`:

- `*.status_before.tsv`
- `*.status_after.tsv`
- `*.status_delta.tsv`

The harness also writes `profile_status_analysis.md`, which ranks per-hit
profile counters, summarizes handler/table-cache deltas, and emits conservative
optimization advice buckets such as `data-triggered-distinct-design`,
`order-range-monitor`, `point-low-priority`, and `range-low-risk-exhausted`.

Leave `COLLECT_PROFILE_STATUS` disabled for final headline performance runs
because profile counters add timing overhead. Use it for short root-cause runs
after a stable regression or noisy shape has already been identified.

Profile counters to record:

- `Cached_plan_profile_hit_build_us`
- `Cached_plan_profile_hit_explain_us`
- `Cached_plan_profile_validate_us`
- `Cached_plan_profile_prevalidate_us`
- `Cached_plan_profile_hit_unique_build_us`
- `Cached_plan_profile_hit_unique_alloc_us`
- `Cached_plan_profile_hit_unique_setup_plan_us`
- `Cached_plan_profile_hit_ref_build_us`
- `Cached_plan_profile_hit_ref_alloc_us`
- `Cached_plan_profile_hit_ref_setup_us`
- `Cached_plan_profile_hit_range_build_us`
- `Cached_plan_profile_hit_range_quick_select_us`
- `Cached_plan_profile_hit_range_setup_us`
- `Cached_plan_profile_hit_range_setup_alloc_us`
- `Cached_plan_profile_hit_range_setup_base_us`
- `Cached_plan_profile_hit_range_setup_distinct_us`
- `Cached_plan_profile_hit_range_setup_order_us`
- `Cached_plan_profile_hit_range_setup_post_us`

System/status counters to record with profile runs:

- `Handler_read_key`
- `Handler_read_next`
- `Handler_read_rnd_next`
- `Created_tmp_tables`
- `Created_tmp_disk_tables`
- `Table_open_cache_hits`
- `Table_open_cache_misses`
- `Table_open_cache_overflows`
- `Opened_tables`
- `Opened_table_definitions`
- server CPU avg/max
- CPU/kQPS
- latency avg/p95/p99

## Coding Gate

Before any new performance patch:

1. Name the exact workload and shape that regresses.
2. Show ON has hits, live cached count, and zero invalidations.
3. Show the regression is stable by median, not one run.
4. Show one profile counter dominates enough to justify code risk.
5. Define the smallest source change and its focused MTR coverage.

If any item is missing, keep collecting data instead of changing production code.

## 2026-06-27 Local Value Result

The latest local release value run produced positive `oltp_read_only` medians at
1/2/4/8/16 threads:

```text
t1 +26.32%, t2 +18.79%, t4 +12.99%, t8 +16.87%, t16 +11.74% QPS/TPS
CPU/kQPS improved by 16.56% to 28.97%
ON runs had millions of hits and zero invalidations
```

Do not start another production-code optimization from the current local data.
The remaining high-value work is a Linux CPU-set 5-repeat value run and then
community report cleanup.  Use profile-guided code changes only if that Linux
run shows a stable regression in a supported shape.
