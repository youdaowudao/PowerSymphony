# C-53 运行时测试补强设计

## Goal

把 Linear `C-53` 的首批 10 条运行时测试需求，映射到当前仓库已存在的测试边界上，形成一套可以直接进入实现的落位设计，而不是重新发明测试平台。

## Confirmed Input

这次设计只依赖两个真相源：

- Linear `C-53` 的卡片目标、范围和首批测试清单
- 当前仓库实际存在的实现与测试文件

本轮摸底确认了以下事实：

1. 目标模块确实集中在：
   - `m3_precheck`
   - `orchestrator`
   - `agent_runner`
   - `codex/app_server`
   - `run_state_store`
   - `run_live`
2. 当前仓库已经存在多组与运行时边界直接相关的测试：
   - `m3_precheck_test.exs`
   - `orchestrator_status_test.exs`
   - `app_server_test.exs`
   - `run_state_store_test.exs`
   - `run_trace_test.exs`
   - `extensions_test.exs`
3. Linear 卡中列出的 `core_test.exs` 与 `run_trace_test.exs` 更适合作为“跨模块支撑与观测补证”入口，而不是把所有首批场景硬塞进去。
4. 当前仓库的开发 / PR 规则已经明确：
   - 开发阶段只跑定向测试
   - PR create/update 且命中 `elixir/**` 时，本地 gate 必须升级到 `make all`

## Design Decisions

### 1. 这批测试是“运行时协议硬化测试”，不是独立测试平台

这批测试要守住的不是“某个函数有没有返回值”，而是：

- 开工前业务判定
- claim / dispatch / retry 的代际一致性
- `turn/completed` 到 `thread/resume` 之间的完成屏障
- `Checking` 的 bounded recheck 语义
- 运行态 summary / timeline / detail 的代际过滤

但它们仍然必须落回现有 ExUnit 套件，而不是独立拆出：

- 新的 replay 平台
- 新的专用 runner
- 新的“只有人工才会跑”的增强 lane

Linear 卡希望得到的是“低成本、本地可重复”的真实业务验证能力；如果这些测试不能进入主套件，它们很快又会回到“偶尔想起来才跑”的状态。

### 2. 落位遵循“语义最近原则”，不机械服从文件名单

Linear 卡列出了优先扩展的测试文件，但当前仓库已经继续演化，真正语义最近的文件并不完全等同于那份名单：

- `orchestrator_status_test.exs` 现在比 `core_test.exs` 更适合承接 dispatch / retry / checking 语义。
- `extensions_test.exs` 已经承担 `run_live` 的轻量加载与懒加载合同，比直接往 `run_live` 附近塞新测试更稳。
- `run_trace_test.exs` 更适合承接“trace 记录与事件归一化”补证，而不是承担所有状态机行为测试。

因此首批测试应优先放在“最接近业务语义的现有测试文件”，而不是为了满足名单形式而分散测试。

### 3. 首批 10 条测试拆成 4 个测试桶

#### A. Precheck 业务判定桶

落位：

- 主文件：`elixir/test/symphony_elixir/m3_precheck_test.exs`
- 必要时 API 映射补证：`elixir/test/symphony_elixir/extensions_test.exs`

负责场景：

- `eligible`
- `blockedBy`
- `current_work` 不可重复开工
- `blocked_but_in_progress`

#### B. Dispatch / Retry / Generation Fence 桶

落位：

- 主文件：`elixir/test/symphony_elixir/orchestrator_status_test.exs`
- 条件性支撑：`elixir/test/symphony_elixir/core_test.exs`

负责场景：

- dispatch 开工动作一致性
- retry 产生新 `run_instance_id`
- stale generation / stale continuation 不污染当前运行
- `Checking` bounded recheck

#### C. Resume Barrier / Terminal Finalization 桶

落位：

- 主文件：`elixir/test/symphony_elixir/app_server_test.exs`
- 条件性联动：`elixir/test/symphony_elixir/orchestrator_status_test.exs`

负责场景：

- `turn/completed` 后必须过 `thread/resume` barrier
- `completed` 后的 late fail / interrupted 不能继续算成功

