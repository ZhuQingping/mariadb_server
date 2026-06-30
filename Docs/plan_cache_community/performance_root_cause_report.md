# Plan Cache Performance Root-Cause Report

## Summary

当前实现曾经存在明确的命中路径性能问题：range 查询虽然 `Cached_plan_hits`
全命中，但命中后仍会走 `SQL_SELECT::test_quick_select()`，等价于每次执行仍
重新做一段代价较高的 range optimizer 工作。这会抵消 plan cache 的收益，
也是“全命中但性能劣化”的主要原因。

这不是 plan cache 方向本身无价值，而是命中路径还没有足够短。当前分支已经
通过多组小提交把主要重型开销削掉，短测中 `oltp_read_only` 已从劣化转为
明显正收益。剩余开销主要集中在执行态结构初始化、内存分配/清零和真实 handler
索引读取，不再是简单的“缓存了计划仍重新优化”的问题。

## Test Context

本报告中的数据来自本地 release 构建的阶段性定位，不作为最终社区性能结论。

```text
repository: /Users/zhuqingping/Work/Database/MariaDB/server-plan-cache
branch: plan_cache
HEAD at report time: 8d6e7e9cda6
build: build_plan_cache_release
binary: build_plan_cache_release/sql/mariadbd
build type: Release
ASAN: OFF
query cache: OFF
sysbench: 1.0.20
```

定位阶段使用短窗口 sysbench 和 plan-cache 内部 profile status 拆分热点。正式
对外性能数据仍应使用 `benchmark_stabilization_plan.md` 中的长时间、多轮、
绑核、全内存方案。

## Root Cause

### What Was Wrong

range 查询命中 plan cache 后，旧路径仍调用 `test_quick_select()` 构造 range
quick。这意味着缓存只绕过了一部分上层准备工作，没有绕过最核心的一段 range
访问路径选择和 quick 构造成本。

在 sysbench `oltp_read_only` 中，range/sum/order/distinct range 模板占比不低。
因此即使 status 显示 plan cache 全命中，也可能出现：

- `Cached_plan_hits` 持续增长；
- `Cached_plan_invalidations=0`；
- 但 QPS/TPS 无提升，甚至劣化。

这种现象说明“命中”语义正确，但命中路径过重。

### Evidence Before Fix

在 direct range quick 优化前，profile 显示 range 命中仍有明显构造成本：

| Counter | Approx cost |
|---|---:|
| range hit build | ~2.35 us / range hit |
| `test_quick_select()` portion | ~1.97 us / range hit |

这部分成本足以吞掉 plan cache 在 parser/optimizer 准备阶段节省的收益。

## Optimizations Completed

已完成的性能优化均拆成小提交，便于后续 review 和回退。

| Commit | Change | Effect |
|---|---|---|
| `16227a1bb91` | release 下跳过 trace eligibility 热路径检查 | 减少非必要状态检查 |
| `2cb287fb39c` | 命中路径复用 cached recipe | 避免重复构造 recipe |
| `77f999a786a` | range recipe 复用参数和签名元数据 | 减少 range 命中解析工作 |
| `303aaffbe8f` | range 命中直接构造 `QUICK_RANGE_SELECT` | 避免命中后调用 `test_quick_select()` |
| `2d29c0b7157` | validation 参数签名比较避免临时分配 | validation 开销下降 |
| `7528e61496a` | prevalidation 避免重建 access recipe | prevalidation 开销下降 |
| `2a058338bf0` | 收窄 execute-time eligibility 检查 | validation 热路径继续下降 |
| `a5887a3a9db` | 缓存 range MRR 元数据并拆分 setup profile | range quick/setup 继续降本，并暴露剩余热点 |
| `0e68fb26b95` | range hit 复用缓存 field metadata | 避免每次命中重新拆 `BETWEEN` 表达式树 |
| `16b47d5418c` | 普通 range hit 缩小 JOIN_TAB setup 分配 | 普通 range 不再固定分配 3 个 `JOIN_TAB` 容量 |
| `40cdccbd8cf` | recipe 缓存 `Item_param*` | unique/ref/range hit 不再按下标扫描 `LEX::param_list` |
| `44d2bafae75` | SUM/ORDER range hit 缩小 JOIN_TAB setup 分配 | 非 DISTINCT 的 SUM/ORDER range 不再按 DISTINCT 容量分配 `JOIN_TAB` |
| `4ec5e8cc09c` | plan-cache range quick 使用 statement root | 避免每次 hit 初始化/释放 `QUICK_RANGE_SELECT` 内部 MEM_ROOT |
| `2c5ea0b7b7c` | direct range hit 合并 `SQL_SELECT` 与 setup 分配 | direct quick 成功时不再单独 `make_select()` |
| `3ce024c0041` | unique equality hit 使用 ref lookup 执行形态 | 避免每次 hit 在构建阶段做 const-table read |
| `ec485fd60e0` | simple/SUM range hit 跳过未使用的 POSITION tail 构造 | 降低无 ORDER/DISTINCT range setup allocation |
| `392f206f245` | 单列非空唯一键 ref hit 跳过 next-record probe | 避免每个命中行额外调用 `join_read_next_same()` |
| `5580f5f1f4c` | 合并 ref hit key setup 小分配 | 减少 key buffer、key copier 和 ref 数组的 memroot 分配次数 |
| `8edfcc793af` | 增加 HIT 后 `build_explain()` profile 计数 | 量化 explain/执行态初始化在命中路径中的剩余成本 |
| `ee42d3f69b8` | 普通单表 HIT 使用轻量 explain/tracker 初始化 | 避免非 EXPLAIN/ANALYZE 路径填充完整 explain payload |
| `9540cbbd91b` | SUM range HIT 使用专用聚合 metadata setup | 降低 sysbench SUM range 的 post setup 成本 |
| `6c1e4e0cd22` | 整数 ref/unique HIT 使用专用 key copier | 避免每次点查 HIT 创建临时 key `Field` |
| `97b50a6ca91` | 整数 BETWEEN range HIT 合并两端 key 写入 | 减少 range quick 构造中的 field-copy 上下文切换 |
| `4635ca2d2ec` | ref HIT 跳过已覆盖数组清零 | 去掉 `best_ref`/`table_vector` 的无效小清零 |
| `84e113d4a65` | inline recipe prevalidation | 保留 prevalidation 计数语义，减少一次热路径函数调用 |
| `972db4d662a` | execute validation 复用已验证 `TABLE*` | 避免每次 HIT validation 重复取单表上下文 |
| `8d6e7e9cda6` | 单字段 DISTINCT range 使用专用 group 构造 | 降低 sysbench DISTINCT range HIT 的 group setup 成本 |

## Current Profile

MRR 元数据缓存和 setup profile 拆分后，短测中的关键状态如下：

```text
Cached_plan_hits: 783183
Cached_plan_invalidations: 0
range hits: 223764
unique hits: 559419
```

range 命中成本：

| Counter | Total | Approx cost |
|---|---:|---:|
| range build | 160753 us | ~0.718 us / range hit |
| range quick construction | 46908 us | ~0.210 us / range hit |
| range setup total | 87019 us | ~0.389 us / range hit |
| range setup alloc | 25080 us | ~0.112 us / range hit |
| range setup base | 7168 us | ~0.032 us / range hit |
| range setup distinct | 5374 us | ~0.024 us / range hit |
| range setup order | 3623 us | ~0.016 us / range hit |
| range setup post | 21198 us | ~0.095 us / range hit |

unique 命中成本：

| Counter | Total | Approx cost |
|---|---:|---:|
| unique build | 497581 us | ~0.890 us / unique hit |
| unique read | 396832 us | ~0.710 us / unique hit |
| unique setup | 66645 us | ~0.119 us / unique hit |

解释：

- range 主要重型问题已经从 `test_quick_select()` 转移到 setup 分配/清零和 post
  setup。
- unique 的 `read` 开销是真实 handler 索引读取，不属于可通过缓存执行计划完全
  消除的优化器开销。
- 当前 profile 本身带有计时器开销，不能直接等同于最终无 profile 的 QPS 结果。

### Unique Ref Next Probe

`3ce024c0041` 将 unique equality hit 从 const-table 读切到 ref 执行形态后，
执行器会在读到一行后继续调用 `join_read_next_same()` 判断是否还有下一行。对
单列、非空、唯一键而言，该 probe 在语义上多余，并会让 `Handler_read_next`
随命中行增长。

`392f206f245` 在 `build_ref_eq_lookup_plan()` 中区分单列唯一键与普通 ref key：
单列唯一键使用 `join_no_more_records`，普通非唯一 ref 仍保留
`join_read_next_same`。这样既保留非唯一 ref 查询的多行语义，也消除了 sysbench
点查主键命中路径上的额外 handler next 调用。

验证：

```text
MTR:
  main.session_plan_cache_unique_eq_real_hit     pass
  main.session_plan_cache_sysbench_coverage      pass
  main.session_plan_cache_state_machine          pass

short release sanity, oltp_point_select, 8 tables x 50000 rows, 20s:
  pc=OFF threads=1  qps ~=  93231.60  hits=0        Handler_read_next=1
  pc=ON  threads=1  qps ~= 101458.02  hits=2029192  Handler_read_next=1
  pc=OFF threads=8  qps ~= 205616.94  hits=2029192  Handler_read_next=1
  pc=ON  threads=8  qps ~= 203960.17  hits=6108427  Handler_read_next=1
```

解释：

- 修复前，focused MTR 中 primary-key real hit 读到两行后
  `Handler_read_next` 增长 2，证明 ref 执行形态引入了额外 next probe。
- 修复后，短测中 plan cache ON 的 `Cached_plan_hits` 持续增长，但
  `Handler_read_next` 不随命中增长。
- 该短测只用于验证局部优化方向；正式性能结论仍需使用稳定 benchmark 方案重跑。

### Ref Key Setup Allocation

`build_ref_eq_lookup_plan()` 在每次 ref/unique hit 中需要构造 `TABLE_REF` 运行态：
key buffer、`store_key*` 数组、`Item*` 数组、`cond_guards` 数组以及
`store_key_item`。这些对象生命周期都绑定当前 statement memroot，原实现会在
已有 `multi_alloc_root()` 之外再做多次小分配。

`5580f5f1f4c` 将这些对象合并进同一次 `multi_alloc_root()`，并用 placement new
构造 `store_key_item`。该改动不改变 ref 执行语义，只减少 hit path 的 allocator
调用次数。

验证：

```text
MTR:
  main.session_plan_cache_unique_eq_real_hit     pass
  main.session_plan_cache_sysbench_coverage      pass
  main.session_plan_cache_state_machine          pass

short release profile, oltp_point_select, 1 thread, 20s:
  before:
    Cached_plan_hits:                         1782451
    Cached_plan_profile_hit_unique_build_us:   177703
    approx unique build:                       0.100 us/hit

  after:
    Cached_plan_hits:                         1871755
    Cached_plan_profile_hit_unique_build_us:   174437
    approx unique build:                       0.093 us/hit
    Handler_read_next:                         1
```

解释：该收益是微优化级别，但方向稳定，且对 sysbench 点查主键命中路径直接相关。

`4635ca2d2ec` 进一步去掉 ref builder 中 `best_ref[0..1]` 和
`table_vector[0..1]` 的两次小清零。这两个数组在同一函数后续被完整赋值：
`best_ref[0]=tab`、`best_ref[1]=0`、`table_vector[0]=table`、
`table_vector[1]=0`。`map2table` 仍保留清零，因为执行期存在按 table map bit
访问的路径。

验证：

