# Plan Cache Current Status and Next Steps

## Latest Snapshot: 2026-06-27

Current documentation snapshot is based on the rewritten
`plan_cache_community_series` branch. Older sections below include historical
benchmark and validation runs from earlier development HEADs; use this snapshot
as the current contribution status.

Current status:

- Production code is frozen for community preparation unless Linux formal
  evidence identifies a specific release-blocking issue.
- Local release engineering evidence is positive for `oltp_read_only` and the
  focused sysbench range shapes, but it is not PR-grade community performance
  evidence because it was collected on local macOS/Darwin without Linux CPU-set
  isolation.
- Current tree contains 29 `mysql-test/main/session_plan_cache*.test` files and
  2 `sys_vars.session_plan_cache*` tests. Final-HEAD focused MTR must rerun all
  of them before PR.
- The latest point-select attribution follow-up with profile collection disabled
  is positive at 1 thread, but point-select should still be treated as
  supporting evidence until Linux runs confirm the multi-concurrency shape.
- The remaining community blockers are real MDEV numbering, final-HEAD MTR,
  ASAN/LSAN, and Linux release CPU-set benchmark evidence.

## Current Status

当前分支已经完成第一轮性能根因定位和低风险优化。生产代码暂时建议冻结，不再为了
短期性能目标继续做高风险优化器改动。

当前可对外支撑的阶段性结论是：

- `oltp_read_only` 是主要价值证明场景，1/2/4/8 并发本地 release 结果均为正收益。
- 当前 HEAD 的 60s x 3 repeat 本地 release primary check 中，`oltp_read_only`
  在 1/2/4/8 并发分别提升 +29.64%、+21.38%、+13.47%、+14.21% QPS，
  同时 CPU/kQPS 分别下降 -34.31%、-24.12%、-18.12%、-15.64%。
- 修正 benchmark 样本有效性检查后，当前 HEAD 的 45s x 3 repeat 本地
  release primary check 中，`oltp_read_only` 在 1/2/4/8 并发分别提升
  +27.32%、+18.98%、+14.69%、+10.63% QPS，`invalid_samples=0`。
  其中 t2 因本机 ON CV 9.07% 被 gate 归为 noisy positive，不是负收益。
- `distinct_range` 是当前最强的单模板收益来源。
- 修正 benchmark 样本有效性检查后，`distinct_range` focused release check
  在 1/4 并发分别提升 +80.99%、+94.41% QPS，CPU/kQPS 分别下降
  -51.25%、-52.17%，`invalid_samples=0`。
- `sum_range`、`simple_range`、`order_range` 是辅助收益场景。
- `oltp_point_select` 有命中和局部收益，但 closed-loop QPS 噪声较大，不应作为主结论。
- 1 并发和 4 并发短 profile 都显示剩余热点集中在 range build/setup/explain，
  point/ref per-hit 成本明显更低。
- `Cached_plan_hits`、`Cached_plan_count`、`Cached_plan_invalidations` 已纳入 harness 和报告，
  可以证明 plan cache ON 场景确实命中且无失效噪声。
- 最近一次 primary check 中所有 ON repeat 均命中，`Cached_plan_invalidations=0`，
  最终 `Cached_plan_count=0`，说明连接断开后缓存释放正常。
- 本地 macOS 数据只适合作为工程证据，社区性能结论还缺 Linux 绑核长稳数据。

## DISTINCT Range Candidate Readiness

`distinct_range` 目前是唯一 profile 指向明确、但仍需要数据触发的代码候选。当前
已经完成的保护网：

- `main.session_plan_cache_distinct_range_result` 覆盖重复 `c` 值、不同
  `BETWEEN` 范围、结果有序去重，以及第 2/3 次执行 real hit。
- `main.session_plan_cache_distinct_range_boundary` 覆盖 extra selected
  column、GROUP BY、HAVING、window function、aggregate GROUP BY 等非 exact
  shape fail-closed。
- `main.session_plan_cache_distinct_range_profile` 覆盖
  `session_plan_cache_profile=ON` 下 range hit、post setup、hit explain
  counters 增长。
- `main.session_plan_cache_debug_fault_injection` 已覆盖现有 DISTINCT setup /
  group / aggregate setup fault fallback。
- 历史 focused MTR 在当时 HEAD 下通过。当前整理分支有
  29 个 `main.session_plan_cache*` 加 2 个 `sys_vars.session_plan_cache*`，
  需要在 PR 前用隔离 vardir/tmpdir 重新跑完整 focused MTR。

尚未满足进入生产代码改动的条件：

