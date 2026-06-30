# Community Contribution Review Closure

This note closes the current multi-agent community-readiness review. It is not
a claim that the feature is ready for a MariaDB PR; it records what was checked,
what has been fixed in the documentation package, and what remains blocking.

## Review Inputs

Three read-only review agents checked independent areas:

| Area | Result |
|---|---|
| Commit series and commit logs | The original development history was not suitable for direct upstream submission. It has been rewritten into a compact `support_ptrc`-style candidate series. |
| Design documents | Main semantics were mostly documented, but public contract details were incomplete. |
| Test and performance evidence | Focused local evidence is strong, but final PR evidence is missing for Linux CPU-set benchmark, final-HEAD MTR, and ASAN/LSAN. |

The unrelated dirty submodule state under `storage/duckdb/third_parties/duckdb`
was ignored.

## Findings Closed In Documentation

- Added `community_commit_series.md` with the upstream candidate patch queue,
  commit-message rules, and cleanup checklist.
- Added `review_risks.md` with reviewer-facing risks, mitigations, and closure
  gates.
- Updated the design proposal to clarify that cache state is per prepared
  statement/session, while `session_plan_cache` also has a global-default scope
  for new sessions.
- Clarified that `Cached_plan_count` is a global live-state counter; session
  status currently reports `0`.
- Clarified that `session_plan_cache_allow_change_ratio=0` disables row-count
  change invalidation, and positive values enable it.
- Expanded the fail-closed boundary to cover `EXPLAIN`/`ANALYZE`, locking
  clauses, user variables, side effects, nondeterministic expressions, and
  related unsupported shapes.
- Added a TaurusDB/MySQL delta table to avoid implying parity with the broader
  commercial implementation.

## Remaining Blockers

- Create an MDEV and replace the placeholder `MDEV-PLAN-CACHE` commit prefix
  before submitting.
- Do not submit the original `plan_cache` development branch; use the curated
  `plan_cache_community_series` branch.
- Re-run final-HEAD focused MTR and broader prepared-statement regression.
- Record final-HEAD ASAN/LSAN evidence.
- Produce publishable Linux release sysbench evidence with separated server and
  sysbench CPU sets, fixed data load, repeated off/on pairs, and captured
  environment.
- Decide whether profile-only status variables are public diagnostics,
  debug-only diagnostics, or removed before the first PR.
- Add optimizer trace output or document it as a follow-up accepted by the MDEV
  discussion.

## Current Contribution Status

The feature is suitable for an RFC/MDEV discussion after the documentation
updates in this package. It is not yet suitable for a direct mainline MariaDB
pull request because final verification and patch-queue cleanup are still
missing.
