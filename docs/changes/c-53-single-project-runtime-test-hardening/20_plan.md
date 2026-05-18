# C-53 运行时测试补强实施计划

## 实施原则

- 先补 change 文档，再按首批 10 条的风险顺序实现。
- 优先扩展现有测试文件，不新建独立测试工程。
- 每条测试都要能说明它防的是哪一种真实业务错误。
- 开发阶段坚持最轻定向测试；进入 PR create/update 前再按仓库 `Next Push Gate` 判断是否升级到 `make all`。

## 预期改动面

### 第一批主要测试文件

- `elixir/test/symphony_elixir/m3_precheck_test.exs`
- `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- `elixir/test/symphony_elixir/app_server_test.exs`
- `elixir/test/symphony_elixir/run_state_store_test.exs`

### 可能的辅助文件

- `elixir/test/symphony_elixir/core_test.exs`
- `elixir/test/symphony_elixir/run_trace_test.exs`
- `elixir/test/symphony_elixir/extensions_test.exs`

### 预期实现文件

这张卡当前阶段优先是测试补强卡，不预设必须修改实现文件；只有在补测试时发现现有合同无法被稳定表达，才允许最小实现修正。可能触达的实现文件包括：

- `elixir/lib/symphony_elixir/m3_precheck.ex`
- `elixir/lib/symphony_elixir/orchestrator.ex`
- `elixir/lib/symphony_elixir/agent_runner.ex`
- `elixir/lib/symphony_elixir/codex/app_server.ex`
- `elixir/lib/symphony_elixir/run_state_store.ex`

`run_live.ex` 不作为首批默认改动面，除非实现首批用例时直接暴露 UI 语义缺口。

## 第一批拆分

### 任务 1：补强 Precheck 业务判定合同

**主要文件：**

- `elixir/test/symphony_elixir/m3_precheck_test.exs`

**覆盖场景：**

1. Precheck 可开工判定
2. Precheck blockedBy 未满足
3. Precheck current_work 不可重复开工
4. Precheck blocked_but_in_progress 异常暴露

**实施重点：**

- 保留已存在的 `eligible / blocked / anomalies` 测试。
- 新增“当前同一卡已在 `current_work` 中时，不得再次进入本轮 dispatch”的显式业务合同。
- 让 case 名和断言更贴近 Linear 卡的业务语言，而不是只剩技术性字段。

**开发时定向命令：**

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/m3_precheck_test.exs
```

### 任务 2：补强 Dispatch / Retry / Generation Fence

**主要文件：**

- `elixir/test/symphony_elixir/orchestrator_status_test.exs`

**候选辅助：**

- `elixir/test/symphony_elixir/core_test.exs`

**覆盖场景：**

5. Dispatch 开工动作正确
6. Retry 生成新 `run_instance_id`
7. Stale continuation 不污染当前运行
10. Checking 是单轮 bounded recheck

**实施重点：**

- 把已存在的 `dispatch_started / dispatch_accepted` trace 测试补成“claim、running entry、trace 三者一致成立”的合同。
- 显式新增 retry 后代际切换测试，锁定新 run 必换 `run_instance_id`。
- 将当前 stale generation message discard 进一步表达成“旧 continuation 不能污染当前运行”。
- 对 `checking_recheck` 保持单轮、限界和 cooldown 语义，不允许回退成普通 continuation。

**开发时定向命令：**

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs
```

### 任务 3：补强 Resume Barrier 与 Terminal Finalization

**主要文件：**

- `elixir/test/symphony_elixir/app_server_test.exs`

**覆盖场景：**

8. `turn/completed` 之后必须过 resume barrier
9. completed 后的 late fail/interrupted 不能算成功

**实施重点：**

- 保留现有 `completed then cancelled/failed`、delayed conflict 测试。
- 新增正向合同：`turn/completed` 只代表 provisional success，最终成功必须等 `thread/resume`。
- 如果当前正向合同已被已有测试间接证明，也要把它改成显式业务测试名，避免 reviewer 需要从多个 case 反推。

**开发时定向命令：**

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/app_server_test.exs
```

### 任务 4：补强观测一致性与代际过滤

**主要文件：**

- `elixir/test/symphony_elixir/run_state_store_test.exs`

**候选辅助：**

- `elixir/test/symphony_elixir/run_trace_test.exs`
- `elixir/test/symphony_elixir/extensions_test.exs`

**覆盖场景：**

- 为第 7 条 stale continuation 提供观测层补证
- 证明 summary / detail / surface 只消费当前 `run_instance_id`

**实施重点：**

- 保留当前 summary/detail/surface 的代际过滤测试。
- 若状态机实现补强新增了 trace 语义，再把最小补证补到 `run_trace_test.exs`。
- `extensions_test.exs` 当前只做 UI 轻量合同守卫，不主动扩成第一批主战场。