- Linux CPU-set release shape benchmark 还没有证明 `distinct_range` 是稳定发布阻塞点。
- Candidate A 如果开工，仍需新增 helper 专属 debug fallback，并保持
  EXPLAIN/ANALYZE、slow explain fallback 安全。
- Candidate B 风险更高，只能在 `hit_explain` 由 Linux 数据证明为主要阻塞后考虑。

## Remaining Work Estimate

按“拿到明确性能收益、可推进社区贡献讨论”的目标，当前已完成本机 release
根因定位和短 profile 收敛。剩余工作量主要是 Linux 绑核长稳 benchmark 与报告固化：
如果只要求拿到一次正式 Linux 性能证据，约 5 到 7 小时；如果要补齐 shape/fixed-rate
增强证据和 PR 前回归，约 1 到 2 个工作日。

| Priority | Work Item | Estimate | Must Finish Before Community Claim |
|---|---:|---:|---|
| P0 | 在独立 Linux 环境跑 release preflight | 10-20 min | Yes |
| P0 | `oltp_read_only` 1/2/4/8/16，5 repeats，300s，CPU set 分离 | 5-7 h | Yes |
| P0 | 汇总 `summary_analysis.md`，确认 ON 命中、无 invalidation、QPS/CPU-per-kQPS 收益 | 30-60 min | Yes |
| P1 | 优先跑 `distinct_range` shape，1/2/4/8，5 repeats，300s | 2-3 h | Strongly recommended |
| P1 | 完整 shape matrix 跑 `distinct/sum/order/simple/point`，1/2/4/8 | 4-6 h | Optional after primary |
| P1 | fixed-rate efficiency 数据，证明同等 QPS 下 CPU/kQPS 下降 | 3-5 h | Strongly recommended if TPS variance remains high |
| P1 | 更新 `sysbench_benchmark_report.md` 和 `community_readiness_report.md` | 1-2 h | Yes |
| P2 | full MTR/debug/ASAN 回归 | 2-6 h | Before PR, not before performance decision |
| P2 | commit series polish and community naming review | 2-4 h | Before PR |

当前不建议把剩余时间投入新的生产代码优化。4 并发短 profile 仍指向同一结论：
`distinct_range` 是唯一值得在数据触发后继续设计的候选；`simple_range`/`sum_range`
已有正收益；`order_range` 需要长稳观察；`point` 不是主收益路径。

如果 Linux primary 结果满足验收条件，可以先进入社区 RFC/MDEV 讨论；shape/fixed-rate
数据用于增强说服力。如果 primary 结果仍然高波动，则必须优先补 fixed-rate efficiency
数据，而不是继续改代码。

短 profile 定位时可设置 `COLLECT_PROFILE_STATUS=1`。这会让 benchmark harness
为每个 case 额外输出 `raw/*.status_delta.tsv`，其中包含 `Cached_plan_profile_*`、
`Handler_*`、table-cache 和临时表相关 counters，并生成
`profile_status_analysis.md` 汇总 per-hit hotspot。正式 headline benchmark 应保持
该选项关闭，避免 profile 计时影响 QPS/TPS。

如果需要比较两组短 profile，例如 1 并发与 4 并发，可使用：

```bash
Docs/plan_cache_community/compare_profile_status.py \
  --top 25 \
  --label-a t1 /path/to/t1/raw/*_ON_*.status_delta.tsv \
  --label-b t4 /path/to/t4/raw/*_ON_*.status_delta.tsv
```

该工具按 shape 对齐并输出 per-hit 成本变化，用于确认并发下热点是否改变。
`--top` 只限制 comparison 表格展示行数；Candidate Signals 会扫描完整比较行，
避免快速查看 top5 时漏掉 DISTINCT `setup_post` / `hit_explain` 这类非最高但
更可设计的信号。

## Immediate Commands

Preflight:

```bash
ARTIFACT_ROOT=/path/to/artifacts \
SERVER_CPUSET=0-7 SYSBENCH_CPUSET=8-15 \
SUITE_MODE=preflight \
Docs/plan_cache_community/run_sysbench_benchmark_suite.sh
```

Primary value benchmark:

```bash
ARTIFACT_ROOT=/path/to/artifacts \
SUITE_MODE=primary \
TABLES=250 TABLE_SIZE=25000 THREADS="1 2 4 8 16" \
BUFFER_POOL_SIZE=10G PREWARM_TIME=120 RUN_TIME=300 REPEATS=5 \
SERVER_CPUSET=0-7 SYSBENCH_CPUSET=8-15 \
Docs/plan_cache_community/run_sysbench_benchmark_suite.sh
```

