# Invalidation Matrix

## Validation Inputs

| Input | Current handling | Evidence |
|---|---|---|
| `session_plan_cache` disabled | no state creation or hit | `session_plan_cache_noop_eligibility` |
| Prepared statement context | only `EXECUTE` can participate | multiple `session_plan_cache*` MTR tests |
| SQL command | only `SELECT` eligible | `session_plan_cache_non_select_boundary` |
| Query block shape | top-level single-level statement only | `session_plan_cache_readiness_boundary` |
| Table category | user base table only | `session_plan_cache_information_schema_boundary`, `session_plan_cache_view_boundary` |
| Optimizer switch | invalidates on change | `session_plan_cache_environment_invalidation` |
| Client character set | invalidates on change | `session_plan_cache_environment_invalidation` |
| Table version | invalidates after DDL/key metadata change | `session_plan_cache_real_hit_boundaries` |
| Row count | invalidates beyond configured ratio | `session_plan_cache_access_shape`, debug fault injection |
| Parameter signature | invalidates on shape/type/null/no-value mismatch | `session_plan_cache_parameter_shape` |
| Access signature | invalidates when access path no longer matches | `session_plan_cache_access_shape` |
| Reprepare | destroys or invalidates state | `session_plan_cache_state_machine` and lifecycle tests |
| Deallocate | releases live state | most recipe tests assert count returns to baseline |
| Disconnect/change user | releases live state | `session_plan_cache_disconnect_count`, `session_plan_cache_change_user_count` |

## Recipe Boundaries

| Shape | Eligible | Notes |
|---|---:|---|
| `field = ?` on non-null single-column unique key | yes | `UNIQUE_EQ_PARAM` |
| `? = field` on non-null single-column unique key | yes | same recipe |
| literal `LIMIT 1` on unique equality | yes | compatibility boundary |
| non-unique indexed equality | yes | `REF_EQ_PARAM` |
| `field BETWEEN ? AND ?` on non-null single-column key | yes | `RANGE_BETWEEN_PARAM` |
| sysbench `SUM(field)` over range | yes | only one aggregate field |
| sysbench one-field `ORDER BY` over range | yes | selected field must match order field |
| sysbench one-field `DISTINCT ... ORDER BY` over range | yes | selected field must match order field |
| ref/range/order/distinct with `LIMIT 1` | no | negative coverage in `session_plan_cache_sysbench_coverage` |
| nullable key parts | no | key helper rejects nullable fields |
| composite keys | no | helper requires one user-defined key part |
| extra predicates | no | recipe parser requires one equality or one BETWEEN predicate |
| `SQL_CALC_FOUND_ROWS` | no | found-row semantics preserved by normal executor |

## Failure Semantics

Most recipe rebuild failures return `FALLBACK`, allowing normal optimization.
If a failure happens after a supported DISTINCT range hit has committed upper
`JOIN` state, the code returns `ERROR` instead of falling back through a mutated
`JOIN`. Debug-only MTR coverage exercises this path.