```text
MTR:
  main.session_plan_cache_unique_eq_real_hit     pass
  main.session_plan_cache_sysbench_coverage      pass
  main.session_plan_cache_parameter_shape        pass
  main.session_plan_cache_state_machine          pass
  main.session_plan_cache_debug_fault_injection  pass

short release profile, oltp_point_select, 1 thread, 20s:
  run 1:
    Cached_plan_hits:                         1816043
    Cached_plan_profile_hit_unique_build_us:   157808
    approx unique build:                       0.0869 us/hit

  run 2:
    Cached_plan_hits:                         1803259
    Cached_plan_profile_hit_unique_build_us:   152187
    approx unique build:                       0.0844 us/hit
```

解释：这是可证明语义等价的微优化，收益幅度小，只作为点查命中路径继续降本的补充。

### Hit Explain Cost

即使命中路径已经绕过普通 optimizer，MariaDB 当前执行流程仍会在
`JOIN::optimize()` 末尾调用 `JOIN::build_explain()`。之前直接跳过
`build_explain()` 或构造 minimal explain 的实验都被 MTR 证伪，因为
`build_explain()` 不只是生成 EXPLAIN 输出，还会初始化执行期需要的 tracker 和
table access explain 对象。

`8edfcc793af` 增加 `Cached_plan_profile_hit_explain_us`，只在
`session_plan_cache_profile=ON` 且本次为 plan cache HIT 时统计
`build_explain()` 时间。该计数器用于定位，不改变 profile 关闭时的默认执行语义。

验证：

```text
MTR:
  main.session_plan_cache_status              pass
  main.session_plan_cache_unique_eq_real_hit  pass
  main.session_plan_cache_sysbench_coverage   pass
  main.session_plan_cache_state_machine       pass

short release profile, oltp_read_only, 1 thread, 20s:
  Cached_plan_hits:                         805338
  Cached_plan_profile_hit_build_us:         183032
  Cached_plan_profile_hit_explain_us:       109242
  approx hit build:                         0.227 us/hit
  approx hit explain:                       0.136 us/hit

short release profile, oltp_point_select, 1 thread, 20s:
  Cached_plan_hits:                         1859477
  Cached_plan_profile_hit_build_us:         175096
  Cached_plan_profile_hit_explain_us:       215196
  approx unique build:                      0.094 us/hit
  approx hit explain:                       0.116 us/hit
```

解释：

- 点查场景中，HIT 后 `build_explain()` 成本已经高于当前 unique hit builder 本身。
- read_only 场景中，`build_explain()` 和 range setup/post 属于同一量级的剩余成本。
- 下一阶段真正有价值的优化方向不是简单跳过 `build_explain()`，而是拆分
  “执行态 tracker 初始化”和“Explain 输出数据生成”，让普通非 EXPLAIN/ANALYZE
  的 plan cache HIT 只保留执行所需初始化。

### Light Hit Explain Setup

`ee42d3f69b8` 将上一节的 profile 结果落地为一个收窄优化：对普通单表
plan cache HIT，在非 `EXPLAIN`、非 `ANALYZE`、非 slow-log explain/engine、
非派生表/子查询/pushdown、非临时表、非 `ORDER BY`/`GROUP BY`/`DISTINCT`、
非 filesort 的场景下，不再调用完整 `JOIN::build_explain()`，而是只创建执行期
会被 `JOIN::exec()` 和 `sub_select()` 解引用的 `Explain_select`、
`Explain_table_access` 和 tracker 指针。

该边界是通过失败实验收窄出来的：曾尝试对更宽的单表 HIT 跳过完整
`build_explain()`，但 `session_plan_cache_sysbench_coverage` 中
`SELECT c FROM sbtest1 WHERE id BETWEEN ? AND ? ORDER BY c` 会在
`Filesort_tracker::report_use()` 崩溃。原因是 filesort 路径依赖完整
`JOIN_TAB::save_explain_data()` 初始化的 `Filesort_tracker`。因此最终实现明确
排除 `ORDER BY`、临时表、filesort、聚合 explain 等复杂场景，只覆盖 sysbench
点查和一部分简单单表 HIT。

验证：

```text
MTR:
  main.session_plan_cache_explain_analyze_boundary  pass
  main.session_plan_cache_unique_eq_real_hit        pass
  main.session_plan_cache_sysbench_coverage         pass
  main.session_plan_cache_state_machine             pass

release build:
  cmake --build build_plan_cache_release --target mariadbd --parallel 16
```

短窗口 release profile 对比：

```text
oltp_point_select, 1 thread, 20s, profile ON

before:
  Cached_plan_hits:                       1859477
  Cached_plan_profile_hit_build_us:       175096
  Cached_plan_profile_hit_explain_us:     215196
  approx hit explain:                     0.116 us/hit
  QPS:                                    92972.79

after:
  Cached_plan_hits:                       1991063
  Cached_plan_profile_hit_build_us:       190912
  Cached_plan_profile_hit_explain_us:      99389
  approx hit explain:                     0.050 us/hit
  QPS:                                    99551.82
  Handler_read_next:                      1
```

`oltp_read_only` 也重新采样，确认 mixed select 覆盖下没有回退到崩溃路径：

```text
oltp_read_only, 1 thread, 20s, profile ON

transactions:                              54437
queries:                                  870992
Cached_plan_hits:                         762078
Cached_plan_invalidations:                0
Cached_plan_profile_hit_build_us:         172595
Cached_plan_profile_hit_explain_us:        56818
approx hit explain:                       0.075 us/hit
Cached_plan_profile_hit_range_count:      217716
Cached_plan_profile_hit_unique_count:     544362
```

解释：

- 点查主键 HIT 是该优化最直接覆盖的场景，`hit_explain_us` 从约
  `0.116 us/hit` 降到约 `0.050 us/hit`。
- `read_only` 中仍有 `ORDER BY`/range/filesort 等复杂模板会回退完整
  `build_explain()`，因此 mixed 场景的平均值不会降到点查水平。
- 该优化是保守裁剪，不尝试改变 EXPLAIN/ANALYZE 或 slow-log explain 语义。

### SUM Range Aggregate Setup

sysbench `oltp_read_only` 中的 `sum_ranges` 模板为：

```sql
SELECT SUM(k) FROM sbtest%u WHERE id BETWEEN ? AND ?
```

该模板没有 `GROUP BY`、`ORDER BY`、`DISTINCT`、`HAVING` 或临时表需求，但旧的
plan-cache range HIT 仍会进入通用 `JOIN::make_aggr_tables_info()` 聚合收尾路径。
对于这个窄形态，通用路径中的 `make_group_fields()` 只是在无 group key 时设置
`sort_and_group`，`setup_copy_fields()` 也不会为单个 `SUM_FUNC_ITEM` 生成真实
copy field。新路径增加 `JOIN::setup_plan_cache_sum_range_aggr_tables_info()`：

- 只在单表、无 ORDER/GROUP/DISTINCT/HAVING/tmp/window/rollup、单个普通
  `SUM(field)`、`tmp_table_param.sum_func_count == 1` 时启用；
- 仍保留 `prepare_sum_aggregators()` 与 `setup_sum_funcs()`，不复用聚合执行态，
  避免跨 execute 的 SUM 状态污染；
- 只用直接 list/ref 初始化替代无 GROUP BY 下的通用 metadata 重建；
- 条件不满足时自动回退 `make_aggr_tables_info()`。

验证：

```text
MTR:
  main.session_plan_cache_sysbench_coverage      pass
  main.session_plan_cache_state_machine          pass
  main.session_plan_cache_debug_fault_injection  pass

release build:
  cmake --build build_plan_cache_release --target mariadbd --parallel 16
```

`session_plan_cache_sysbench_coverage` 额外覆盖了同一 SUM prepared statement 下
“有行 -> 空范围 -> 有行”的连续执行，空范围返回 `NULL`，用于防止聚合状态沿用。

SUM-only profile 使用 sysbench `oltp_read_only`，关闭 point/simple/order/distinct，
只保留 `sum_ranges=1`：

```text
baseline:
  Cached_plan_profile_hit_range_count:          548935
  Cached_plan_profile_hit_range_build_us:       262511
  Cached_plan_profile_hit_range_setup_us:       163108
  Cached_plan_profile_hit_range_setup_post_us:   38572
  approx build:                                  0.478 us/hit
  approx setup:                                  0.297 us/hit
  approx post:                                   0.070 us/hit

candidate:
  Cached_plan_profile_hit_range_count:          534048
  Cached_plan_profile_hit_range_build_us:       249269
  Cached_plan_profile_hit_range_setup_us:       149048
  Cached_plan_profile_hit_range_setup_post_us:   28285
  approx build:                                  0.467 us/hit
  approx setup:                                  0.279 us/hit
  approx post:                                   0.053 us/hit
```

解释：

- 该优化主要降低 SUM range 的 post setup，约 `0.070 -> 0.053 us/hit`。
- mixed `oltp_read_only` 中 SUM 只是 range 模板的一部分，且 macOS 本机 QPS 噪声
  较大，因此不把该补丁单独作为整体 TPS/QPS 提升证明。
- 社区性能主张仍应以固定速率 `oltp_read_only` 多轮 CPU/event 和低并发 closed-loop
  sanity 为准。

### Integer Ref Key Copier

`build_ref_eq_lookup_plan()` 每次 unique/ref HIT 都需要构造 `TABLE_REF` 运行态。旧路径
使用 `store_key_item`，其基类 `store_key` 会为 key buffer 调用
`Field::new_key_field()` 创建临时 key `Field`，执行时再通过 `Item::save_in_field()`
写入 key buffer。对 sysbench 点查 `WHERE id=?` 这种单列整数主键场景，这些步骤比
必要路径更重。

新路径增加 `Plan_cache_int_store_key`，只在以下条件全部满足时使用：

- 单列、非 NULL keypart；
- key field 类型为 `TINY/SHORT/INT24/LONG/LONGLONG`；
- 当前 `Item_param` 可返回 `INT_RESULT` 的 `const_ptr_longlong()`；
- 仍保留 `TABLE_REF::key_copy`，执行器继续通过 `cp_buffer_from_ref()` 调用 `copy()`；
- 参数签名变化仍由 plan-cache validation 失效处理。

专用 copier 不创建临时 key `Field`，而是在 `copy_inner()` 中临时把原 field 移到
key buffer，调用 `Field::store(longlong, unsigned_flag)`，再恢复原 field 指针。
非整数或参数类型不匹配时回退原 `store_key_item`。

验证：

```text
MTR:
  main.session_plan_cache_unique_eq_real_hit     pass
  main.session_plan_cache_sysbench_coverage      pass
  main.session_plan_cache_parameter_shape        pass
  main.session_plan_cache_state_machine          pass
  main.session_plan_cache_debug_fault_injection  pass

release build:
  cmake --build build_plan_cache_release --target mariadbd --parallel 16
```

`oltp_point_select` 1 线程、20 秒、profile ON，两轮采样：

```text
candidate run 1:
  Cached_plan_hits:                         1878068
  Cached_plan_profile_hit_unique_build_us:   164428
  approx unique build:                       0.0875 us/hit

candidate run 2:
  Cached_plan_hits:                         1995576
  Cached_plan_profile_hit_unique_build_us:   176301
  approx unique build:                       0.0883 us/hit
```

对比轻量 explain 后、该优化前的点查 profile：

```text
before:
  Cached_plan_hits:                         1913681 / 1899506
  Cached_plan_profile_hit_unique_build_us:   181000 / 183437
  approx unique build:                       0.095 - 0.097 us/hit
```

解释：

- 该优化直接面向 sysbench point-select 主键 HIT，也会覆盖 read_only 中的 primary-key
  point selects。
- 它不改变 ref 执行形态、不跳过 explain/tracker 初始化，也不清空 `key_copy`，因此
  避免了早期“整数 ref + 跳过 explain”实验中的崩溃问题。
