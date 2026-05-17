# C-42 Run 深看页上下文串联实施计划

## 目标

在不引入新的重数据浏览层的前提下，为 run 深看页补齐 thread / turn / conversation / continuation / tools / shell / sub-agent 的轻量上下文串联卡。

## 实施顺序

### 1. 先用测试锁定 context summary 合同

- 为 `RunTrace` / `RunStateStore` 新增聚合测试，覆盖：
  - thread / turn anchor
  - `run_instance_id` / generation 过滤，证明旧 attempt 事件不会串进当前 context
  - reasoning / requestUserInput recent interaction signals 摘要
  - `params.question` / `params.prompt` / `params.questions[*].question` 的提取优先级与降级
  - continuation / retry 标签及其优先级、空态
  - tool / shell 摘要
  - sub-agent `unavailable` / `none_observed` 降级
- 为 controller 新增 worker 与 control-plane 的 context 读取和错误映射测试。
- 为 `RunLive` 新增上下文卡渲染与独立错误态测试。
- 对 context item 新增锚点验证，证明 item 能回到 timeline / event detail，而不是悬空摘要。

### 2. 新增 worker 侧 context summary 聚合

- 在 `RunTrace` 或 `RunStateStore` 中增加“最近窗口上下文聚合”读取能力。
- 尽量复用现有 raw event、`StatusDashboard.humanize_codex_message/1`、`StateReducer` 的既有语义。
- 保持读取范围只在当前 running entry 的当前 run_trace。
- 聚合前必须先按当前 entry 的 `run_instance_id` 过滤。
- 每个面板固定倒序取最近少量 item，不做无限扩张。

### 3. 新增 observability 读取入口

- 新增 worker 侧 `run_context` 读取入口。
- 新增 control-plane 侧 `project_run_context` 代理入口。
- 错误语义与既有读取面保持一致。

### 4. 替换 `RunLive` 占位区

- 把 `Context surfaces` 静态占位文案换成真实 context summary 卡片。
- 保持 mount 后异步加载、轻量展示、独立失败态。
- 不影响 timeline / event detail 的既有交互。
- sub-agent 降级态文案必须明确是 unavailable / none observed，不能渲染成误导性的“暂无子 agent 活动”。

## 验证路线

- 定向跑相关 ExUnit：
  - `run_trace_test.exs`
  - `run_state_store_test.exs`
  - `extensions_test.exs`
- 必须额外覆盖：
  - partial degrade：context 失败不影响 summary / timeline / event detail
  - `404 run_not_found` / `409 duplicate_run` / `503 context_unavailable` 的 worker 与 control-plane 映射
  - recent window 跨 turn / retry 边界时，anchor 与摘要仍绑定当前 generation
- 收口前执行本地 `make all`，因为累计 diff 会命中 `elixir/**`。
- 代码变更完成后必须过一次零上下文 reviewer gate。

## 风险门

- 若实现过程中发现 sub-agent 线索在当前 trace 体系内无法稳定提取，则保留 `unavailable` 降级，不扩 scope 去改底层 trace 记录协议。
- 若 reviewer 指出 conversation 摘要与既有 summary humanization 口径冲突，只允许做一次 focused recheck，不能重开 broad exploration。
