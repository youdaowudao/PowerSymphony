# C-53 单项目真实业务运行时测试补强

## 目标

把 Linear `C-53` 中已经明确的“单项目真实业务运行时测试补强”要求，收敛成一组可 review、可 handoff、可继续实现的稳定 change 文档。

本 change 只处理当前单项目真实业务主链路里最贵、最难重复、最容易漏掉的运行时边界测试，不回退到真实 Linear 大量联调，也不把这张卡扩大成测试平台建设。

## 需求快照

### 要解决什么问题

- 当前最危险的缺口已经不是静态逻辑，而是运行时协议、状态迁移、线程代际隔离和观测一致性。
- 这些问题如果继续主要靠真实业务流去验证，验证成本高、频率低，线程串线和状态机误判更容易漏掉。
- 当前仓库虽然已经有一批相关测试，但覆盖面分散在 `m3_precheck`、`orchestrator_status`、`app_server`、`run_state_store`、`extensions` 等文件里，尚未形成一套围绕真实业务风险排序的补强计划。
- Linear 卡明确要求把“当前单项目真实业务里最贵、最难测、最容易漏的运行时问题”压缩成一组本地可重复执行的测试资产。

### 成功标准

- 首批 10 条高价值运行时测试有清晰落位，不依赖新增通用测试平台。
- 每条首批测试都能明确回答：
  - 它防哪一种真实业务错误
  - 应落到哪个现有测试文件
  - 当前是“已覆盖 / 部分覆盖 / 待补强”
- 这些测试最终进入现有 `mix test` 主套件，而不是单独维护一条脱离主套件的增强通道。
- 同时要明确运行分层：
  - 开发阶段按改动面跑定向测试
  - PR create/update 前按仓库 `Next Push Gate` 决定是否升级到 `make all`
  - 远端 CI 继续把这些测试当作正常回归的一部分
- 第一批只聚焦：
  - Precheck 开工判定
  - Dispatch / retry / run_instance_id 代际隔离
  - `turn/completed` 后的 resume barrier
  - `Checking` 的 bounded recheck 语义

### 明确不做什么

- 不新建独立 replay 平台、通用测试基建或新的重型 harness。
- 不把这张卡扩大成未来多项目抽象设计。
- 不依赖大量真实 Linear 卡片消耗来证明首批边界。
- 不把所有建议文件都机械塞进第一批；首批应优先落在语义最接近的现有测试文件。
- 不把 `make all` 误写成日常开发命令。

### 固定约束

- 文档按仓库规则落在 `docs/changes/`，因为本卡跨模块、高风险、需要零上下文复核。
- 目标模块范围以 Linear 卡为准：
  - `elixir/lib/symphony_elixir/m3_precheck.ex`
  - `elixir/lib/symphony_elixir/orchestrator.ex`
  - `elixir/lib/symphony_elixir/agent_runner.ex`
  - `elixir/lib/symphony_elixir/codex/app_server.ex`
  - `elixir/lib/symphony_elixir/run_state_store.ex`
  - `elixir/lib/symphony_elixir_web/live/run_live.ex`
- 优先扩展现有测试文件，不单独起一套新的测试工程。
- 本卡新增测试必须优先贴近真实业务语义，而不是为了抽象漂亮去重写现有测试结构。
- 这些测试属于“运行时协议硬化测试”：
  - 不是 live E2E 抽检
  - 不是独立 nightly lane
  - 是现有 ExUnit 主套件中的高价值回归资产

## 测试运行定位

### 领域定位

这批测试属于“单项目真实业务运行时协议硬化测试”。

它们的特点是：

- 语义比纯函数单测更贴近真实业务
- 成本又必须远低于真实 Linear 联调
- 目标是守住运行时代际、状态迁移和观测一致性

因此它们不应被设计成一条独立于主套件之外的“专门增强通道”；正确定位是：

- **实现形态**：落回现有 `mix test` / ExUnit 套件
- **开发时机**：按改动面定向执行相关测试文件
- **质量门时机**：进入 PR 后随仓库既有 gate 一起执行

### 运行分层

1. **开发阶段**
   - 按改动面跑最轻定向测试。
   - 例如：
     - `m3_precheck` 改动 -> `mix test test/symphony_elixir/m3_precheck_test.exs`
     - `orchestrator / agent_runner` 改动 -> `mix test test/symphony_elixir/orchestrator_status_test.exs`
     - `app_server` 改动 -> `mix test test/symphony_elixir/app_server_test.exs`
     - `run_state_store / run_live` 改动 -> `mix test test/symphony_elixir/run_state_store_test.exs` 与相关 `extensions_test.exs`
2. **PR create/update 前**
   - 这张卡触达 `elixir/**`，因此最终是否跑 `make all` 不由“测试卡特殊性”决定，而由仓库 `Next Push Gate` 决定。
   - 当前仓库规则下，命中 `elixir/**` 的 PR create/update push 必须先本地 `make all`。
3. **远端 CI**
   - 这些测试作为主套件的一部分进入正常回归。
   - 远端 full gate 是最终复核器，不应是第一次发现这批运行时问题的主要入口。

结论：

- **不是**“单独跑的增强套件”
- **也不是**“每次开发默认先全量跑的特殊门”
- **而是**“开发时定向跑、PR full gate 时随主套件进入质量门的运行时硬化回归”

## 体量评估

### 当前测试面大小

本卡主要触达的现有测试文件共有约 `234` 个 test case：

- `m3_precheck_test.exs`: `11`
- `orchestrator_status_test.exs`: `61`
- `app_server_test.exs`: `25`
- `run_state_store_test.exs`: `11`
- `run_trace_test.exs`: `45`
- `extensions_test.exs`: `81`

当前仓库整体大约有 `617` 个 test case，因此本卡触达的是最核心、最敏感的一圈运行时测试面，但这不代表要一次性大规模重写这些文件。

### 预计新增体量

结合当前“已覆盖 / 部分覆盖 / 真空区”判断，本卡首轮合理新增规模应控制在：

- **首批 + 低耦合第二批合并后**：约 `15-25` 条新增 case

这意味着：

- 体量不小，确实会抬高 `mix test --cover` 的执行成本
- 但还在合理范围内，不需要因为体量就拆成独立增强套件

### 体量红线

以下任一情况出现时，应停止继续往本轮塞范围，改为单独续卡或拆到下一轮：

- 预计新增 case 明显超过 `25`
- 需要把 `run_live` UI 细节拉成第一批主改动面
- 需要新建复杂 harness、通用 replay 平台或跨模块测试基建
- 需要让大量测试依赖真实 Linear、真实网络或长时间等待

本卡的正确规模是：

- 足够覆盖真实业务最贵的运行时边界
- 但仍保持“主套件回归 + 开发期定向测试”这一运行方式

## 文档索引

- [10_design.md](./10_design.md)
- [20_plan.md](./20_plan.md)
- [90_verification.md](./90_verification.md)

## 关联材料

- Linear 真相源：`C-53 单项目真实业务运行时测试补强卡`
- 相关既有变更：
  - [docs/changes/c-52-workspace-lifecycle-turn-finalization/README.md](../c-52-workspace-lifecycle-turn-finalization/README.md)
  - [docs/changes/c-52-workspace-invalidation/README.md](../c-52-workspace-invalidation/README.md)
  - [docs/changes/c-50-ownership-gate/README.md](../c-50-ownership-gate/README.md)