- mixed `oltp_read_only` 中 unique build 受 range/filesort/调度噪声影响更大，不能
  用单轮 QPS 证明该补丁；点查 per-hit builder counter 是更直接证据。

### Later Hit-Path Profile Smoke

在后续小优化后，使用 release build、临时 datadir、query cache 关闭、
`session_plan_cache_profile=ON` 做过单连接 prepared-statement smoke。该数据只用于
确认优化方向，不作为正式 QPS 结论。

普通 range:

```text
query: SELECT c FROM t WHERE k BETWEEN ? AND ?
executions after warmup: 3000
Cached_plan_hits: 3000
Cached_plan_invalidations: 0
Cached_plan_profile_hit_range_build_us: 1614
Cached_plan_profile_hit_range_make_select_us: 70
Cached_plan_profile_hit_range_quick_select_us: 468
Cached_plan_profile_hit_range_setup_us: 797
Cached_plan_profile_hit_range_setup_alloc_us: 209
Cached_plan_profile_hit_range_setup_post_us: 80
```

三类 hit 混合 smoke:

```text
queries:
  SELECT c FROM t WHERE id=?
  SELECT c FROM t WHERE k=?
  SELECT c FROM t WHERE k BETWEEN ? AND ?
executions after warmup: 3000 each
Cached_plan_hits: 9000
Cached_plan_invalidations: 0
Cached_plan_profile_hit_unique_count: 3000
Cached_plan_profile_hit_ref_count: 3000
Cached_plan_profile_hit_range_count: 3000
Cached_plan_profile_hit_build_us: 3938
Cached_plan_profile_hit_unique_build_us: 2128
Cached_plan_profile_hit_ref_build_us: 339
Cached_plan_profile_hit_range_build_us: 1471
Cached_plan_profile_prevalidate_us: 172
Cached_plan_profile_validate_us: 244
```

历史 HEAD 重新采样:

```text
HEAD: 1a8b1db31ac
queries:
  SELECT c FROM t WHERE id=?
  SELECT c FROM t WHERE k=?
  SELECT c FROM t WHERE k BETWEEN ? AND ?
executions after warmup: 10000 each
Cached_plan_hits: 30000
Cached_plan_invalidations: 0
Cached_plan_profile_hit_build_us: 13090
Cached_plan_profile_hit_path_us: 14323
Cached_plan_profile_hit_unique_count: 10000
Cached_plan_profile_hit_unique_build_us: 6876
Cached_plan_profile_hit_unique_setup_us: 1262
Cached_plan_profile_hit_unique_read_us: 4975
Cached_plan_profile_hit_ref_count: 10000
Cached_plan_profile_hit_ref_build_us: 1142
Cached_plan_profile_hit_range_count: 10000
Cached_plan_profile_hit_range_build_us: 5072
Cached_plan_profile_hit_range_make_select_us: 188
Cached_plan_profile_hit_range_quick_select_us: 1683
Cached_plan_profile_hit_range_setup_us: 2385
Cached_plan_profile_hit_range_setup_alloc_us: 649
Cached_plan_profile_hit_range_setup_base_us: 329
Cached_plan_profile_hit_range_setup_order_us: 188
Cached_plan_profile_hit_range_setup_post_us: 221
Cached_plan_profile_prevalidate_us: 572
Cached_plan_profile_validate_us: 898
```

解释：

- 普通 range setup allocation 已降到约 `0.07 us / range hit`。
- range build 在该 smoke 中约 `0.49 us / range hit`。
- ref build 很轻，当前不再是优先优化点。
- unique build 仍包含真实 const-table read，不能简单归因于 plan-cache setup。

`84e113d4a65` 将 recipe prevalidation 固定逻辑折叠到
`validate_state_for_execute()` 内部。该路径在 state 已经非空且 validation 通过后
执行，原 helper 只做 `access_recipe.kind != NONE`、递增
`Cached_plan_prevalidations` 和 DBUG 输出；新路径保留这些语义和
`Cached_plan_profile_prevalidate_us` 计时窗口。

```text
MTR:
  main.session_plan_cache_status                pass
  main.session_plan_cache_state_machine         pass
  main.session_plan_cache_sysbench_coverage     pass
  main.session_plan_cache_parameter_shape       pass
  main.session_plan_cache_debug_fault_injection pass

short release profile, oltp_point_select, 1 thread, 20s:
  run 1:
    Cached_plan_hits:                    1917954
    Cached_plan_profile_prevalidate_us:    36872
    approx prevalidate:                  0.0192 us/hit

  run 2:
    Cached_plan_hits:                    1798564
    Cached_plan_profile_prevalidate_us:    34409
    approx prevalidate:                  0.0191 us/hit
```

解释：该改动收益很小，只减少固定函数边界开销；因为状态机和计数 MTR 均通过，
保留为热路径微优化。

`972db4d662a` 继续裁剪 validation 热路径：`check_execute_eligibility()` 已经
通过 `single_table(select_lex)` 取得并验证 `TABLE*`、`TABLE_SHARE`、用户表类别和
临时表状态，`validate_state()` 随后又重复调用一次 `single_table()`。新路径让
execute eligibility helper 通过可选输出参数返回已验证的 `TABLE*`，后续 table
version 与统计变更检查复用该指针。

```text
MTR:
  main.session_plan_cache_sysbench_coverage          pass
  main.session_plan_cache_environment_invalidation   pass
  main.session_plan_cache_parameter_shape            pass
  main.session_plan_cache_state_machine              pass
  main.session_plan_cache_debug_fault_injection      pass

short release profile:
  oltp_point_select, 1 thread, 20s:
    Cached_plan_hits:                         1907217
    Cached_plan_profile_validate_us:            51278
    approx validate:                          0.0269 us/hit

  oltp_read_only, 1 thread, 20s:
    Cached_plan_hits:                          767440
    Cached_plan_profile_validate_us:            21470
    approx validate:                          0.0280 us/hit
```

解释：该优化只减少重复表上下文获取，不放宽 eligibility 或 invalidation 检查。
收益仍是微优化级别，但直接作用于每次 HIT 都经过的 validation path。

range quick root 优化后重新采样:

```text
HEAD: 4ec5e8cc09c
executions after warmup: 20000 each

simple range:
Cached_plan_profile_hit_range_build_us: 10020
Cached_plan_profile_hit_range_quick_select_us: 2406
Cached_plan_profile_hit_range_setup_us: 5256

sum range:
Cached_plan_profile_hit_range_build_us: 10144
Cached_plan_profile_hit_range_quick_select_us: 2353
Cached_plan_profile_hit_range_setup_us: 5733

order range:
Cached_plan_profile_hit_range_build_us: 10429
Cached_plan_profile_hit_range_quick_select_us: 2517
Cached_plan_profile_hit_range_setup_us: 5636

distinct range:
Cached_plan_profile_hit_range_build_us: 13246
Cached_plan_profile_hit_range_quick_select_us: 2664
Cached_plan_profile_hit_range_setup_us: 8334
```

对比保守基线的一轮 2 万次采样，`quick_select_us` 从约 `2922-3383 us`
降到 `2353-2664 us`，即每次 range hit 减少约 `0.03-0.04 us`。该改动还做过
20 万次 SUM range hit RSS smoke，服务端 RSS 从 `160880 KB` 到 `162192 KB`，
增量约 `1.3 MB`，未观察到随 hit 次数线性增长的 per-hit 泄漏迹象。

range select allocation 合并后重新做同机 A/B:

```text
base: 4ec5e8cc09c
candidate: 2c5ea0b7b7c
executions after warmup: 100000 each

simple range base:
Cached_plan_profile_hit_range_build_us: 56868
Cached_plan_profile_hit_range_make_select_us: 2460
Cached_plan_profile_hit_range_quick_select_us: 14505
Cached_plan_profile_hit_range_setup_us: 30037

simple range candidate:
Cached_plan_profile_hit_range_build_us: 52096
Cached_plan_profile_hit_range_make_select_us: 0
Cached_plan_profile_hit_range_quick_select_us: 14374
Cached_plan_profile_hit_range_setup_us: 30194

sum range base:
Cached_plan_profile_hit_range_build_us: 59013
Cached_plan_profile_hit_range_make_select_us: 2650
Cached_plan_profile_hit_range_quick_select_us: 13582
Cached_plan_profile_hit_range_setup_us: 33154

sum range candidate:
Cached_plan_profile_hit_range_build_us: 54726
Cached_plan_profile_hit_range_make_select_us: 0
Cached_plan_profile_hit_range_quick_select_us: 13204
Cached_plan_profile_hit_range_setup_us: 34090
```

该优化收益较小但方向稳定：direct quick 成功后不再单独构造 `SQL_SELECT`，10 万次
range hit 中 simple build 下降约 `4772 us`，SUM build 下降约 `4287 us`。
同时 `setup_alloc_us` 会小幅上升，因为 `SQL_SELECT` 被并入 setup 的
`multi_alloc_root()`。因此该提交只能视为命中路径降本的补充项，不应把它单独作为
sysbench QPS 提升的主要解释。

integer BETWEEN key store 合并后重新做 mixed `oltp_read_only` profile:

```text
HEAD: 97b50a6ca91
workload: oltp_read_only, 8 tables x 50000 rows, 1 thread, 20s

run 1:
Cached_plan_hits:                         803196
Cached_plan_profile_hit_range_count:      229464
Cached_plan_profile_hit_range_build_us:   123262
Cached_plan_profile_hit_range_quick_select_us: 25800
Cached_plan_profile_hit_range_setup_us:   81143
Cached_plan_profile_hit_unique_count:     573732
Cached_plan_profile_hit_unique_build_us:  52001
QPS:                                      45897.99

run 2:
Cached_plan_hits:                         807452
Cached_plan_profile_hit_range_count:      230680
Cached_plan_profile_hit_range_build_us:   124808
Cached_plan_profile_hit_range_quick_select_us: 25750
Cached_plan_profile_hit_range_setup_us:   82806
Cached_plan_profile_hit_unique_count:     576772
Cached_plan_profile_hit_unique_build_us:  52688
QPS:                                      46141.54
```

两轮 range build 约 `0.537-0.541 us / range hit`，相比整数 ref fast path 后
mixed read_only profile 中约 `0.587 us / range hit` 有下降。该优化只覆盖
单列、非空、整数 keypart 的 `BETWEEN ? AND ?` direct quick 路径；非整数、
NULL、类型不匹配或 store 失败仍回退到原 `store_key_item` 路径。

验证记录：

- release build: `cmake --build build_plan_cache_release --target mariadbd --parallel 8`
- release MTR: `main.session_plan_cache_sysbench_coverage`,
  `main.session_plan_cache_real_hit_boundaries`
- debug MTR: `main.session_plan_cache_debug_fault_injection`,
  `main.session_plan_cache_sysbench_coverage`,
  `main.session_plan_cache_real_hit_boundaries`,
  `main.session_plan_cache_parameter_shape`,
  `main.session_plan_cache_state_machine`
- RSS smoke: 20 万次 SUM range hit，`Cached_plan_hits=200000`，
  `Cached_plan_prevalidations=200000`，RSS 从 `160672 KB` 到 `162032 KB`，
  增量约 `1.3 MB`

unique equality hit 执行形态调整后做过真实耗时 A/B。该测试关闭
`session_plan_cache_profile`，避免 profile 自身开销影响结果；两轮均为同机临时
release server、20 万次 prepared point-select、全命中。

```text
query: SELECT c FROM t WHERE id = ?
executions after warmup: 200000

const-table shape baseline:
real 2.34s
Cached_plan_hits: 200000
Cached_plan_prevalidations: 200000
Cached_plan_invalidations: 0

ref lookup shape candidate:
real 2.08s
Cached_plan_hits: 200000
Cached_plan_prevalidations: 200000
Cached_plan_invalidations: 0
```

