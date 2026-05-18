# C-44 Run 深看页产品层收口

## 目标

把现有 run 深看页 `/projects/:project_id/runs/:issue_identifier` 从“功能都在，但阅读顺序、状态表达和交互层级都偏散”的第一版只读页，收口成一版可长期使用的产品层结构。

本 change 只整理深看页现有 summary、timeline、event detail、context、dependencies、attention 这些已存在能力的展示层与轻交互，不扩展新的重数据面，也不改变深看页背后的按需加载边界。

## 需求快照

### 要解决什么问题

- 当前 `RunLive` 把六个大区块顺序平铺，缺少主次层级，用户需要自己判断先看哪里。
- Timeline、Context、Dependencies、Attention 各自可用，但彼此没有围绕“先判断当前 run 是否健康，再决定是否展开细节”的阅读顺序组织。
- 空态、异常态、加载态都存在，但缺少统一表现，页面在“没有数据”“接口失败”“局部仍在加载”之间的心理模型不够稳定。
- 页面没有产品层折叠与过滤入口，深看页一旦信息量上来，就会迅速变成“所有区块同时展开”的噪音面板。
- 现有移动端只依赖基础响应式样式，缺少明确的最小可用布局和信息压缩顺序。

### 成功标准

- 深看页具备清晰的主阅读路径：先看概览，再看需要处理的事项，再按需进入 timeline / context / event detail。
- 页面提供基础交互收口，至少包含折叠 / 展开和面向 timeline 的轻量过滤，且不引入新的重数据加载。
- 空态、异常态、加载态采用统一的组件化表达，不再让各区块各说各话。
- 页面明确哪些信息始终可见，哪些信息默认折叠，避免“全都很重要”的噪音状态。
- 移动端保留最小可用：主摘要、注意事项、区块折叠、timeline 浏览都能正常工作。
- 现有按需加载边界保持稳定：summary 首屏仍然轻量，timeline/context/detail/surface 仍然独立懒加载。

### 明确不做什么

- 不新增 raw / payload / prompt / shell 的默认正文加载。
- 不改变 `project_id + issue_identifier` 深看页身份键。
- 不新增新的深看数据类型，不扩展后端 summary/context/timeline 合同。
- 不改变 thread / turn / continuation / dependency / attention 的来源定义。
- 不把本卡升级成新的品牌视觉工程或设计系统改造。
- 不引入编辑依赖、处理 attention、改变执行逻辑等写操作能力。

### 固定约束

- 首屏概览只允许消费 `RunLive.load_run/1` 取得的 `run_state.run` summary payload；不允许等待或偷用 timeline/context/detail/surface 的懒加载 payload。
- 深看页继续复用 `Presenter.project_run_summary_payload/3`、`Presenter.run_timeline_payload/1`、`Presenter.run_context_payload/1`、`Presenter.run_event_detail_payload/1` 和既有 `ObservabilityApiController` / `Orchestrator` 懒加载链路。
- Timeline、Context、Event detail、Surface 的加载入口、错误语义和独立失败退化必须保持现有兼容性。
- Dependencies 与 Attention 继续只读，字段来源仍来自 `ProjectProcessManager` 的运行态投影，不得绕过现有 source of truth。
- 本卡触达 `elixir/**` 与 LiveView 行为，属于 PR-bound full-gate 路径；PR create/update 前本地门禁必须是 `make all`。

## 风险判定

### 任务类型识别

- 任务类型：`Large change`
- 原因：
  - 至少会修改 `RunLive` 模板/状态机、样式文件和对应 LiveView 测试。
  - 用户可见行为会变化，且需要补充新的区块层级、折叠状态与过滤交互。
  - 变更横跨现有 summary/timeline/context/detail 多个消费面，但不改其底层数据合同。

### 观察层合同风险

- 结论：`已命中`
- 原因：
  - 同一语义被多个消费面读取：`health`、`attention_items`、`blocked_by` / `blocks`、timeline labels、context 状态会同时出现在 summary 区、attention 区、折叠区块标签和过滤结果中。
  - 页面会引入新的聚合展示：例如“需要处理的事项优先级”“区块默认折叠策略”“timeline 过滤结果”，都属于对既有语义的再组织，而非原样透传。
  - 用户依赖这些展示判断是否继续展开 detail，因此必须明确 allowed transform 与 must-not-infer 边界。