#### D. 观测一致性与代际过滤桶

落位：

- 主文件：`elixir/test/symphony_elixir/run_state_store_test.exs`
- 条件性补证：`elixir/test/symphony_elixir/run_trace_test.exs`
- 第二批 UI 入口：`elixir/test/symphony_elixir/extensions_test.exs`

负责场景：

- 当前 run summary / event detail / surface 只读取当前 `run_instance_id`
- 观测层不接受旧代际 trace 污染

### 4. `run_live` 属于第二批观测补齐，不是首批主战场

Linear 卡范围包含 `run_live.ex`，但首批 10 条里并没有要求优先解决：

- deep view 默认轻量加载
- timeline 浏览分页
- 事件 surface 的独立懒加载

这些更接近第二批的“观测面表达正确性”。

因此首批只需要确保：

- `run_state_store` 产出的 summary / timeline / detail 已经对当前运行代际保持干净
- `extensions_test.exs` 里现有的 run deep view 轻量合同不被后续实现破坏

除非首批实现引入新的 UI 语义，否则不应主动把 `run_live` 拉成第一批主修改面。

### 5. 第二批不再机械后置，而是按耦合度并入本轮

用户目标不是把测试拆成两次 closeout 再各跑一次 `make all`，而是尽量在同一轮实现中把低耦合、同语义面的第二批项顺手做完，最后只做一次首次 full gate。

因此第二批要拆成两类：

#### 直接并入本轮

- `capacity_queued` 与 `blocked` 的区分
  - 与 `m3_precheck_test.exs` 同语义面，成本低，不值得单独续轮。
- failure / interrupt 后 `release` 与 `current_work` 清理正确
  - 与 `orchestrator_status_test.exs` 的 retry / stall / ownership 是同一状态机面。
- run summary / timeline 与真实运行一致
  - 与 `run_state_store_test.exs` 的当前代际过滤是同一观测面。

#### 保持边界，避免本轮膨胀

- `Checking / Human Review / Rework / Merging` 收尾语义完整性
  - 这条一旦做深，很容易把范围拉到 reducer / presenter / snapshot 口径重构。
- deep view 默认轻量
  - 当前 `extensions_test.exs` 已有较强合同，不应为了“顺手”把 UI 细节放大成第一批主任务。

设计结论：

- 第一批不是唯一实现范围
- 但并入本轮的第二批只允许选择与首批同文件面、同状态机面、同观测面的低耦合项
- 不允许借“想少跑一次 make all”为理由把范围膨胀成新的大 change

## 首批 10 条落位矩阵

| # | 场景 | 当前覆盖判断 | 主要落位 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | Precheck 可开工判定 | 已覆盖 | `m3_precheck_test.exs` | 已有 `eligible / dispatch` 排序与开工判定测试，后续只需补业务命名与风险说明。 |
| 2 | Precheck blockedBy 未满足 | 已覆盖 | `m3_precheck_test.exs` | 已有 non-terminal blocker 判定；可补更贴近 Linear 语言的 case 名。 |
| 3 | Precheck current_work 不可重复开工 | 部分覆盖 | `m3_precheck_test.exs` | 已有 `current_work` 归一化，但缺“同一卡已在运行时不得再次进 eligible/dispatch”的直白合同测试。 |
| 4 | Precheck blocked_but_in_progress 异常暴露 | 已覆盖 | `m3_precheck_test.exs` | 已有 anomaly 测试；应在计划里把它认定为第一批已坐实用例。 |
| 5 | Dispatch 开工动作正确 | 部分覆盖 | `orchestrator_status_test.exs` | 已有 `dispatch_started / dispatch_accepted` trace，但还需更直接锁定 claim、running entry、trace 一致性。 |
| 6 | Retry 生成新 run_instance_id | 待补强 | `orchestrator_status_test.exs` | 当前大量测试使用 `run_instance_id`，但缺 retry 必换代际的显式业务合同测试。 |
| 7 | Stale continuation 不污染当前运行 | 部分覆盖 | `orchestrator_status_test.exs` + `run_state_store_test.exs` | 已有 stale generation message discard 与 summary/detail 过滤，但仍需把“旧 continuation 不得推进当前 run”表述为主测试目标。 |
| 8 | `turn/completed` 之后必须过 resume barrier | 部分覆盖 | `app_server_test.exs` | 已有 `thread/resume` 交互和延迟冲突场景，但缺“completed 只是 provisional success”的正向合同测试。 |
| 9 | completed 后的 late fail/interrupted 不能算成功 | 已覆盖 | `app_server_test.exs` | 已有 `completed then cancelled/failed` 和 delayed variants。 |
| 10 | Checking 是单轮 bounded recheck | 已覆盖 | `orchestrator_status_test.exs` | 已有 `checking_recheck` cooldown、dispatch gate、restricted recheck mode。 |