该改动不是简单移动 profile 计时点：旧 unique hit 在
`build_unique_eq_const_lookup_plan()` 内调用 `join_read_const_table()`，每次
hit 构建阶段都会同步读行；新路径仍按 unique recipe 识别和计数，但调用
`build_ref_eq_lookup_plan()` 构建 ref 访问形态，让普通 executor 负责读取这一行。
语义烟测覆盖了存在行、不存在行、`COUNT(*)`、`SUM()`、`ORDER BY` 的 ON/OFF 输出
一致性；release MTR 与 debug fault-injection MTR 均通过。

同一优化也用 sysbench `oltp_point_select` 做过提交前后 A/B。该 Lua 使用 prepared
statements，且 `oltp_point_select` 每个 event 执行 1 条 primary-key point select。
测试使用 release build、plan cache ON、`tables=8`、`table_size=50000`、
`rand-type=uniform`、`skip-trx=1`，每个并发档 10 秒 warmup + 30 秒测量。

| Threads | const-table shape QPS | ref lookup shape QPS | Change | Hits | Invalidations |
|---:|---:|---:|---:|---:|---:|
| 1 | 92781.43 | 94050.53 | +1.4% | 2821547 | 0 |
| 2 | 130306.10 | 139186.82 | +6.8% | 4175645 | 0 |
| 4 | 154416.96 | 160245.25 | +3.8% | 4807395 | 0 |
| 8 | 193261.61 | 198664.14 | +2.8% | 5959979 | 0 |

该 sysbench 结果说明 unique hit 执行形态调整不仅改善手写 prepared 循环，也能反映到
`oltp_point_select` 点查 QPS。短测仍不足以作为社区发布级性能结论，但足以支撑该
补丁作为命中路径降本方向继续保留。

unique-as-ref 之后重新采样 `oltp_read_only` mixed select profile，当前热点已经转移到
range hit：

```text
workload: sysbench oltp_read_only
threads: 1
duration: 30s
plan cache profile: ON

transactions: 88313
queries: 1236382
Cached_plan_hits: 1635820
Cached_plan_prevalidations: 1635820
Cached_plan_invalidations: 0

Cached_plan_profile_hit_unique_count: 1168484
Cached_plan_profile_hit_unique_build_us: 140553
Cached_plan_profile_hit_range_count: 467336
Cached_plan_profile_hit_range_build_us: 279842
Cached_plan_profile_hit_range_quick_select_us: 73793
Cached_plan_profile_hit_range_setup_us: 173112
Cached_plan_profile_hit_range_setup_alloc_us: 46150
Cached_plan_profile_hit_range_setup_post_us: 42393
Cached_plan_profile_validate_us: 51451
Cached_plan_profile_prevalidate_us: 33083
```

unique build 约 `0.12 us/hit`，range build 约 `0.60 us/hit`。继续优化时应优先看
range setup，而不是 unique/ref 小分配。

ref equality POSITION tail 裁剪后做过同机 A/B。该改动只影响当前 unique/ref hit
实际使用的 ref builder：保留 `POSITION` 数组容量，但不再 placement-new 未使用的
tail slot。

```text
workload: sysbench oltp_point_select
threads: 1
duration: 30s
plan cache profile: ON

baseline:
transactions: 2594488
queries: 2594488
Cached_plan_hits: 2594480
Cached_plan_profile_hit_unique_count: 2594480
Cached_plan_profile_hit_unique_build_us: 298698

candidate:
transactions: 2646330
queries: 2646330
Cached_plan_hits: 2646322
Cached_plan_profile_hit_unique_count: 2646322
Cached_plan_profile_hit_unique_build_us: 272275
```

折算 unique build 从约 `0.115 us/hit` 降到约 `0.103 us/hit`，点查 QPS 从
`86481.75` 到 `88209.52`，约 +2.0%。release MTR 与 debug fault-injection MTR
均通过。

ref POSITION workspace 进一步从 2 个 slot 缩到 1 个 slot 后做过同机 A/B：

```text
workload: sysbench oltp_point_select
threads: 1
duration: 30s
plan cache profile: ON

baseline after ref tail optimization:
transactions: 2618547
queries: 2618547
Cached_plan_hits: 2618539
Cached_plan_profile_hit_unique_build_us: 275646

candidate:
transactions: 2760140
queries: 2760140
Cached_plan_hits: 2760132
Cached_plan_profile_hit_unique_build_us: 284683
```

折算 unique build 从约 `0.105 us/hit` 到 `0.103 us/hit`，QPS 从 `87283.54`
到 `92003.17`。QPS 有环境波动因素，但 per-hit build 成本同向下降。release MTR
与 debug fault-injection MTR 均通过。

range POSITION tail 裁剪后做过同机 A/B。该改动只影响非 ORDER、非 DISTINCT 的
range hit；ORDER/DISTINCT 仍构造 tail POSITION slots。

```text
executions after warmup: 50000 each

simple range baseline:
Cached_plan_profile_hit_range_build_us: 21818
Cached_plan_profile_hit_range_setup_alloc_us: 3628
Cached_plan_profile_hit_range_setup_us: 12408

simple range candidate:
Cached_plan_profile_hit_range_build_us: 21779
Cached_plan_profile_hit_range_setup_alloc_us: 3287
Cached_plan_profile_hit_range_setup_us: 12449

sum range baseline:
Cached_plan_profile_hit_range_build_us: 25554
Cached_plan_profile_hit_range_setup_alloc_us: 3981
Cached_plan_profile_hit_range_setup_us: 15827

sum range candidate:
Cached_plan_profile_hit_range_build_us: 24334
Cached_plan_profile_hit_range_setup_alloc_us: 3289
Cached_plan_profile_hit_range_setup_us: 14646

order range baseline/candidate build:
23206 / 23259
```

该收益主要体现在 SUM range：build 下降约 `1220 us / 5万次`，setup allocation
下降约 `692 us / 5万次`。simple range 总 build 基本持平，但 allocation 有下降。
release MTR 与 debug fault-injection MTR 均通过。

该提交后再次采样 `oltp_read_only` mixed select profile：

```text
workload: sysbench oltp_read_only
threads: 1
duration: 30s
plan cache profile: ON

transactions: 86869
queries: 1216166
Cached_plan_hits: 1621904
Cached_plan_invalidations: 0
Cached_plan_profile_hit_unique_count: 1158544
Cached_plan_profile_hit_unique_build_us: 137423
Cached_plan_profile_hit_range_count: 463360
Cached_plan_profile_hit_range_build_us: 274821
Cached_plan_profile_hit_range_quick_select_us: 75333
Cached_plan_profile_hit_range_setup_us: 166900
Cached_plan_profile_hit_range_setup_alloc_us: 43083
Cached_plan_profile_hit_range_setup_post_us: 39803
Cached_plan_profile_validate_us: 51664
Cached_plan_profile_prevalidate_us: 33901
```

range setup allocation 从上一轮 `46150 us` 降到 `43083 us`，但 range setup 仍是
剩余最大热点。

## Short A/B Signal

关闭 plan-cache profile 后做过一组短窗口 A/B 验证，用来确认优化方向是否正确：

| Run | Mode | TPS | QPS | Hits | Invalidations |
|---|---|---:|---:|---:|---:|
| off1 | OFF | 2243.65 | 35898.47 | 0 | 0 |
| on1 | ON | 2805.31 | 44884.99 | 785507 | 0 |
| off2 | OFF | 2261.13 | 36178.14 | 785507 | 0 |
| on2 | ON | 2802.46 | 44839.32 | 1570216 | 0 |

这组数据说明当前实现已经具备方向性正收益：`oltp_read_only` 短测中 ON 相比 OFF
约有 24% 左右 QPS/TPS 提升，且 invalidation 为 0。

但这仍不是社区发布级数据。最终报告需要按 `in_memory_sysbench_harness.sh`
或 `reproducible_sysbench_harness.sh` 执行多轮、长时间、绑核、全内存测试。

## Remaining Performance Risks

### Range Setup Cost

当前 range hit 中还剩约 `0.389 us / range hit` 的 setup 成本，其中 allocation
和 post setup 是主要剩余项。

继续优化的方向可能包括：

- 更紧凑地缓存或复用 `JOIN_TAB` / `POSITION` / `JOIN_TAB_RANGE` 执行态字段；
- 减少每次命中时的 MEM_ROOT 分配和结构清零；
- 将 distinct/order 相关 setup 拆成更精确的 recipe 执行态。

这些改动风险明显高于前面几组补丁，因为它们更接近 MariaDB JOIN 执行器状态。
如果要做，应先补更强的 MTR 覆盖和结果一致性测试。

当前已排除的低收益/高风险点：

- 不建议缩小 `JOIN::map2table` 的分配或只清零当前表项。执行期存在多个按
  table_map bit 逐位访问 `map2table` 的路径；虽然当前 supported shape 是单表，
  但 `ORDER`、依赖图和 post-join setup 相关代码耦合较深。该方向收益很小，风险
  高于当前阶段可接受范围。
- 不提交 ref equality hit 中手写 `POSITION[0]` 填充替代 `set_position()` 的优化。
  该尝试避免 `set_position()` 的 best_ref 移位循环，并保留等价字段赋值；release
  MTR 通过。但 `oltp_point_select` 1 并发 30 秒 profile 中 QPS 为 `87194.33`，
  unique build 为 `273372 us / 2615865 hits`，没有超过已提交 ref POSITION tail
  裁剪后的 `88209.52` QPS 与 `272275 us / 2646322 hits`。该方向不保留。
- 不提交 key metadata / `KEY_PART` 模板缓存优化。该尝试把 `store_length`、
  `key_part_flag`、`Field*` 等参数无关字段缓存到 recipe 并传入 hit builder，
  MTR 通过，但短 profile 未显示稳定收益，unique/ref build 还略有上升。当前
  builder 中保留轻量 key metadata 校验更稳妥。
- 不提交“recipe 覆盖全部参数时跳过全量 `param_list` 遍历”的参数签名快路径。
  该尝试只影响 `validate_us`，MTR 通过，但 3 万次混合 hit profile 中
  `Cached_plan_profile_validate_us` 与基线噪声区间重叠，收益不足以支撑新增分支。
- 不提交 hit dispatch 按 `Recipe_kind` 预过滤的分支裁剪优化。该尝试让 range hit
  不再进入 unique/ref 的 allow 函数，MTR 通过，5 万次 range-only profile 多数轮次
  略好，但改善幅度约 1% 左右且与噪声区间重叠；编译器也可能已经内联了这些短函数。
- 不提交 range post setup 中“仅当 `items0` 为空时才调用 `init_items_ref_array()`”
  的重复拷贝裁剪。该尝试保持 `make_aggr_tables_info()` 的入口断言不变，release
  MTR 通过；但 2 万次 range hit profile 中 SUM/ORDER 没有改善，ORDER 总 setup
  还从 `5288 us` 升到 `5576 us`，只有 DISTINCT 略好，证据不足以支撑新增条件分支。
- 不提交 `QUICK_RANGE_SELECT::ranges` 初始容量/指针数组分配裁剪。该尝试让
  plan-cache `BETWEEN` helper 只预留 1 个 range slot，并把默认预分配类型从
  `QUICK_RANGE` 改为 `QUICK_RANGE*`；release MTR 通过，但 2 万次 range hit
  profile 没有改善，SUM/DISTINCT 还变差。该改动触及通用 range quick 构造函数，
  在没有稳定收益时不值得保留。