Full formal sequence, when there is enough time to run primary, shape, and
fixed-rate evidence in one pass:

```bash
ARTIFACT_ROOT=/path/to/artifacts \
SUITE_MODE=formal \
TABLES=250 TABLE_SIZE=25000 THREADS="1 2 4 8 16" \
SHAPE_THREADS="1 2 4 8" \
BUFFER_POOL_SIZE=10G PREWARM_TIME=120 RUN_TIME=300 REPEATS=5 \
SERVER_CPUSET=0-7 SYSBENCH_CPUSET=8-15 \
Docs/plan_cache_community/run_sysbench_benchmark_suite.sh
```

This writes a top-level `plan-cache-formal-*/benchmark_artifact_summary.md`
after the child primary, shape, and fixed-rate artifact directories complete.

Fast value sequence, recommended for a quick community value decision:

```bash
ARTIFACT_ROOT=/path/to/artifacts \
SUITE_MODE=value \
TABLES=250 TABLE_SIZE=25000 THREADS="1 2 4 8 16" \
SHAPE_THREADS="1 2 4 8" \
BUFFER_POOL_SIZE=10G PREWARM_TIME=120 RUN_TIME=300 REPEATS=5 \
SERVER_CPUSET=0-7 SYSBENCH_CPUSET=8-15 \
Docs/plan_cache_community/run_sysbench_benchmark_suite.sh
```

This runs preflight, primary `oltp_read_only`, and `distinct_range` attribution
only, then writes `plan-cache-value-*/benchmark_artifact_summary.md`.  Use this
before full `formal` when the priority is deciding whether the feature has a
publishable value case.

Primary evidence gate after the run:

```bash
Docs/plan_cache_community/analyze_sysbench_summary.py \
  --require-primary-threads "1 2 4 8" \
  --detail-results /path/to/artifacts/plan-cache-primary-*/results.tsv \
  --min-positive-repeats 4 \
  /path/to/artifacts/plan-cache-primary-*/summary.tsv
```

`SUITE_MODE=primary` runs this gate automatically and writes
`primary_gate_analysis.md`. It requires every configured primary thread to
classify as primary and to have at least 4 positive QPS repeats by default.
Override `PRIMARY_GATE_THREADS` only when the tested host has a different
non-saturated concurrency range; override `PRIMARY_GATE_MIN_POSITIVE_REPEATS`
only when `REPEATS` changes.  `PRIMARY_GATE_THREADS=` disables the gate for
local smoke only, not for formal evidence.

If 16 threads is still below server CPU saturation on that host, include `16`
in `--require-primary-threads`; otherwise report it as saturation or boundary
evidence instead of making it part of the primary acceptance gate.

Benchmark artifact review draft:

```bash
Docs/plan_cache_community/summarize_benchmark_artifacts.py \
  /path/to/artifacts/plan-cache-primary-* \
  /path/to/artifacts/plan-cache-shapes-* \
  > /path/to/artifacts/benchmark_artifact_summary.md
```

Use `--fail-on-review-signals` when the summary is part of a CI/nightly gate.

`run_sysbench_benchmark_suite.sh` writes `benchmark_artifact_summary.md`
automatically for primary, shape, point, and fixed-rate runs.  The manual
command is useful when combining several artifact directories.

Shape attribution benchmark:

```bash
ARTIFACT_ROOT=/path/to/artifacts \
SUITE_MODE=shapes \
TABLES=250 TABLE_SIZE=25000 SHAPE_THREADS="1 2 4 8" \
BUFFER_POOL_SIZE=10G PREWARM_TIME=120 RUN_TIME=300 REPEATS=5 \
SERVER_CPUSET=0-7 SYSBENCH_CPUSET=8-15 \
Docs/plan_cache_community/run_sysbench_benchmark_suite.sh
```

Fixed-rate efficiency benchmark:

```bash
ARTIFACT_ROOT=/path/to/artifacts \
SUITE_MODE=fixed \
TABLES=250 TABLE_SIZE=25000 THREADS="1 2 4 8 16" \
BUFFER_POOL_SIZE=10G PREWARM_TIME=120 RUN_TIME=300 REPEATS=5 \
SERVER_CPUSET=0-7 SYSBENCH_CPUSET=8-15 \
Docs/plan_cache_community/run_sysbench_benchmark_suite.sh
```

Linearity diagnostic is only for root-cause investigation when QPS does not scale
with concurrency. It is not formal ON/OFF plan-cache evidence:

```bash
ARTIFACT_ROOT=/path/to/artifacts \
SUITE_MODE=diagnostic \
TABLES=250 TABLE_SIZE=25000 THREADS="1 2 4 8 16" \
BUFFER_POOL_SIZE=10G PREWARM_TIME=120 RUN_TIME=60 \
Docs/plan_cache_community/run_sysbench_benchmark_suite.sh
```

## Acceptance Criteria

Primary `oltp_read_only` claim:

- ON median QPS/TPS improves at 1/2/4 threads, and preferably remains positive at 8/16.
- ON CPU per kQPS improves, especially when QPS delta is small.
- `Cached_plan_hits` grows in every ON run.
- `Cached_plan_count` is non-zero during ON run sampling.
- `final_plan_cache_status.tsv` shows `Cached_plan_count` returned to baseline
  after sysbench clients disconnected.
- `Cached_plan_invalidations` remains 0.
- `mariadbd_error_summary.txt` has no unexplained warnings or errors.
- `run_manifest.txt` records the exact release build, CPU sets, server options,
  sysbench common arguments, timing, repeats, and gate parameters used.
- Coefficient of variation is low enough for median comparison; noisy single runs are not publishable.

Shape attribution claim:

- `distinct_range` should remain the strongest positive shape.
- `sum_range` should be positive by median, not judged by one short run.
- `simple_range` and `order_range` can be small positive supporting data.
- `point` should be marked as noise-boundary unless Linux medians are stable.

Community readiness:

- Keep feature default off.
- Keep unsupported SQL fail-closed.
- Avoid claiming full MySQL plan-cache parity.
- Frame the contribution as a session-level prepared-statement plan cache for narrow
  single-table SELECT recipes.

## Recommended Next Decision

Do not spend the next block on more production-code optimization unless Linux fixed-rate
or primary data proves the hit path is still slower after CPU isolation. The fastest path
to a credible result is to run primary `oltp_read_only`, then shape attribution, then
fixed-rate efficiency only if closed-loop QPS remains noisy.

## 2026-06-27 Status After Local Release Value Run

Local release evidence is now positive enough to stop speculative production-code
optimization:

```text
Artifact: /tmp/plan-cache-value-20260627-022352/plan-cache-primary-20260627-022352
Build: Release, ASAN OFF
Platform: local macOS/Darwin arm64, no Linux CPU-set isolation
Workload: oltp_read_only
Config: 64 tables, 25000 rows/table, 10G buffer pool, 60s, 3 repeats
```

Median result:

```text
t1   +26.32% QPS/TPS, -28.97% CPU/kQPS, 3/3 positive repeats
t2   +18.79% QPS/TPS, -20.57% CPU/kQPS, 3/3 positive repeats
t4   +12.99% QPS/TPS, -17.67% CPU/kQPS, 3/3 positive repeats
t8   +16.87% QPS/TPS, -17.58% CPU/kQPS, 3/3 positive repeats
t16  +11.74% QPS/TPS, -16.56% CPU/kQPS, 3/3 positive repeats
```

Status evidence:

```text
ON hit median by thread: 2324800, 3454196, 3848608, 5464762, 5505854
Cached_plan_invalidations: 0
live cached plan count max median: 320, 640, 1280, 2560, 5120
```

The suite exited with code 3 only because `REPEATS=3` was combined with a
formal default `PRIMARY_GATE_MIN_POSITIVE_REPEATS=4`.  Commit `be08973bba3`
fixed the suite so development runs cap the effective positive-repeat gate at
the actual repeat count.  Replaying the analysis with `--min-positive-repeats 3`
leaves only one local repeatability warning: t2 is supporting/noisy because
the OFF samples had 8.10% CV.  With `--max-cv 10`, all rows classify as primary
and the gate has no failures.

Next work should be Linux CPU-set validation, not more code changes:

```bash
ARTIFACT_ROOT=/path/to/artifacts \
SUITE_MODE=value \
TABLES=250 TABLE_SIZE=25000 THREADS="1 2 4 8 16" \
SHAPE_THREADS="1 2 4 8" \
BUFFER_POOL_SIZE=10G PREWARM_TIME=120 RUN_TIME=300 REPEATS=5 \
SERVER_CPUSET=0-7 SYSBENCH_CPUSET=8-15 \
Docs/plan_cache_community/run_sysbench_benchmark_suite.sh
```

Publishable community evidence still requires the Linux run to pass the default
gate: 1/2/4/8 primary rows, at least 4/5 positive repeats, low CV, non-zero
hits/live cached count, zero invalidations, and clean error summary.