## 现有文件的具体职责判断

### `m3_precheck_test.exs`

当前已经是首批里最完整的入口，原因是它已经覆盖：

- `eligible / dispatch`
- blocked 非 terminal 依赖
- `blocked_but_in_progress`
- `current_work` 结构归一化

因此首批在这份文件里的新增工作不应是“大改测试架构”，而是：

- 把 `current_work` 不可重复开工补成明确合同
- 把已存在场景按 Linear 业务语言重新对齐命名

### `orchestrator_status_test.exs`

当前是 dispatch / retry / checking / stale generation 的真正主入口。

它已经覆盖：

- accepted dispatch trace
- real retry dispatch path
- `checking_recheck` cooldown 和 restricted mode
- stale generation codex update / run result 丢弃

因此这份文件应承担首批里最关键的状态机补强：

- retry 必换 `run_instance_id`
- dispatch 成功时 claim、running record、trace 同步成立
- stale continuation 视角下的 generation fence 合同

### `app_server_test.exs`

当前已经是 turn terminal / resume barrier 合同的核心测试文件。

它已经覆盖：

- `turn/completed` 后的 `thread/resume`
- completed 后 late cancelled / failed
- delayed late terminal conflict

因此它的首批增量应是把语义写直：

- `completed` 不等于 finalized success
- finalized success 的唯一出口是 barrier 通过

### `run_state_store_test.exs`

当前已承担“观测层只看当前代际”的关键验证。

它已经覆盖：

- summary 忽略旧 `run_instance_id`
- detail / surface 忽略旧 attempts
- duplicate run / unavailable errors

因此它在首批里的角色不是新建一批 UI 测试，而是给 stale continuation / run generation fence 提供观测一致性补证。

### `core_test.exs` 与 `run_trace_test.exs`

这两份文件在首批里应保持克制使用：

- `core_test.exs`
  - 更适合承载跨模块测试 helper 或 orchestrator 启停夹具
  - 不是 dispatch / checking 的默认落点
- `run_trace_test.exs`
  - 更适合在需要补 trace 语义时使用
  - 不是首批所有运行时合同的主文件

## Primary Risks

1. 把首批测试错误拆到太多文件，导致 reviewer 很难看出“这一批到底守什么业务风险”。
2. 把“进入主套件”误执行成“开发期默认总是全量跑”。
3. 把 `run_live` 的观测面问题过早拉进第一批，稀释 dispatch / generation / barrier 主轴。
4. 复用现有测试时只看技术结构，不重新对齐 Linear 卡里的业务语言，导致后续还是要翻译一次。

## Design Outcome

首批 10 条测试的正确实施方式是：

- **实现形态**：进入现有 ExUnit 主套件
- **开发时机**：按改动面定向执行相关测试文件
- **质量门时机**：PR 进入 `elixir/**` 路径后随 `make all` 进入 full gate
- **首批主文件**：
  - `m3_precheck_test.exs`
  - `orchestrator_status_test.exs`
  - `app_server_test.exs`
  - `run_state_store_test.exs`
- **条件性支撑文件**：
  - `core_test.exs`
  - `run_trace_test.exs`
  - `extensions_test.exs`

并入本轮的低耦合第二批项也按同一原则处理：

- 尽量落在上述主文件中
- 不单独拉起新的测试层
- 不单独制造第二次 full gate 需求