- 不提交移除 range builder 初始 `tab->next_select= setup_end_select_func(join)`
  的微优化。该赋值后续会在 post setup 末尾重设，看起来冗余；release MTR 通过，
  但 2 万次 range hit profile 中 simple/ORDER 基本落在噪声内，SUM/DISTINCT 反而
  变差，说明该行不是当前稳定收益点。
- 不提交 simple range hit 跳过 `test_if_need_tmp_table()` 的微优化。该尝试仅在
  `needs_post_access_setup=false` 时直接设置 `join->need_tmp=false`；release MTR
  通过，但 10 万次 simple range A/B 基本持平：range build `44477 us` 到
  `44390 us`，setup `25313 us` 到 `25430 us`，post `2381 us` 到 `2407 us`。
  该分支不是真正热点。
- 不提交 plan-cache range quick 跳过 `QUICK_RANGE_SELECT::column_bitmap` 分配的优化。
  代码检查显示该 bitmap 主要被 ROR merged scan 使用，普通 `BETWEEN` quick 不走
  该路径；实验中给构造函数增加默认参数，仅 `get_quick_select_for_between()` 跳过
  bitmap 分配，release MTR 通过。但 5 万次 range shape 同机 A/B 没有稳定收益：
  simple build `22261 us` 到 `22549 us`，order build `23040 us` 到 `25159 us`；
  SUM/DISTINCT 的 quick_select 有小幅波动但不足以抵消整体噪声。该方向不保留。
- 不提交 simple/SUM range 进一步缩小 `POSITION` 分配容量的优化。已提交版本只是
  跳过未使用 tail slot 的构造；进一步把 `positions/sort_positions/best_positions`
  从 2 个 slot 缩到 1 个 slot，release MTR 通过，但 5 万次 range shape profile
  没有比已提交版本更稳定：simple build `21256 us`，SUM build `24790 us`，ORDER
  和 DISTINCT 波动更大。考虑到 `JOIN::sort_space=2` 和 `next_sort_position`
  周边代码存在容量假设，该方向不保留。
- 不提交 `get_quick_select_for_between()` 中仅当 handler 非 `NONE` 时才调用
  `quick->init()` 的微优化。该尝试保持 handler 已初始化时的安全路径，release MTR
  通过；但单形态 15 秒 profile 只有 simple/SUM 的 quick_select 有小幅下降，
  ORDER/DISTINCT 不稳定。mixed `oltp_read_only` 30 秒 profile 中 range build
  约 `201736 us / 343592 hits`，折合 `0.587 us/hit`，相比上一轮约 `0.593 us/hit`
  只有约 1% 差异，QPS 还从约 `40538` 波动到 `40088`。收益不足以形成可信提交。
- 不提交非 DISTINCT range hit 延迟构造 `Plan_cache_join_restore` 的优化。该对象
  只在 DISTINCT 异常回退路径显式调用 `restore()`，看起来 simple/SUM/ORDER 可以
  避免保存 JOIN 字段；实验中 release 编译通过，simple range 的 `setup_base`
  有小幅下降，但总 build 与整数 key fast path 基本持平，SUM/ORDER 的改善主要来自
  已提交的整数 key fast path。该方案需要 placement-new/对齐局部存储，复杂度高于
  当前可证明收益，因此不保留。
- 不提交 range hit 中手写 `POSITION[0]` 填充替代 `set_position()` 的优化。range
  专用路径中 `best_ref[0]` 已经是当前表，理论上可以跳过 `set_position()` 的移动
  循环；实验中 release 编译通过，但 simple range profile 为
  `169775 us / 358898 hits`，约 `0.473 us/hit`，没有超过整数 key fast path
  已提交版本的约 `0.466 us/hit`，`setup_post` 也没有改善。该方向不保留。
- 不提交 ref/unique hit 中把 `JOIN_TAB_RANGE` 并入已有 `multi_alloc_root()` 的优化。
  range hit 已经从类似裁剪中受益，因此尝试把 `build_ref_eq_lookup_plan()` 里后续
  单独 `new (mem_root) JOIN_TAB_RANGE` 合并到前面的分配列表。debug build、release
  build 和 `session_plan_cache_unique_eq_real_hit`、`session_plan_cache_sysbench_coverage`、
  `session_plan_cache_state_machine`、`session_plan_cache_debug_fault_injection` 均通过；
  但两轮 `oltp_point_select` 20 秒 profile 没有稳定收益：unique build 分别约
  `181000 us / 1913681 hits` 和 `183437 us / 1899506 hits`，折合约
  `0.095-0.097 us/hit`，与已有轻量 explain 后的基线噪声重叠，QPS 也未改善。
  该分配不是当前点查热点。
- 不提交 light hit explain 中把 `Explain_select` 与 `Explain_table_access` 合并到
  一次 `multi_alloc_root()` 的优化。该尝试只影响 `JOIN::build_plan_cache_hit_explain()`
  的已收窄轻量路径，debug build 和 `session_plan_cache_explain_analyze_boundary`、
  `session_plan_cache_sysbench_coverage`、`session_plan_cache_unique_eq_real_hit`、
  `session_plan_cache_state_machine` 均通过；但 release `oltp_point_select`
  20 秒串行 profile 中 `Cached_plan_profile_hit_explain_us` 为
  `100132 us / 1906523 hits`，约 `0.0525 us/hit`，没有超过整数 ref fast path
  后约 `0.049-0.050 us/hit` 的基线。该合并分配收益不稳定，保留原代码更利于
  review。
- 不提交 direct range quick 返回后跳过 quick 形态校验的优化。`get_quick_select_for_between()`
  构造的对象理论上已固定为 `QS_TYPE_RANGE`、同一 key、单 keypart；实验中 release
  编译通过，但 simple range 约 `163530 us / 342837 hits`，mixed `oltp_read_only`
  range build 约 `192336 us / 352652 hits`，没有超过已提交清零裁剪版本的信号。
  该校验成本太小，保留防御性检查更稳妥。
- 不提交 plan-cache `BETWEEN` direct quick 中把 `QUICK_RANGE`、min key、max key
  合并到一次 `multi_alloc_root()` 的优化。该尝试只替换
  `get_quick_select_for_between()` 中 `QUICK_RANGE` 构造，避免通用构造函数里的两次
  `memdup()`；debug/release build 通过，`session_plan_cache_sysbench_coverage`、
  `session_plan_cache_real_hit_boundaries`、`session_plan_cache_parameter_shape`、
  `session_plan_cache_state_machine`、`session_plan_cache_debug_fault_injection` 均通过。
  但两轮 release `oltp_read_only` profile 没有超过 `97b50a6ca91` 的基线：
  range build 分别约 `120049 us / 221460 hits` 与
  `123119 us / 223800 hits`，折合约 `0.542` 和 `0.550 us/hit`；
  基线约 `0.537-0.541 us/hit`。该分配折叠没有稳定收益，保留通用
  `QUICK_RANGE` 构造路径更稳妥。
- 不提交 exact DISTINCT range 中手工设置 `TMP_TABLE_PARAM` 以跳过
  `count_field_types()` 的优化。该尝试基于单字段 FIELD 形态，把
  `field_count=1`、`sum_func_count=0`、`func_count=0`、`hidden_field_count=0`、
  `quick_group=1` 写入临时参数；debug/release build 和 focused MTR 均通过。但
  DISTINCT-only release profile 没有超过 `8d6e7e9cda6`：两轮累计约
  `20753 us / 358659 hits`，`setup_distinct ~= 0.058 us/hit`，而已提交的单字段
  group 快路径约 `0.053-0.054 us/hit`。该方向不保留。
- 不提交“整数 ref 命中直接写 key buffer 并跳过 `build_explain()`”的优化。采样显示
  `oltp_point_select` 8 并发 ON case 中 `build_ref_eq_lookup_plan()` 下仍有
  `store_key_item` / `Field::new_key_field()` / `build_explain()` 成本，因此尝试
  为单列整数 ref lookup 增加专用 `read_first_record`，并在 plan cache HIT 后跳过
  普通 SELECT 的 `build_explain()`。该方向被 MTR 证伪：如果清空 `ref.key_copy`，
  `JOIN_TAB::save_explain_data()` 会崩溃；如果跳过 `build_explain()`，普通执行
  会在 `JOIN::exec()` 崩溃，说明当前 MariaDB 执行路径仍依赖 `build_explain()`
  同步部分执行态。该方向若要继续，只能设计“保留执行态初始化、裁剪 explain 数据
  生成”的更细粒度接口，不能用简单跳过方式。
- 不提交“plan cache HIT 创建最小 `Explain_select`、跳过 table explain 填充”的
  优化。该尝试保留 `JOIN::exec()` 需要的 `explain->time_tracker`，仅对普通
  SELECT、非 ANALYZE/EXPLAIN、非 slow-log explain/engine、无 `aggr_tables`、
  无 inner unit 的命中路径创建最小 explain 节点。release/debug 编译通过，
  `session_plan_cache_explain_analyze_boundary` 通过，但
  `session_plan_cache_sysbench_coverage` 在第二次点查执行时于 `sub_select()` 崩溃。
  这说明 `JOIN_TAB::save_explain_data()` 还会初始化执行期需要的 table/join
  tracker 指针；`build_explain()` 在当前 MariaDB 中同时承担 explain 数据生成和
  执行态 tracker 初始化职责。后续若继续优化，必须先把这些职责拆开，而不是构造
  不完整 explain 节点。

当前已提交的低风险 range 构造优化：

- 提交 `1a5a8ca6560` 删除 plan-cache range hit 中 `best_ref[2]` 与
  `table_vector[2]` 的冗余清零。两个数组后续会完整写入 `[0]` 和 `[1]`，而
  `map2table` 仍保留全量清零以避免 table_map 访问风险。release/debug MTR 均通过。
  mixed `oltp_read_only` 30 秒 profile 中，`setup_alloc` 从约 `32094 us` 到
  `30870 us`，range build 从约 `0.568 us/hit` 到 `0.556 us/hit`；simple range
  单形态未稳定体现，因此该提交只作为确定冗余清零裁剪，不作为独立 QPS 证明。
- 提交 `742ec75dbf0` 将 plan-cache range hit 的 `JOIN_TAB_RANGE` 并入已有
  `multi_alloc_root()` 分配列表，去掉每次命中后续单独 `new (mem_root)`。release/debug
  MTR 均通过。mixed `oltp_read_only` 30 秒 profile 中，range build 为
  `190785 us / 353828 hits`，约 `0.539 us/hit`，相比同轮当前 HEAD profile 的
  `191427 us / 336752 hits`，约 `0.568 us/hit` 有正向信号；simple range 单形态
  未稳定改善，因此该提交只应视为低风险分配裁剪，不作为独立 QPS 证明。
- 提交 `a5c9daa533d` 为 plan-cache `BETWEEN` direct quick 增加整数 key fast path。
  对单列非 NULL 整数 keypart，直接使用 `Item_param::const_ptr_longlong()` 和
  `Field::store()` 生成 range key buffer，避免每次命中构造临时 key `Field`；
  非整数或失败场景仍回退原 `store_key_item` 路径。release/debug MTR 均通过。
  simple range A/B 中，range build 从 `184963 us / 359685 hits`
  降到 `162799 us / 349717 hits`，约 `0.514 us/hit` 到 `0.466 us/hit`；
  其中 `quick_select` 从约 `0.152 us/hit` 降到 `0.099 us/hit`。该优化降低
  range hit 构造 CPU 成本，但单机 sysbench QPS 仍被噪声覆盖，不能单独作为
  社区性能证明。

当前 HEAD 重新用 sysbench 参数隔离 range 形态，profile 计数按相邻 case 差值计算：

