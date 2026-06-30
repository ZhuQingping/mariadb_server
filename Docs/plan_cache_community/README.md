# MariaDB Plan Cache Community Package

This directory collects the contribution-facing material for the current
MariaDB session plan cache work. It is intentionally shorter and more stable
than the phase-by-phase development log under `Docs/plan_cache_tasks/`.

## Current Position

The current implementation is suitable for a staged community discussion, not
as a claim of full parity with broader prior plan-cache implementations.

The community candidate branch is `plan_cache_community_series`. It follows the
local `support_ptrc` style with three commits: implementation, tests, and
documentation. The original `plan_cache` branch remains a development history
branch and should not be submitted directly.

The recommended public framing is:

```text
Session-level prepared-statement plan cache for narrow single-table SELECT
recipes, default off, with conservative fail-closed boundaries.
```

## Documents

- `community_design_proposal.md`: design and architecture for a MariaDB RFC/MDEV.
- `community_readiness_report.md`: contribution readiness and gap analysis
  versus broader prior plan-cache implementations.
- `community_review_closure.md`: current multi-agent review findings, closed
  documentation items, and remaining blockers.
- `patch_scope.md`: proposed patch-series split and review boundaries.
- `community_commit_series.md`: proposed MDEV-style commit rewrite plan and
  local-branch cleanup checklist.
- `known_limitations.md`: current unsupported SQL and why it stays closed.
- `invalidation_matrix.md`: validation and invalidation rules.
- `review_risks.md`: community review risk matrix and closure standard.
- `test_report.md`: current local verification evidence.
- `sysbench_benchmark_report.md`: benchmark plan and current release result.
- `benchmark_stabilization_plan.md`: revised reproducible benchmark strategy
  after unstable point-select results.
- `performance_root_cause_report.md`: root-cause analysis for plan-cache hit
  path overhead, completed optimizations, and remaining performance risks.
- `performance_optimization_backlog.md`: prioritized data-driven queue for
  remaining performance work and explicit short-term do-not-do items.
- `distinct_range_next_patch_plan.md`: narrow design gate for the only current
  profile-driven code candidate, exact sysbench DISTINCT range setup/explain.
- `current_status_and_next_steps.md`: current progress, remaining work estimate,
  next benchmark commands, and acceptance criteria.
- `reproducible_sysbench_harness.sh`: local harness for fixed-rate and
  closed-loop release sysbench evidence collection.
- `in_memory_sysbench_harness.sh`: in-memory TPS/QPS harness for
  all-in-memory point-select, read-only, and optional read-only template-shape
  comparisons. Set `COLLECT_PROFILE_STATUS=1` only for short profile-driven
  debug runs, not headline performance runs.
- `analyze_sysbench_summary.py`: post-processes harness `summary.tsv` files and
  classifies primary, supporting, noisy, and invalid performance evidence.
- `analyze_profile_status.py`: post-processes `raw/*.status_delta.tsv` files
  from profile-driven debug runs, reports per-hit hotspot counters, and emits
  conservative optimization advice.
- `compare_profile_status.py`: compares two profile/status delta sets, for
  example 1-thread versus 4-thread shape profiles, and highlights per-hit cost
  changes plus conservative candidate signals.
- `summarize_benchmark_artifacts.py`: turns completed benchmark artifact
  directories into a compact Markdown review summary for report drafting.
- `linearity_diagnostic_harness.sh`: diagnostic-only harness for checking
  client/server CPU scaling and table-cache counters; not formal ON/OFF
  performance evidence.
- `benchmark_env.sh`: shared host-environment capture helper used by benchmark
  harnesses.
- `run_sysbench_benchmark_suite.sh`: convenience wrapper for the preflight,
  primary, shape, point, fixed-rate, and diagnostic benchmark modes.

## Contribution Gates

Before opening a MariaDB community PR, the package should contain:

- focused MTR evidence for every supported recipe;
- at least one broader prepared-statement regression pass;
- debug and preferably ASAN memory-lifecycle evidence;
- sysbench point/read-only results with plan cache off/on;
- a patch series that keeps community review units small;
- a clear limitation statement that the first stage is not a full JOIN plan
  clone/cache implementation.

## References

- MariaDB pull request guidance:
  `https://mariadb.org/get-involved/getting-started-for-developers/submitting-pull-request/`
- MariaDB contribution process:
  `https://mariadb.org/the-mariadb-contribution-process-a-step-by-step-guide/`
- MariaDB test case guidance:
  `https://mariadb.org/get-involved/getting-started-for-developers/writing-good-test-cases-mariadb-server/`

The implementation was informed by prior MySQL plan-cache work, but this
community package should be self-contained and should not rely on local
proprietary paths for review.
