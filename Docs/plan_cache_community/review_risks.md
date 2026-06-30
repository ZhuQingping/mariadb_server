# Community Review Risks

This file lists the risks that MariaDB reviewers are most likely to focus on
and the current mitigation or closure plan. It is intentionally conservative:
any unsupported case must run through the normal optimizer/executor path.

## Risk Matrix

| Risk | Why it matters | Current mitigation | Before PR |
|---|---|---|---|
| Wrong results on unsupported SQL | A plan cache bug can silently return stale or incomplete rows. | Exact recipe matching; unsupported joins, views, derived tables, subqueries, broad ORDER/GROUP/DISTINCT, and nondeterministic cases fail closed. | Keep a public fail-closed table and focused MTR for every supported and rejected shape. |
| Memory and object lifetime | Reusing old optimizer/executor objects can leave dangling pointers across executions. | Cache stores a compact recipe and validation signature, then rebuilds executable state per hit. | Run debug and ASAN/LSAN passes; keep retained object ownership documented in code review. |
| Invalidation completeness | Table definition/data distribution, optimizer settings, charset, and parameter states can change between executions. | Validate table version, optimizer switch, charset, parameter signature, runtime null/no-value state, and optional row-count ratio. | Add optimizer trace or documented diagnostic output for invalidation reasons. |
| Partial mutation fallback | A failed hit after mutating `JOIN` state can corrupt a later normal execution. | Early failures fall back; late DISTINCT upper-state failures report an error instead of continuing with a partially mutated `JOIN`. | Keep DBUG fault-injection coverage and describe the boundary in commit bodies. |
| Public diagnostics surface | Too many status/profile variables create long-term compatibility obligations. | Stable counters are useful for proof: hits, prevalidations, invalidations, live count. | Decide whether profile-only counters stay debug-only, become diagnostics, or are removed before first PR. |
| Benchmark credibility | Local macOS results are useful engineering evidence but not final upstream evidence. | Reports separate local release evidence from the required publishable Linux CPU-set runs. | Re-run Linux release sysbench with CPU isolation, fixed data load, repeated off/on pairs, and environment capture. |
| Default-off rationale | A new optimizer feature must not surprise existing workloads. | `session_plan_cache` is default off; cache state is per prepared statement/session. | Document global-default versus session behavior and show no effect when disabled. |
| TaurusDB/MySQL parity | Reviewers may assume this is a full clone of the commercial implementation. | Current MariaDB design is a narrower recipe-rebuild stage. | Keep a delta table that names unsupported full-plan features and expansion order. |

## Review Focus Areas

- `SELECT_LEX` ownership and cleanup of cached recipe state.
- Handler/ref/range buffers rebuilt on hit, especially after errors.
- Eligibility checks before capturing a cache entry.
- Invalidation paths for metadata, optimizer switches, charset, null
  parameters, and optional row-count-ratio changes.
- Status counters and any profile counters that remain public.
- MTR coverage for both hits and rejected shapes.

## Closure Standard

The feature should be treated as community-ready only after:

- focused MTR passes on the final rewritten patch queue;
- broader prepared-statement regression tests pass;
- debug build and ASAN/LSAN evidence is recorded;
- release Linux sysbench evidence shows repeatable value for point-select and
  read-only cases;
- the submitted commit series is small enough for maintainers to review by
  functional boundary.