| Shape | Hits | Build us/hit | Setup us/hit | Quick us/hit | Explain us/hit | Notes |
|---|---:|---:|---:|---:|---:|---|
| simple range | 283749 | 0.477 | 0.295 | 0.108 | 0.065 | 已多轮优化，post setup 已低 |
| SUM range | 629697 | 0.434 | 0.291 | 0.073 | 0.056 | 专用 SUM setup 已生效 |
| ORDER range | 148578 | 0.492 | 0.316 | 0.102 | 0.169 | 受 filesort/explain tracker 边界限制 |
| DISTINCT range | 140431 | 0.677 | 0.501 | 0.102 | 0.175 | 当前最重，但触及 distinct/tmp/aggr setup |

结论：继续优化 simple/SUM 的低风险空间已经很小；ORDER/DISTINCT 的剩余成本更高，
但与 filesort tracker、temporary table metadata、`make_aggr_tables_info()` 和
完整 `build_explain()` 绑定更深。下一轮若继续做代码优化，应优先调研 DISTINCT
range 是否能安全缓存或专用化 metadata；否则应冻结性能代码，转入稳定 benchmark
和社区材料整理。

`8d6e7e9cda6` 先落地其中较窄的一步：对 exact sysbench
`SELECT DISTINCT c FROM t WHERE id BETWEEN ? AND ? ORDER BY c` 形态，直接复制
单个 `ORDER` 节点作为 group，避免每次 HIT 进入通用 `create_distinct_group()`
扫描字段列表、遍历 ORDER 列表和处理非当前边界的隐藏字段场景。若不是单字段、
ORDER 不在 select list、字段不等价或分配失败，仍回退原通用路径。

```text
MTR:
  main.session_plan_cache_sysbench_coverage       pass
  main.session_plan_cache_debug_fault_injection   pass
  main.session_plan_cache_real_hit_boundaries     pass
  main.session_plan_cache_explain_analyze_boundary pass
  main.session_plan_cache_parameter_shape         pass

release profile, DISTINCT range only, 1 thread:
  run 1:
    Cached_plan_profile_hit_range_count:          180718
    Cached_plan_profile_hit_range_setup_us:        86870
    Cached_plan_profile_hit_range_setup_distinct_us: 9793
    approx setup:                                0.481 us/hit
    approx distinct setup:                       0.054 us/hit

  run 2 cumulative delta:
    Cached_plan_profile_hit_range_count:          177953
    Cached_plan_profile_hit_range_setup_us:        85319
    Cached_plan_profile_hit_range_setup_distinct_us: 9475
    approx setup:                                0.479 us/hit
    approx distinct setup:                       0.053 us/hit
```

对比上一轮 shape profile 中 DISTINCT range `setup ~= 0.501 us/hit`、
`setup_distinct ~= 0.069 us/hit`，该改动只带来小幅下降。它不是完整 DISTINCT
post setup 专用化，后续若继续优化还需要处理 `make_aggr_tables_info()` 的通用
post setup 和 full `build_explain()` tracker 初始化成本。

### Current HEAD ON/OFF Sanity Check

在当前 HEAD 上使用 release `mariadbd`、同一个临时 datadir、数据导入一次、10GB
buffer pool、`oltp_read_only`、1 并发、60 秒做开发机 sanity check：

- plan cache OFF：`141267` transactions，QPS `32962.01`，TPS `2354.43`；
- plan cache ON：`175345` transactions，QPS `40913.29`，TPS `2922.38`；
- ON 相比 OFF：QPS/TPS 提升约 `24.1%`；
- ON 命中 counters：`Cached_plan_hits=2454790`，`Cached_plan_invalidations=0`；
- ON profile：unique `186648 us / 1753442 hits`，range
  `386015 us / 701348 hits`。

这说明当前实现已经能在 sysbench `oltp_read_only` 混合 SELECT 模型中体现明确
收益，且命中有效、没有异常 invalidation。该结果仍是 macOS 同机单轮 sanity check，
不能替代最终社区材料所需的 Linux 绑核、多并发、多轮 median/p25/p75 报告。

同样方式对 `oltp_read_only` 做 2 并发 60 秒 sanity check：

- plan cache OFF：`258926` transactions，QPS `60415.36`，TPS `4315.38`；
- plan cache ON：`311436` transactions，QPS `72667.49`，TPS `5190.54`；
- ON 相比 OFF：QPS/TPS 提升约 `20.3%`；
- ON 命中 counters：`Cached_plan_hits=4360024`，`Cached_plan_invalidations=0`；
- ON profile：unique `409598 us / 3114344 hits`，range
  `778256 us / 1245680 hits`。

2 并发结果与 1 并发方向一致，但提升幅度略低；需要在 Linux 绑核环境下继续覆盖
4/8/16 并发并做多轮统计，确认 CPU 未打满前的可复现性。

同样方式对 `oltp_read_only` 做 4 并发 60 秒 sanity check：

- plan cache OFF：`361152` transactions，QPS `84267.38`，TPS `6019.10`；
- plan cache ON：`376602` transactions，QPS `87872.04`，TPS `6276.57`；
- ON 相比 OFF：QPS/TPS 提升约 `4.3%`；
- ON 命中 counters：`Cached_plan_hits=5272268`，`Cached_plan_invalidations=0`；
- ON profile：unique `725033 us / 3765988 hits`，range
  `1345972 us / 1506280 hits`。

4 并发仍保持正向，但收益明显收窄，说明本机同进程部署可能已经受到 sysbench 客户端、
socket、handler 读取、调度或其他共享资源影响。正式性能报告必须同时记录 CPU 利用率、
绑核方式和多轮分位数，否则难以说明“CPU 未打满前提升一致”。

同样方式对 `oltp_read_only` 做 8 并发 60 秒 sanity check：

- plan cache OFF：`533621` transactions，QPS `124508.70`，TPS `8893.48`；
- plan cache ON：`442695` transactions，QPS `103291.81`，TPS `7377.99`；
- ON 相比 OFF：QPS/TPS 下降约 `17.0%`；
- ON 命中 counters：`Cached_plan_hits=6197410`，`Cached_plan_invalidations=0`；
- ON profile：unique `1455505 us / 4426886 hits`，range
  `2583171 us / 1770524 hits`；
- sysbench thread fairness 从 OFF `66702.6250/84.15` 变为 ON
  `55336.8750/3243.37`。

8 并发出现反转，且线程公平性波动明显。这更像本机同机部署下的调度、socket、
handler/共享资源竞争或 CPU 频率影响，而不是 plan cache 命中失效；ON case 仍然
全命中且 invalidation 为 0。该结果说明当前 macOS 单机测试在 8 并发已经不能作为
社区性能结论，后续必须转 Linux 绑核并采集 CPU 利用率、上下文切换、锁等待和多轮
分位数。

为排除 profile instrumentation 开销，关闭 `session-plan-cache-profile` 后重跑
8 并发 `oltp_read_only`：

- plan cache OFF：`531323` transactions，QPS `123972.67`，TPS `8855.19`；
- plan cache ON：`464867` transactions，QPS `108465.42`，TPS `7747.53`；
- ON 相比 OFF：QPS/TPS 下降约 `12.5%`；
- ON 命中 counters：`Cached_plan_hits=6507818`，`Cached_plan_invalidations=0`。

关闭 profile 后仍然反转，说明 profile 计时不是 8 并发下降的主因。后续若继续定位
8 并发，应优先观察 sysbench/mariadbd 绑核、CPU 利用率、上下文切换、锁等待，以及
plan cache 命中路径是否引入了高并发下的共享资源竞争。

同样方式对 `oltp_point_select` 做 1 并发 60 秒 sanity check：

- plan cache OFF：`5250687` transactions，QPS/TPS `87510.83`；
- plan cache ON：`5611648` transactions，QPS/TPS `93526.74`；
- ON 相比 OFF：QPS/TPS 提升约 `6.9%`；
- ON 命中 counters：`Cached_plan_hits=5611640`，`Cached_plan_invalidations=0`；
- ON profile：unique `562741 us / 5611640 hits`。

点查单条 SQL 极短，结果更容易受客户端调度、socket 和 CPU 频率影响；该结果仅说明
当前 HEAD 在点查 sanity check 中方向正确，最终社区数据仍应以多轮统计为准。

关闭 profile 后对 `oltp_point_select` 做 8 并发 60 秒 sanity check：

- plan cache OFF：`11809142` transactions，QPS/TPS `196816.98`；
- plan cache ON：`9287947` transactions，QPS/TPS `154796.95`；
- ON 相比 OFF：QPS/TPS 下降约 `21.4%`；
- ON 命中 counters：`Cached_plan_hits=9287883`，`Cached_plan_invalidations=0`。

点查 8 并发也出现反转，说明问题不只是 `read_only` 的 range builder；高并发下
通用命中路径、prepared-statement 执行路径或本机共享资源竞争都需要纳入后续定位。
因此，8 并发及以上的 macOS 同机数据只能用于发现风险，不能作为社区收益证明。

对同一场景做 `sample` 对比时，现象仍可复现但幅度较小：

- plan cache OFF：`11733295` transactions，QPS/TPS `195553.00`；
- plan cache ON：`10684845` transactions，QPS/TPS `178078.51`；
- ON 相比 OFF：QPS/TPS 下降约 `8.9%`；
- ON 命中 counters：`Cached_plan_hits=12194022`，`Cached_plan_invalidations=0`。

采样中的关键差异是：ON 命中路径仍在 `JOIN::prepare()`、`JOIN::optimize()`、
`JOIN::build_explain()`、`plan_cache::try_execute_cached_recipe()` 和
`plan_cache::build_ref_eq_lookup_plan()` 中消耗 CPU；其中 ref builder 还会构造
`store_key_item` 并触发 `Field::new_key_field()`。这说明点查 8 并发劣化并不是
命中失效，而是命中路径仍保留了若干每次执行的 JOIN/Explain/ref setup 成本。
简单跳过这些步骤已经被 MTR 证伪，后续若继续优化，需要先拆分 MariaDB 当前
`build_explain()` 中“执行态初始化”和“Explain 数据生成”的职责。

### Direct Range Quick Boundary

当前 direct quick 路径是保守启用的，只覆盖窄场景：

- 单表；
- 单列 keypart；
- 非 nullable；
- 升序 key；
- `BETWEEN ? AND ?` 形态；
- 不满足条件时回退正常 `test_quick_select()`。

这能覆盖 sysbench 中关键 range 模板，但不是完整 range optimizer cache。多列索引、
nullable keypart、DESC key、复杂 range merge 等场景仍应保持 fail-closed。

### Point Select Scaling

点查场景的单次查询非常短，QPS 受 sysbench 客户端调度、socket/protocol、handler
读取、CPU 频率和核调度影响很大。即使 plan cache 减少了优化器成本，closed-loop
QPS 也可能不线性。

因此点查不应单独作为社区价值证明。更合适的主证明是 `oltp_read_only`，因为它
覆盖 point/ref/range/sum/order/distinct SELECT 混合模板，更接近 plan cache 的
收益模型。

## Answer To The Current Question

实现曾经有性能问题：缓存执行计划命中后仍做了过多 range 构造和验证工作，尤其
是 range hit 仍调用 `test_quick_select()`。这会导致“命中率很高但性能不升反降”。

当前这部分主要问题已经修掉，短测显示 `oltp_read_only` 已有明确正收益。剩余问题
不是 plan cache 设计无效，而是命中路径还有执行态 setup 成本。后续是否继续优化
取决于正式长测结果：如果全内存、绑核、多轮测试中仍无法稳定体现收益，再进入
JOIN/range setup 复用这类高风险优化；否则建议先冻结性能代码，转入稳定性验证和
社区材料整理。

### ORDER Range Light Explain

