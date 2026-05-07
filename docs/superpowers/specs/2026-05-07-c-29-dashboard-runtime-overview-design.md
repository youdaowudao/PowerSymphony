# C-29 Dashboard 多项目运行态总览设计

## 背景

`main` 现有 `DashboardLive` 已经能在 control-plane 模式下展示项目列表，但内容仍停留在静态 `validation_result / validation_errors / runtime_state.status = not_started`。`ProjectProcessManager`、`WorkerHealthPoller`、项目摘要 API 已经具备更真实的运行态字段与 `start / stop / restart` 能力，本卡需要把这些现有能力收口到首页控制面。

## 目标

在不新增重型观测流的前提下，把 control-plane 首页升级成多项目 worker 轻量运行态总览，让用户打开 `/` 后能直接看到每个项目的可用性与处理入口。

## 范围

- 首页继续沿用现有 `DashboardLive`，不另起平行页面体系。
- control-plane 总览必须展示 `project / enabled / worker_status / worker_port / last_seen_at / last_error / actions`。
- 页面内直接提供 `start / stop / restart`。
- 操作后要能看到状态刷新。
- 总览页继续保持轻量，不引入 raw/timeline/event detail。

## 非目标

- 不做 M3 的 Codex phase/action/health 可视化。
- 不做 raw debug page。
- 不做复杂筛选、图表、长轮询日志面板。
- 不为了本卡新增新的公开控制协议。

## 方案对比

### 方案 A：在 `DashboardLive` 里直接接 `ProjectProcessManager`，用轻量定时刷新维持总览

这是推荐方案。

- 数据仍通过 `Presenter.projects_payload/1` 输出，避免 LiveView 自己拼装运行态。
- 动作直接调用 `ProjectProcessManager.start_project/1`、`stop_project/1`、`restart_project/1`。
- control-plane 模式下单独启用轻量 tick，只刷新 `projects_payload`，不订阅 observability event stream。
- 页面保留首页入口，不依赖浏览器直连各 worker，也不要求浏览器调用现有 JSON API。

优点：

- 复用当前控制面与现有运行态真源，改动集中。
- 最符合“总览优先、页面轻量”的边界。
- 容易用现有 `ExtensionsTest` 与 `ProjectProcessManagerTest` 补齐 TDD。

缺点：

- `DashboardLive` 需要补一层 control-plane 专用事件和展示逻辑。

### 方案 B：前端继续只读，按钮通过浏览器 fetch 已有 `/api/v1/projects/:id/*`

- UI 改动较小。
- 但会把页面交互拆成 LiveView + 浏览器手写 fetch，两套状态源更难保证一致。
- 失败态、按钮禁用、测试方式都会更分裂。

结论：不采用。

### 方案 C：新增 `/projects/:project_id` 详情页承载动作，总览页只保留摘要

- 结构上更容易扩展后续 M3。
- 但本卡优先级是首页收口，详情页会分散实现与测试精力。

结论：本卡不采用；若后续需要，再作为增量扩展。

## 最终设计

### 1. 数据模型

`Presenter.project_entry_payload/1` 继续作为 control-plane 项目总览的统一输出，保留现有字段并补强两个展示语义：

- `last_error` 优先显示 runtime 错误；若 runtime 未给出错误且项目存在 validation errors，则回退为首个或合并后的 validation summary。
- `runtime_state` 仍保持轻量，只保留 `status`，避免把原始事件、timeline 或进程细节塞进 LiveView assigns。

### 2. 首页展示

control-plane 下的 `Projects` 表升级为以下列：

- `Project`
- `Enabled`
- `Worker status`
- `Worker port`
- `Last seen`
- `Last error`
- `Actions`

其中：

- `Project` 单元格显示项目名、项目 ID，以及现有 JSON summary link。
- `validation_result` 作为项目元信息保留在 `Project` 单元格，避免丢失配置校验语义，但不再占独立主列。
- `Last error` 统一承载运行态错误或配置错误摘要，帮助用户一眼看出“需要处理”的项目。

### 3. 交互与刷新

- control-plane 模式下，`DashboardLive` 在连接后启动轻量 tick，例如每 2 秒重新加载 `projects_payload`。
- `handle_event("project_action", ...)` 根据 `action` 调用 `ProjectProcessManager`。
- 动作返回后立即重新加载 `projects_payload`，并用 flash 或行内文案反馈结果。
- 刷新只重取项目摘要，不触碰 `Presenter.state_payload/2`、`issue_payload/3`、raw events、timeline 或 rate limit 区块。

### 4. 隔离性

- 所有动作都按 `project_id` 落到 `ProjectProcessManager` 的单项目接口。
- A 项目状态变化只会更新对应 runtime entry，不会改写 B 项目的 `last_seen_at`、`last_error` 或 `worker_status`。
- 这一点依赖既有 `ProjectProcessManager` / `WorkerHealthPoller` 隔离语义，并在 LiveView 集成测试中再做一层 UI 证明。

### 5. 测试策略

优先补 `elixir/test/symphony_elixir/extensions_test.exs` 的 control-plane LiveView 集成测试，覆盖：

- 至少两个项目的总览展示。
- `running / unreachable / not_started / invalid` 等状态的页面渲染。
- `start / stop / restart` 触发后页面刷新。
- A/B 项目状态隔离。
- control-plane 页面不渲染 `Running sessions`、`Retry queue`、`Rate limits`，也不需要 raw/timeline/event 内容。

补充单元/集成验证：

- `Presenter` 的 `last_error` 回退逻辑。
- 原单项目 CLI 不回归，至少保持现有相关测试绿。

## 风险与约束

- 本卡不应改动 `Application child_specs`、`Orchestrator`、`AppServer`、`SSH`、`live_e2e` 等高风险路径；如果实现过程中必须触碰，验证门槛要升级到完整 `mix test` 与 `mix test --cover`。
- control-plane 页面刷新必须保持轻量，不能为了“实时感”把 workflow mode 的重型观测逻辑搬进来。
- 由于当前 run 是 unattended ticket workflow，本轮以“先形成设计文档与计划文档，再进入实现”替代互动式审批，不在中途等待人工确认。

## 验收映射

- 多项目显示：通过双项目 control-plane LiveView 集成测试证明。
- 运行态字段显示：页面断言 `worker_status / worker_port / last_seen_at / last_error`。
- 页面动作：LiveView `render_click` 驱动 `start / stop / restart`。
- 状态刷新与隔离：动作后重新渲染，并断言未操作项目不串写。
- 轻量性：断言 control-plane 页面不出现 raw/timeline/event/rate limit/running session 区块。
- 单项目 CLI 不回归：保留现有相关测试通过。
