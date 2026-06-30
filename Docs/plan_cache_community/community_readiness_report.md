# Community Readiness Report

## Conclusion

The current MariaDB session plan cache has clear contribution value, but it
should be positioned as a staged RFC/MDEV contribution rather than a drop-in
equivalent to broader prior plan-cache implementations.

Recommended public framing:

```text
Default-off session-level prepared-statement plan cache for conservative
single-table SELECT recipes, with fail-closed validation and invalidation.
```

Estimated readiness:

| Dimension | Current assessment |
|---|---:|
| First-stage MariaDB community discussion | 60% to 70% |
| Direct mainline pull request readiness | not yet ready |
| Parity with broader prior plan-cache implementations | 25% to 35% |

The feature is valuable because it targets repeated prepared SELECT execution,
which is a common sysbench and application workload shape. The current
implementation is deliberately narrower than broader full-plan-cache designs,
which improves reviewability and reduces wrong-result risk for a first
community stage.

## Current Strengths

- The feature is default off through `session_plan_cache`.
- Public names have been moved away from `rds_` to neutral MariaDB-style names.
- The implementation uses conservative recipe reconstruction instead of broad
  executor object reuse.
- Unsupported query shapes fail closed rather than attempting partial reuse.
- Focused MTR coverage exists for prepared statement lifecycle, invalidation,
  sysbench point/ref/range shapes, SUM range, ORDER range, and DISTINCT range.
- Community-facing docs now describe scope, limitations, invalidation rules,
  test evidence, and benchmark requirements.

## Contribution Gaps

- A real MariaDB MDEV issue number is still needed before community submission.
- The community candidate branch uses `MDEV-PLAN-CACHE:` placeholder subjects;
  replace them with the real MDEV number once the issue exists.
- Full MTR evidence is not recorded for the final branch state.
- ASAN/LSAN evidence is not recorded for the final branch state.
- The current benchmark evidence is local macOS/Darwin release engineering
  evidence, not repeated Linux CPU-set community evidence.
- Optimizer trace output does not yet expose plan-cache decisions.
- The development task log under `Docs/plan_cache_tasks/` should not be part of
  the public community patch.
- `community_commit_series.md` and `review_risks.md` capture the rewritten
  community series and reviewer-facing risk matrix.

## Gap Versus Broader Prior Implementations

Broader prior MySQL implementations cache and restore more optimizer and
executor state, including full `JOIN` plan state, execution context, QEP tables,
access paths, range/index state, ORDER/GROUP state, temporary table parameters,
and transient item state.

The current MariaDB implementation instead stores a bounded recipe/signature and
rebuilds execution state. This is safer for initial review but has narrower
coverage and less parity.

Important missing or reduced areas:

- full JOIN plan cloning and restoration;
- table scan and index scan recipes beyond the current bounded shapes;
- broader covering-index and ICP handling;
- index merge;
- scalar subquery support;
- general aggregate support beyond narrow sysbench-style `SUM(field)` range;
- broader ORDER/GROUP/DISTINCT execution state;
- window-function interactions;
- transient `Item_cache`, temporal comparison, and expression clone handling;
- optimizer trace instrumentation;
- repeated long-duration sysbench and production-like validation.

## Contribution Strategy

Recommended first community stage:

1. Open an MDEV that describes the feature as a default-off session prepared
   SELECT plan cache.
2. Submit a small patch series rather than one large feature patch.
3. Keep unsupported shapes closed and document them explicitly.
4. Include focused MTR, broader prepared-statement MTR, debug build, release
   build, ASAN/LSAN where possible, and release sysbench evidence.
5. Exclude development-only task logs from the public patch.

Recommended patch split:

| Patch | Scope |
|---|---|
| 1 | system variables, counters, and empty lifecycle hooks |
| 2 | cache key/signature and invalidation framework |
| 3 | point/ref/range recipe support |
| 4 | narrow sysbench aggregate/order/distinct recipes |
| 5 | MTR coverage and community docs |
| 6 | optional optimizer trace and diagnostic polish |

## Pre-PR Checklist

- Create MDEV and rename commit subjects.
- Refresh `test_report.md` with final HEAD, debug build, release build, focused
  MTR, broader prepared-statement MTR, and ASAN/LSAN status.
- Run repeated Linux release sysbench with longer warmup/run windows and
  separated server/sysbench CPU sets.
- Record CPU, RSS, error-log warnings, and `Cached_plan_*` counters.
- Add optimizer trace evidence or document why it is deferred.
- Replace the placeholder `MDEV-PLAN-CACHE` commit prefix with the real MDEV
  number before submission.
- Run `git diff --check`.

## References

- MariaDB contribution process:
  `https://mariadb.org/the-mariadb-contribution-process-a-step-by-step-guide/`
- MariaDB code contribution guide:
  `https://mariadb.com/docs/general-resources/community/contributing-participating/contributing-code`
- MariaDB community contribution policy:
  `https://github.com/MariaDB/server/blob/main/COMMUNITY_CONTRIBUTIONS.md`
- Prior MySQL implementation notes used during local research.
