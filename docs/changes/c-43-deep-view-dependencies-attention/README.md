# C-43 Run 深看页依赖关系与关注事项只读面板

## 目标

在现有 run 深看页 `/projects/:project_id/runs/:issue_identifier` 中，把占位的 `Dependencies & attention` 区块补成第一版稳定、只读的关系与关注面板，让人类能在不离开当前 run 的前提下看清：

- 当前 issue 被哪些 issue 阻塞。
- 当前 issue 又阻塞了哪些 issue。
- 当前 run 现在有哪些值得继续盯的事项。
- 哪些状态只是计划内等待，不应被误包装成异常 attention。

## 需求快照

### 要解决什么问题

- 当前 `RunLive` 已有 summary、timeline、event detail 与 context placeholder，但 `Dependencies & attention` 仍只有保留文案。
- control-plane 深看页当前只消费轻量 run summary，没有把依赖关系与 attention 面板所需字段稳定投影到页面。
- 人类现在能看到“run 本身发生了什么”，但还不能一眼区分“问题来自运行过程”还是“问题来自依赖 / 等待关系”。

### 成功标准

- 深看页能稳定显示当前 issue 的 `blockedBy` 与 `blocks` 只读列表。
- 深看页能稳定显示只读 attention 列表，而不是只有静态依赖。
- `linear_state=Checking` 且仍处于计划内复查窗口时，不会被误显示为 attention。
- 页面能给出跳向相关 issue 的只读入口，不要求在当前卡里提供编辑能力。
- 新能力复用现有 run summary / project detail 链路，不为 C-43 单独新开一套 detail API 面。

### 明确不做什么

- 不允许编辑 `blockedBy` / `blocks`。
- 不做依赖画布、拖拽关系图或新的执行决策入口。
- 不把 `Context surfaces` placeholder 一并扩成 thread / turn / conversation / sub-agent 正文。
- 不新增自动建议、自动升级、自动处理 attention 的行为。
- 不把正常 `Checking` 等待直接包装成异常 attention。

### 固定约束

- 继续沿用当前 deep-view 身份键：`project_id + issue_identifier`。
- 优先复用 worker `/api/v1/state` -> control-plane `run_summaries` 的现有数据链；若字段不够，只做最小增量扩展，不新开面向 C-43 的专用后端接口。
- attention 判断必须复用既有 `StateReducer.health_for_summary/2` 与 `Checking` cooldown 语义。
- `blockedBy` / `blocks` 的呈现必须是只读投影；当前卡不承担关系修正职责。
- repo 文档不复制 Linear `## Codex Workpad` 的实时状态；这里只固化稳定目标、边界、实现路径和验证锚点。

## 当前实现判断

- `RunLive` 已有独立的 summary / timeline / event detail 状态机，适合直接在页面层补一个新的只读 panel，而不是重开页面。
- worker `running` entry 当前已经持有 `issue` 结构，内含 `blocked_by`；因此 `blockedBy` 可以从现有运行态最小投影出来。
- `blocks` 不在当前轻量 run summary 合同里，需要从同一批 worker `running` entries 中按 `blocked_by.identifier == 当前 issue_identifier` 反向计算，避免额外调用 Linear。
- attention 不需要新建状态机；可以基于现有 summary 的 `health`、`linear_state`、`current_phase`、`current_action` 等稳定字段生成只读提示。

## 风险

- 如果把 `blocks` 计算放在错误层级，容易把 project detail 的轻量列表意外升级成跨页面重合同。
- 如果 attention 规则绕开现有 `health_for_summary/2`，会与既有 quiet / stalled / Checking 语义分叉。
- 如果把依赖与 attention 混成单一字符串，后续 reviewer 很难判断是否命中 “关系面” 与 “关注面” 的职责分层。

## 验证锚点

- Presenter / control-plane 测试覆盖 run summary 新字段投影与 `blocks` 反向计算。
- LiveView 测试覆盖：
  - 正常渲染 `blockedBy` / `blocks`。
  - `possibly_stalled`、`needs_attention` 等 attention 的只读展示。
  - `Checking` 且仍在 cooldown 时不显示 attention。
  - 无依赖、无 attention 时的空态文案。
- 既有 timeline / event detail 行为保持可用，不因本卡新增 panel 被覆盖或回退。

## 文档索引

- 当前入口文件即本卡稳定目标快照。
- [20_plan.md](./20_plan.md)