## Source-of-Truth Chain

| 关键字段 / 语义 | 实际 source | 中间 projection | 最终 consumer |
| --- | --- | --- | --- |
| run headline / status (`issue_identifier`, `title`, `linear_state`, `current_phase`, `current_action`, `health`) | worker `/api/v1/state` running entry，或 workflow 路径下 orchestrator 当前 running entry | `ProjectProcessManager.project_run_summary_from_running_entry/1` -> `attach_run_summary_relationships/1` -> project registry `runtime_state.run_summaries` -> `Presenter.project_summary_payload/2` / `project_run_summary_payload/3` -> `RunLive.load_run/1` | `RunLive` 概览区、区块 badge、静态默认折叠状态 |
| dependency lists (`blocked_by`, `blocks`) | running entry `blocked_by` + `ProjectProcessManager.reverse_blocks_for_summary/2` 基于同批 running summaries 的反向计算 | `attach_run_summary_relationships/1` -> project registry `runtime_state.run_summaries` -> `Presenter.project_run_summary_payload/3` -> `RunLive.load_run/1` | `RunLive` 的 Dependencies 区、概览 counts |
| attention semantics (`attention_items`) | `ProjectProcessManager.attention_items_for_summary/1`，内部复用 `StateReducer.health_for_summary/2`、blocker / blocked children 规则 | project registry `runtime_state.run_summaries` -> `Presenter.project_run_summary_payload/3` -> `RunLive.load_run/1` | `RunLive` Attention 区、`Action Needed` 首条重点、概览 counts |
| timeline items and status markers | `RunTrace.timeline/2` 或 `RunStateStore.timeline_page_for_running_entries/3` | `Presenter.run_timeline_payload/1` | `RunLive` Timeline 区、timeline filters、事件 badge |
| context cards (`anchor`, `conversation`, `continuation`, `tools`, `shell`, `subagents`) | `RunTrace.context_summary/2` 或 `RunStateStore.context_summary_for_running_entries/2` | `Presenter.run_context_payload/1` | `RunLive` Context 区块、移动端压缩摘要 |
| event detail / surfaces | `RunTrace.event_detail/3` / `event_surface` 路径，或对应 running-entry worker proxy | `Presenter.run_event_detail_payload/1` / `Presenter.run_event_surface_payload/1` | `RunLive` Event detail 区与 surface lazy body |

## Contract Matrix

| field / view | source of truth | allowed transform | must not infer |
| --- | --- | --- | --- |
| 概览主状态与健康度 | `project_run_summary_payload/3` 中已有 summary 字段 | 可重排显示顺序、可映射成 badge / hero / concise copy | 不得凭 UI 状态自创新的 run health、phase 或 linear state |
| Dependencies 视图 | `blocked_by` / `blocks` 只读列表 | 可按“Blocked by / Blocks”分组、可在空态时统一降级、可在概览中只显示计数或摘要 | 不得推断新的依赖，不得把缺失 identifier 的 placeholder 当成可编辑实体 |
| `Action Needed` 概览首条重点 | `attention_items` 原始列表的现有顺序 | 只允许展示第一个 `attention_items[n]` 的 message，或在空列表时显示固定空态；Dependencies 继续在同一区块单独展示 | 不得把 `current_action`、`health`、`blocked_by`、`blocks` 或任何 lazy payload 再组合成新的 attention 排序 |
| 首屏 counts | `length(attention_items)`、`length(blocked_by)`、`length(blocks)` | 可显示为只读计数 chips 或 summary stats | 不得展示 timeline/context/detail/surface 的 count，也不得因为未 lazy load 而推断“预计 count” |
| Timeline filters | `timeline_state.items` 的现有 `event_type` / `source` / `status_markers` 原始字段 | 只允许前端本地筛选；允许把固定 predicate humanize 成 filter label | 不得请求额外 timeline 数据，不得隐式丢弃事件，只能对已加载 items 做显示过滤 |
| Context / Event detail 折叠与空态 | 现有 `context_state` / `detail_state` / `surface_state` 加载状态与 payload | 可统一空态、错误态、加载态文案与容器样式 | 不得把局部失败推断成 run 不存在，也不得因某个懒加载失败隐藏 summary/timeline |