`0ab385432c9` 将 light explain 的覆盖面扩展到窄的单表 ORDER range hit。该路径
仍对 `ANALYZE`、`EXPLAIN`、slow-log explain/engine、temporary table、
GROUP/DISTINCT、subquery、derived、pushdown 和非单表形态回退完整
`build_explain()`；唯一新增的是在已有 `join_tab->filesort` 的 ORDER range 上创建
`Explain_table_access::pre_join_sort`，从而保留 `Filesort::tracker` 初始化。

验证：

- debug build: `cmake --build build_plan_cache_debug --target mariadbd`
- release build: `cmake --build build_plan_cache_release --target mariadbd`
- MTR:
  - `main.session_plan_cache_sysbench_coverage`
  - `main.session_plan_cache_explain_analyze_boundary`
  - `main.session_plan_cache_debug_fault_injection`
  - `main.session_plan_cache_real_hit_boundaries`
  - `main.session_plan_cache_parameter_shape`

短窗口 release ORDER-only profile：

```text
workload: sysbench oltp_read_only
shape: --point-selects=0 --simple-ranges=0 --sum-ranges=0 --order-ranges=1 --distinct-ranges=0
threads: 1
duration: 5s
session_plan_cache_profile=ON

transactions: 64797
queries: 64797
Cached_plan_hits: 64795
Cached_plan_invalidations: 0
Cached_plan_profile_hit_range_count: 64795
Cached_plan_profile_hit_explain_us: 5108
Cached_plan_profile_hit_range_build_us: 31761
Cached_plan_profile_hit_range_setup_us: 20393
```

折算 explain 成本约 `0.079 us / range hit`。此前 ORDER range shape profile 中
explain 成本约 `0.169 us / hit`，说明该窄化 light explain 对 ORDER range 命中路径
有明确降本。该优化不扩展到 DISTINCT；DISTINCT 仍保守使用完整 explain 初始化。

### Exact DISTINCT Range Tab Capacity

`e6ffa420131` 对 exact sysbench DISTINCT range shape
(`SELECT DISTINCT c ... WHERE id BETWEEN ? AND ? ORDER BY c`) 缩小 range hit
工作区：该形态只在 access tab 上构造 group/filesort 状态，不需要为通用 DISTINCT
预留额外 post-join `JOIN_TAB`。补丁只在单字段、单 ORDER、无 aggregate/GROUP/window/
rollup、SELECT list 与 ORDER field 完全一致时把 `JOIN_TAB` 容量从 3 收到 1；其他
DISTINCT 形态继续保留原容量并走原 fail-closed 路径。

验证：

- debug build: `cmake --build build_plan_cache_debug --target mariadbd`
- release build: `cmake --build build_plan_cache_release --target mariadbd`
- MTR:
  - `main.session_plan_cache_sysbench_coverage`
  - `main.session_plan_cache_debug_fault_injection`
  - `main.session_plan_cache_real_hit_boundaries`
  - `main.session_plan_cache_parameter_shape`
  - `main.session_plan_cache_explain_analyze_boundary`

短窗口 release DISTINCT-only profile：

```text
shape: --point-selects=0 --simple-ranges=0 --sum-ranges=0 --order-ranges=0 --distinct-ranges=1
threads: 1
duration: 12s
session_plan_cache_profile=ON

run 1:
  qps: 11891.67
  Cached_plan_hits: 142701
  Cached_plan_invalidations: 0
  Cached_plan_profile_hit_range_build_us: 92177
  Cached_plan_profile_hit_range_setup_alloc_us: 14273
  Cached_plan_profile_hit_range_setup_us: 65690
  Cached_plan_profile_hit_explain_us: 26160

run 2:
  qps: 11848.75
  Cached_plan_hits: 142186
  Cached_plan_invalidations: 0
  Cached_plan_profile_hit_range_build_us: 91342
  Cached_plan_profile_hit_range_setup_alloc_us: 14105
  Cached_plan_profile_hit_range_setup_us: 64895
  Cached_plan_profile_hit_explain_us: 26111
```

折算后，DISTINCT range build 约 `0.642-0.646 us / hit`，setup allocation 约
`0.099-0.100 us / hit`。同轮基线 shape profile 中 DISTINCT build 约
`0.665 us / hit`、setup allocation 约 `0.137 us / hit`，说明该改动主要降低了
DISTINCT 命中路径的临时工作区构造成本。

`f67b193703a` 补充了该优化的安全边界：如果表引擎提供
`handlerton::create_group_by`，exact DISTINCT range 不再使用 1-tab 工作区，而是保留
通用 DISTINCT 容量，避免绕过 storage-engine group-by handler 后又在不足容量上执行
通用聚合 setup。

曾尝试为 exact DISTINCT range 增加专用 post setup helper，以绕过
`make_aggr_tables_info()` 的通用分支。该方向在短窗口 profile 中只把 setup 成本从约
`0.456-0.460 us / hit` 降到约 `0.447-0.450 us / hit`，build 成本基本不变；同时它需要
复制 `make_aggr_tables_info()` 中 group fields、items ref array、filesort、storage
engine group-by handler 等 JOIN 状态语义。收益不足以覆盖语义风险，已放弃，不建议作为
当前社区准备阶段的交付主线。

### Current HEAD Remaining Hotspot Check

`ae7c726320b` 后使用 release build 做了一个短 prepared-loop profile smoke，每个
case 2000 次 execute，用于判断是否还有值得立刻实现的低风险优化点。该 smoke 不是
社区性能结论，只用于定位。

变更前 profile 摘要：

```text
point:    hits=1999, hit_build=207 us, hit_explain=128 us,
          validate=68 us, prevalidate=41 us
ref:      hits=1999, hit_build=182 us, hit_explain=106 us,
          validate=68 us, prevalidate=28 us
range:    hits=1999, range_build=705 us, quick=143 us,
          setup_alloc=124 us, setup=458 us
sumrange: hits=1999, range_build=930 us, quick=210 us,
          setup_alloc=147 us, setup=588 us
```

结论：

- point/ref builder 已经约 `0.09-0.10 us / hit`，继续拆 `map2table`、`set_position()`
  或 key copier 的收益很小，且历史短测已经显示这类微优化容易被噪声覆盖。
- light explain 仍约 `0.05-0.06 us / hit`，但之前“跳过 explain/minimal explain”
  已被 MTR 崩溃证伪；继续优化需要重构 tracker 初始化语义，不适合作为小补丁。
- range/SUM range 仍是主要剩余 setup 成本，但 broad range optimizer cache、
  复用 `QUICK_RANGE_SELECT` 或复用 SUM aggregator 都属于高风险方向。

`dcdb980f5e9` 只做了一个窄的机械收缩：simple/SUM range 已经不构造 tail
`POSITION`，但 allocation 仍按两个 `POSITION` 槽位分配。该提交把无 ORDER/DISTINCT
range 的 `positions`、`sort_positions`、`best_positions` 容量同步收缩为 1，并把
`join->sort_space` 设为同一容量；ORDER/DISTINCT 仍保留 2 个槽位。

验证：

- debug build: `cmake --build build_plan_cache_debug --target mariadbd`
- release build: `cmake --build build_plan_cache_release --target mariadbd`
- MTR:
  - `main.session_plan_cache_sysbench_coverage`
  - `main.session_plan_cache_real_hit_boundaries`
  - `main.session_plan_cache_debug_fault_injection`

变更后同一短 profile：

```text
range:    hits=1999, range_build=726 us, quick=152 us,
          setup_alloc=126 us, setup=449 us
sumrange: hits=1999, range_build=940 us, quick=196 us,
          setup_alloc=127 us, setup=575 us
```

该优化主要是减少无 ORDER/DISTINCT range 的内存工作区；simple range 的收益被短测噪声
覆盖，SUM range 的 setup allocation 从 `147 us / 1999 hits` 降到
`127 us / 1999 hits`。它不应作为主要性能卖点，只作为低风险收敛项保留。

独立只读 review 未发现当前越界或语义问题：simple/SUM range 命中路径只写入和读取
`POSITION[0]`，ORDER/DISTINCT 仍因 `construct_position_tail=true` 保留 2 个槽位。
剩余约束是未来漂移：如果后续放宽 SUM 支持，或让
`setup_plan_cache_sum_range_aggr_tables_info()` 对仍使用 1 槽 POSITION 的 shape 回退到
通用 `make_aggr_tables_info()`，必须重新审计通用聚合、filesort、`save_query_plan()`
等路径是否仍假设 `table_count + 1` 个 POSITION 槽位。

### Read-Only Template Split

2026-06-26 使用 current HEAD `8a943d68e61` release build 做了一轮
`oltp_read_only` 模板拆分诊断。该测试复用一次 sysbench prepare 数据，只改变
`oltp_read_only.lua` 的各类 SELECT 数量，用于判断收益来源；它不是正式社区性能
结论。

环境摘要：

```text
output: /tmp/plan-cache-template-diagnostic-20260626-171824
build: build_plan_cache_release
CMAKE_BUILD_TYPE: Release
WITH_ASAN: OFF
tables: 32
table_size: 20000
buffer_pool: 4G
measure: 20s per case
prepared statements: --db-ps-mode=auto
query cache: OFF
```

结果：

| Shape | Threads | OFF QPS | ON QPS | Change | ON hit delta | Invalidations |
|---|---:|---:|---:|---:|---:|---:|
| point | 1 | 80245.78 | 97732.22 | +21.79% | 1954675 | 0 |
| point | 4 | 156340.51 | 150858.65 | -3.51% | 3017277 | 0 |
| simple range | 1 | 21200.24 | 23839.13 | +12.45% | 476766 | 0 |
| simple range | 4 | 61841.78 | 61005.55 | -1.35% | 1220055 | 0 |
| sum range | 1 | 41939.97 | 44931.24 | +7.13% | 898624 | 0 |
| sum range | 4 | 87005.68 | 93879.26 | +7.90% | 1877561 | 0 |
| order range | 1 | 12234.22 | 13260.37 | +8.39% | 265184 | 0 |
| order range | 4 | 27005.24 | 27900.47 | +3.32% | 557915 | 0 |
| distinct range | 1 | 6533.36 | 11814.18 | +80.83% | 236260 | 0 |
| distinct range | 4 | 17279.16 | 25363.41 | +46.79% | 507177 | 0 |

该拆分说明 `oltp_read_only` 的主要收益来自 range 类模板，尤其是 DISTINCT range；
SUM range 和 ORDER range 也有稳定正收益。point/simple range 在 4 并发的一次短窗口
结果看起来略负，需要复测确认。

随后只复测 point 和 simple range 的 4 并发，ON/OFF 交替三轮，每轮 30 秒，并记录
`mariadbd` CPU：

```text
output: /tmp/plan-cache-point-simple-repeat-20260626-172824
tables: 32
table_size: 20000
buffer_pool: 4G
threads: 4
measure: 30s per case
```

三轮均值：

| Shape | Mode | Avg QPS | QPS stdev | Avg server CPU |
|---|---|---:|---:|---:|
| point | OFF | 123819.35 | 16994.45 | 237.40% |
| point | ON | 124133.23 | 14247.32 | 227.62% |
| simple range | OFF | 42712.76 | 1058.66 | 265.02% |
| simple range | ON | 43892.74 | 1294.02 | 257.08% |

复测结论：

- point 4 并发均值为 `+0.25%`，不能证明存在稳定劣化。
- simple range 4 并发均值为 `+2.76%`，第一次短测中的负值更像本机短窗口波动。
- 两个 ON case 的 server CPU 均值都低于 OFF，说明当前没有证据表明 plan cache HIT
  在这两个模板上引入了额外 CPU 瓶颈。
- 后续性能主线不应再优先投入 point/ref 微优化；更有价值的是把 read-only mixed
  workload 的稳定正收益做成可复现社区 benchmark。