**开发时定向命令：**

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/run_state_store_test.exs
```

### 任务 5：并入低耦合第二批项，避免第二轮单独收口

**主要文件：**

- `elixir/test/symphony_elixir/m3_precheck_test.exs`
- `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- `elixir/test/symphony_elixir/run_state_store_test.exs`

**并入场景：**

- Precheck `capacity_queued` 与 `blocked` 的区分
- failure / interrupt 后 `release` 与 `current_work` 清理正确
- run summary / timeline 与真实运行一致

**实施重点：**

- 只并入与首批同文件面、同状态机面的第二批项。
- 不把 `run_live` 的 UI 细节和更广的 closeout 语义完整性一起拉进本轮。
- 所有并入项都必须服务于“减少未来第二次 full gate 概率”，而不是增加新的实现面。

## 质量门策略

### 1. 开发阶段

这批测试首先是**开发期定向增强回归**。

执行规则：

- 改 `m3_precheck` -> 跑 `m3_precheck_test.exs`
- 改 orchestrator / retry / checking -> 跑 `orchestrator_status_test.exs`
- 改 `app_server` / barrier -> 跑 `app_server_test.exs`
- 改 `run_state_store` / 观测过滤 -> 跑 `run_state_store_test.exs`

这一步不要求默认全量 `make all`。

### 2. PR create/update 前

这张卡只要开始落测试代码，就命中 `elixir/**`。

因此仓库规则下：

- 当前分支用于 PR create/update 时，`Next Push Gate` 必须按 full-gate 路径处理。
- 也就是在 push 前执行：

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- make all
```

结论：

- **开发中**：按测试桶定向跑
- **进入 PR gate**：作为主套件的一部分进入 `make all`

### 4. 单次 `make all` 策略

本轮目标是尽量把首次 PR-bound full gate 压到一次，执行顺序固定为：

1. 先完成首批 + 已并入的低耦合第二批测试补强。
2. 开发过程中只跑对应测试桶的定向测试，不提前跑 `make all`。
3. 等实现线程和 reviewer 视角都认为可以 closeout 时，再执行第一次本地 `make all`。

约束也必须写清：

- 这是一种**目标策略**，不是对仓库规则的豁免。
- 如果第一次 `make all` 暴露问题，按仓库规则必须修完后再重跑，不能为了“只跑一次”压过规则。
- 因此正确目标不是“承诺永远只跑一次”，而是“在范围和顺序上尽量避免人为制造第二次本地 full gate”。

### 3. 远端 CI

远端 CI 不应是第一次发现这些问题的主要入口，但这些测试仍应成为正常 CI 回归的一部分。

这也是为什么它们必须落回现有 ExUnit 主套件，而不是独立维护一条“增强脚本”。

## 首批实现顺序

建议顺序：

1. `m3_precheck_test.exs`
2. `orchestrator_status_test.exs`
3. `app_server_test.exs`
4. `run_state_store_test.exs`

原因：

- 先锁最便宜、最纯的业务判定。
- 再锁最危险的 dispatch / retry / generation fence。
- 再锁 completion barrier。
- 最后补观测层代际一致性。

## 首批收口判断

首批 10 条实现收口前，必须能明确回答：

1. 哪几条是复用已有测试并重命名/补强即可。
2. 哪几条是当前仓库真空区，必须新增测试。
3. 哪几条需要最小实现修正，而不是只补测试就能坐实。
4. 这些测试是否都进入了现有 `mix test` 主套件，而不是挂在单独脚本上。

## 目前摸底结论

截至当前文档阶段，基于现有仓库测试可先做如下判断：

- **已覆盖，可直接承接为首批正式合同**
  - Precheck 可开工判定
  - Precheck blockedBy 未满足
  - Precheck blocked_but_in_progress 异常暴露
  - completed 后的 late fail/interrupted 不能算成功
  - Checking 是单轮 bounded recheck
- **部分覆盖，需要补强**
  - Precheck current_work 不可重复开工
  - Dispatch 开工动作正确
  - Stale continuation 不污染当前运行
  - `turn/completed` 之后必须过 resume barrier
- **当前优先真空区**
  - Retry 生成新 `run_instance_id`

## 体量控制

### 当前判断

- 本卡主触达测试面约 `234` 个既有 case
- 首轮合理新增规模应控制在 `15-25` 条 case

### 控制原则

- 超过 `25` 条新增 case 时，优先检查是否把不该并入本轮的第二批项带进来了。
- 如果某个场景需要新建复杂 harness、依赖真实 Linear、或明显拖慢反馈回路，则不并入本轮。
- `extensions_test.exs` 与 `run_trace_test.exs` 只做补针，不作为首轮主增长面。

这份判断应作为后续实现的默认起点，除非补读代码后发现更强约束。