## 冻结的展示口径

- 页面主区块固定为：`Overview`、`Action Needed`、`Timeline`、`Context`、`Event Detail`。
- 默认展开策略固定为静态策略，不允许依据 `health`、`current_action`、`attention_items` 或其他数据动态推断：
  - 默认展开：`Overview`、`Action Needed`、`Timeline`
  - 默认折叠：`Context`
  - `Event Detail` 在未选择 event 前保持入口态，视为默认折叠
  - surface bodies 继续默认折叠
- `Action Needed` 的唯一重点来源是 `attention_items`：
  - 首条重点只允许显示 `attention_items` 的第一条 message
  - 若 `attention_items == []`，显示固定空态，不得回退到 `current_action` 或 `health`
  - Dependencies 仍在 `Action Needed` 内单独列出，不参与“首条重点”重新排序
- 首屏可用 counts 只允许使用以下三个只读值：
  - `attention_count = length(attention_items)`
  - `blocked_by_count = length(blocked_by)`
  - `blocks_count = length(blocks)`
- Timeline filter 的 allowed set 固定为：
  - `all`: 不过滤
  - `attention`: `status_markers` 包含 `attention`
  - `retry`: `source == "orchestrator"` 且 `event_type == "retry_scheduled"`
  - `session`: `event_type == "session_started"`
  - `turn_completed`: `event_type == "turn_completed"`
  - `run_result`: `event_type == "run_result"`
- active timeline filter 与 `load_more` 的规则固定为：
  - `timeline_state.items` 始终保留所有已加载 item
  - filter 只影响渲染结果，不修改底层 items
  - `load_more` 追加新页后，当前 active filter 重新应用到“累计 items”上
  - control-plane 与 workflow 两条链都必须遵守同一过滤口径

## 设计结论

本卡采用“保留现有数据边界，在 `RunLive` 上增加产品层布局壳和轻交互状态”的方案：

- 在首屏引入更强的概览区，把主状态、当前动作和冻结好的三类 counts 前置。
- 把页面正文改造成带静态默认折叠策略的区块组：`Overview / Action Needed / Timeline / Context / Event Detail`。
- `Action Needed` 只复用现有 `attention_items` 与 dependencies，不重新发明排序规则。
- Timeline 增加固定口径的本地轻量 filter，不新增接口；Event detail 继续由用户点击触发懒加载。
- 把空态、错误态、加载态收口为统一容器和文案模式，保证每个区块都能独立降级。
- CSS 在现有 `dashboard.css` 上最小增量扩展，避免另起页面专属样式体系。

## 验证锚点

- `extensions_test.exs` 覆盖：
  - 默认概览层级与主要区块是否存在。
  - `Action Needed` 首条重点只来自 `attention_items[0]`，`Checking + attention_items == []` 时保持空态而不回退到其他字段。
  - 首屏 counts 只展示 `attention_count`、`blocked_by_count`、`blocks_count`。
  - 折叠 / 展开交互是否只影响视图，不触发额外重数据请求。
  - timeline filter 是否只基于现有 items 生效，且 active filter 在 `load_more` 后重新应用到累计 items。
  - 统一空态、异常态、加载态是否正确渲染。
  - 无 identifier 的 blocker placeholder 在概览压缩与 dependencies 列表里仍可见。
  - 移动端最小布局关键类名和 DOM 结构是否稳定。
- 保留既有回归：
  - timeline / context / detail / surface 的独立懒加载与错误退化不回退。
  - dependency / attention 语义与既有测试仍一致。
  - control-plane 与 workflow 两条 summary/timeline/context 链在新布局、折叠和 filter 下语义一致。
- closeout gate 之外，最终 PR create/update 前执行 `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- make all`。

## 文档索引

- [20_plan.md](./20_plan.md)
