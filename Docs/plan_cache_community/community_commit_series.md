# Community Commit Series

The original `plan_cache` branch is an integration branch. It records design,
benchmark, debugging, and local-agent history. It should not be submitted to
MariaDB as-is.

This package has been rewritten into a compact community candidate branch,
`plan_cache_community_series`, following the same coarse structure used by the
local `support_ptrc` branch:

```text
MDEV-PLAN-CACHE: Cache prepared SELECT plans
MDEV-PLAN-CACHE: Test prepared SELECT plan cache
MDEV-PLAN-CACHE: Document prepared SELECT plan cache
```

`MDEV-PLAN-CACHE` is a placeholder. Replace it with the real MDEV number before
opening a MariaDB pull request.

## Commit Message Rules

Use MariaDB-style subjects:

```text
MDEV-xxxxx: Cache prepared SELECT plans
```

Each core commit body should explain:

- why the change is needed;
- exact supported scope;
- fail-closed behavior;
- memory/lifetime assumptions;
- tests added or updated;
- benchmark summary when the commit is performance-sensitive.

Avoid upstream subjects such as `Docs: record ...`, `Bench: suggest ...`,
`Plan cache: profile ...`, or references to local working directories and
development-only coordination details. Those are useful branch history, not
community review units.

## Current Review Series

| Order | Upstream commit | Content |
|---|---|---|
| 1 | `MDEV-xxxxx: Cache prepared SELECT plans` | Core implementation: default-off sysvars, status counters, per-PS/session ownership, eligibility, validation, invalidation, equality/ref/range recipes, narrow sysbench read-only recipes, and fail-closed fallback. |
| 2 | `MDEV-xxxxx: Test prepared SELECT plan cache` | Focused MTR coverage: sysvars, lifecycle cleanup, status counters, invalidation, hit correctness, unsupported-shape fallback, binary protocol smoke, sysbench SELECT shapes, and debug fault injection. |
| 3 | `MDEV-xxxxx: Document prepared SELECT plan cache` | Community design, limitations, invalidation matrix, test report, performance evidence, benchmark harness, review risks, and contribution status. |

This coarse split matches `support_ptrc`. If MariaDB reviewers ask for smaller
patches, split commit 1 by recipe boundary and split commit 2 by test theme.
Do that as a second rewrite after the MDEV discussion, not by replaying the
original development history.

## Cleanup Applied

- `AGENTS.md`, `CLAUDE.md`, and `Docs/plan_cache_tasks/*` are not included in
  the community candidate branch.
- Development-only `Docs:*`, `Bench:*`, and profile-debug commits are folded
  into the three review commits or omitted.
- Public variables use neutral names such as `session_plan_cache`.
- The unrelated dirty submodule state under
  `storage/duckdb/third_parties/duckdb` is not included.

## Remaining Before PR

- Replace `MDEV-PLAN-CACHE` with the real MDEV number.
- Re-run final-HEAD focused MTR and broader prepared-statement regression on
  the rewritten branch.
- Record ASAN/LSAN evidence on the rewritten branch.
- Add Linux CPU-set release benchmark evidence before making a publishable
  performance claim.