2026-06-26 在提交 `f0cae999261` 后，又使用已提交的
`in_memory_sysbench_harness.sh` 重跑了一轮模板级矩阵。该版本的 harness 会在
sysbench 运行期间采样 `Cached_plan_count`，因此可以证明 ON case 不只是结束后
counter 增长，而是在运行期间确实存在 live cached statement。

环境摘要：

```text
output: /tmp/plan-cache-shape-matrix-20260626-180554
HEAD: f0cae999261c6c606d361c04a8f7ecf65fe6ac14
build: build_plan_cache_release
CMAKE_BUILD_TYPE: Release
WITH_ASAN: OFF
sysbench: 1.0.20
tables: 32
table_size: 20000
buffer_pool: 4G
workload: oltp_read_only
shapes: point simple_range sum_range order_range distinct_range
threads: 1, 4
measure: 20s per case
repeats: 1
CPU set isolation: not available on this macOS host
```

结果摘要：

| Shape | Threads | OFF QPS | ON QPS | Change | ON hit delta | ON live count max | Invalidations | CPU/kQPS change |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| point | 1 | 83840.09 | 91831.80 | +9.53% | 1836665 | 32 | 0 | -38.57% |
| point | 4 | 153687.72 | 152818.06 | -0.57% | 3056399 | 128 | 0 | +1.67% |
| simple range | 1 | 21029.95 | 23178.91 | +10.22% | 463561 | 32 | 0 | -21.19% |
| simple range | 4 | 61548.25 | 63568.20 | +3.28% | 1271302 | 128 | 0 | -3.16% |
| sum range | 1 | 40823.75 | 47060.77 | +15.28% | 941217 | 32 | 0 | -21.36% |
| sum range | 4 | 101138.35 | 91120.56 | -9.91% | 1822380 | 128 | 0 | -6.36% |
| order range | 1 | 12012.53 | 12487.43 | +3.95% | 249725 | 32 | 0 | -11.56% |
| order range | 4 | 29268.68 | 29796.35 | +1.80% | 595830 | 128 | 0 | +0.05% |
| distinct range | 1 | 6543.74 | 11839.37 | +80.93% | 236763 | 32 | 0 | -53.33% |
| distinct range | 4 | 17763.14 | 28381.18 | +59.78% | 567535 | 128 | 0 | -41.17% |

这轮结果强化了两个判断：

- plan cache 在所有 ON case 中确实生效：`Cached_plan_hits` 增长、运行中
  `Cached_plan_count` 非 0，且 `Cached_plan_invalidations=0`。
- 最适合作为社区性能收益主场景的是 range 类 SELECT，尤其 DISTINCT range；
  point 4 并发接近持平，不能作为主卖点。

`sum_range` 4 并发在该单轮矩阵中 QPS 为负，但 CPU/kQPS 仍改善。随后对同一形态
做三轮复测：

```text
output: /tmp/plan-cache-sumrange-repeat-20260626-181349
shape: sum_range
threads: 4
measure: 20s per case
repeats: 3
```

复测 median 结果：

| Shape | Threads | OFF median QPS | ON median QPS | Change | OFF CV | ON CV | CPU/kQPS change | ON hit median | Invalidations |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| sum range | 4 | 71543.61 | 88938.65 | +24.31% | 17.89% | 9.58% | -22.73% | 1778762 | 0 |

因此，第一次 `sum_range` 4 并发负值更像 macOS 短窗口波动，不应作为代码回归结论。
正式报告仍需要在 Linux CPU-set 隔离环境下用 5 轮或更多重复确认。

### Current HEAD Short Shape Profile

2026-06-26 使用 current HEAD `d71c08d0a23` release build 做了一轮短 profile
shape 矩阵，用于定位剩余 per-hit 热点。该测试启用
`COLLECT_PROFILE_STATUS=1` 和 `session_plan_cache_profile`，因此只用于根因定位，
不是正式性能结论。

环境摘要：

```text
output: /tmp/plan-cache-shape-profile-20260626-190913
tables: 4
table_size: 5000
buffer_pool: 512M
threads: 1
measure: 5s per case
shapes: point simple_range sum_range order_range distinct_range
```

QPS 方向：

| Shape | OFF QPS | ON QPS | Change | ON hits | Invalidations | CPU/kQPS change |
|---|---:|---:|---:|---:|---:|---:|
| point | 86197.60 | 93946.47 | +8.99% | 469763 | 0 | -68.63% |
| simple range | 21878.86 | 23402.38 | +6.96% | 117017 | 0 | -0.92% |
| sum range | 44009.28 | 50528.91 | +14.81% | 252657 | 0 | -13.02% |
| order range | 12179.10 | 12711.78 | +4.37% | 63559 | 0 | -2.70% |
| distinct range | 6863.78 | 12159.82 | +77.16% | 60800 | 0 | -45.95% |

ON case 的 per-hit profile hotspot：

| Shape | Hit path us/hit | Range/unique build us/hit | Range setup us/hit | Quick us/hit | Explain us/hit |
|---|---:|---:|---:|---:|---:|
| point | 0.120 | 0.084 | n/a | n/a | 0.050 |
| simple range | 0.528 | 0.482 | 0.288 | 0.121 | n/a |
| sum range | 0.479 | 0.436 | 0.285 | 0.082 | n/a |
| order range | 0.557 | 0.509 | 0.315 | 0.120 | n/a |
| distinct range | 0.681 | 0.630 | 0.447 | n/a | 0.263 |

解释：

- point/ref hit 的剩余 per-hit 成本已经明显低于 range hit；继续压 point/ref
  builder 的收益优先级低。
- simple/SUM range 的热点仍主要是 range build 和 setup，但 profile 成本约
  `0.48/0.44 us`，已经进入小补丁收益容易被系统噪声覆盖的区间。
- ORDER range 比 simple/SUM 稍重，主要是 range build/setup；但当前 QPS 仍为正，
  应等待 Linux 长稳 shape 数据确认是否值得动。
- DISTINCT range 的收益最大，同时 per-hit 成本也最高：range build、setup 和
  explain/tracker 初始化都更重。若后续 Linux shape/fixed-rate 数据显示仍有异常，
  最值得继续研究的是 exact DISTINCT range 的 metadata/setup 专用化，而不是
  point/ref 微优化。
- 所有 ON case 均有 hit 增长且 invalidation 为 0；没有 table-cache miss 或 disk
  tmp table 信号，因此这轮热点主要在 plan-cache HIT 执行态构造路径。

当前性能提升点优先级：

1. **高价值、低风险**：冻结当前 point/simple/range 小优化，补齐 Linux 绑核、
   10G buffer pool、长窗口、多轮 benchmark 证据。
2. **中价值、需数据触发**：如果正式长测显示 DISTINCT/SUM/ORDER range 中某一类
   仍有异常波动，再针对该模板做 profile 驱动的小优化。
3. **低优先级**：继续压缩 point/ref 命中路径。当前单 hit 剩余 builder/explain
   成本已经很小，macOS QPS 噪声足以覆盖收益。
4. **高风险、暂不建议**：复用完整 `QUICK_RANGE_SELECT`、跳过/重写
   `build_explain()`、绕过通用 DISTINCT/SUM 聚合 setup。这些方向需要重构执行态
   初始化语义，不适合作为当前社区准备阶段的交付主线。

### Current HEAD 4-Thread Shape Profile

同一 current HEAD 后续又跑了一轮 4 并发短 profile，用来确认 1 并发热点判断在
并发执行下是否改变。该测试同样启用 `COLLECT_PROFILE_STATUS=1`，因此仍只用于
定位，不作为正式 headline QPS 数据。

环境摘要：

```text
output: /tmp/plan-cache-shape-profile-t4-20260626-191644
tables: 4
table_size: 5000
buffer_pool: 512M
threads: 4
measure: 5s per case
shapes: point simple_range sum_range order_range distinct_range
```

QPS 方向：

| Shape | OFF QPS | ON QPS | Change | ON hits | Invalidations | CPU/kQPS change |
|---|---:|---:|---:|---:|---:|---:|
| point | 169700.89 | 178389.24 | +5.12% | 892001 | 0 | -26.83% |
| simple range | 65053.20 | 72885.56 | +12.04% | 364446 | 0 | -6.81% |
| sum range | 121729.98 | 130425.45 | +7.14% | 652174 | 0 | -9.80% |
| order range | 37028.21 | 37615.86 | +1.59% | 188081 | 0 | +0.77% |
| distinct range | 22542.22 | 35969.62 | +59.57% | 179851 | 0 | -40.33% |

ON case 的 per-hit profile hotspot：

| Shape | Hit path us/hit | Range/unique build us/hit | Range setup us/hit | Quick us/hit | Explain us/hit |
|---|---:|---:|---:|---:|---:|
| point | 0.176 | 0.115 | n/a | n/a | 0.069 |
| simple range | 0.650 | 0.604 | 0.301 | 0.220 | n/a |
| sum range | 0.707 | 0.660 | 0.347 | 0.226 | n/a |
| order range | 0.690 | 0.641 | 0.339 | 0.218 | n/a |
| distinct range | 0.840 | 0.789 | 0.477 | n/a | 0.237 |

这轮 4 并发 profile 没有改变优化优先级：

- DISTINCT range 仍是最强收益和最高 per-hit 成本的组合，属于数据触发的下一候选点。
- simple/SUM range 在 4 并发下仍有正收益，但剩余成本分散在 build/setup/quick，
  不适合在没有 Linux 回归证据前继续拆小补丁。
- ORDER range QPS 小正、CPU/kQPS 轻微变差，属于需要长稳数据观察的边界项。
- point/ref 命中路径仍明显轻于 range，继续微优化 point 不是当前最快的性能提升点。
- 所有 ON case 命中增长、invalidation 为 0，且没有 table-cache miss 或 disk tmp
  table 信号；当前瓶颈仍是 plan-cache HIT 执行态构造，而不是缓存失效或表缓存。

使用 `compare_profile_status.py` 对同一批 1 并发和 4 并发 ON profile 做归一化
对比后，进一步看到：

```text
output: /tmp/plan-cache-profile-compare-t1-t4.md
top second-profile signals:
  distinct_range hit_path:        0.681 -> 0.840 us/hit
  distinct_range range_build:     0.630 -> 0.789 us/hit
  distinct_range range_setup:     0.447 -> 0.477 us/hit
  distinct_range hit_explain:     0.263 -> 0.237 us/hit
  distinct_range setup_post:      0.144 -> 0.147 us/hit
  distinct_range setup_alloc:     0.100 -> 0.115 us/hit
  point hit_path:                 0.120 -> 0.176 us/hit
```

并发 profile 中各 range shape 的 quick-select 计时都有上升，但当前没有 QPS 回归证据，
因此它仍属于观察项。更稳定的可设计信号仍是 DISTINCT range 下的
`setup_post`、`setup_alloc` 和 `hit_explain`，且只有在 Linux 长稳 benchmark
显示该 shape 是发布阻塞点时才值得进入代码设计。

## Next Steps

1. 使用 release 版本、query cache 关闭、buffer pool 全内存、数据导入一次的方式
   重新跑 `point_select` 和 `read_only`。
2. 并发度覆盖 1/2/4/8/16，至少 5 轮，报告 median、p25、p75、min、max、CV。
3. Linux 环境下将 `mariadbd` 和 sysbench 绑到不同 CPU set；macOS 本地结果仅做
   开发定位，不作为最终社区数据。
4. 每个 ON case 记录 `Cached_plan_hits`、`Cached_plan_invalidations`、
   `Cached_plan_count`，证明命中有效且没有异常失效。
5. 若正式长测仍显示劣化，再针对 range setup allocation/post setup 设计下一轮
   小补丁；不要一次性改 JOIN 执行态大结构。
