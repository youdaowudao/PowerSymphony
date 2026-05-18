# C-54 实施计划

## 实施目标

在不重开 `C-44` 页面主结构、也不重写 `C-45` diff 合同的前提下，把 `IssueDiff` 的只读结果接到：

- continuation prompt
- run trace / context summary
- 深看页既有 `Context` 区块

同时把 `unchanged` 场景的 continuation 输入压缩成更短的只读增量文案。

## 任务拆分

### 任务 1：冻结 `issue_refresh` trace/context 合同

目标：

- 明确 `issue_refresh` event 由谁写、写什么 payload、缺失时如何降级。

涉及文件：

- `elixir/lib/symphony_elixir/agent_runner.ex`
- `elixir/lib/symphony_elixir/run_trace.ex`
- `elixir/lib/symphony_elixir_web/presenter.ex`
- `elixir/lib/symphony_elixir_web/live/run_live.ex`

要点：

- 只在 continuation 刷新点记录 event，不新增第二套 issue diff source。
- payload 直接复用 `IssueDiff.describe/2` 的结构化结果，避免 consumer 再次比较 issue。
- `RunTrace.context_summary/2` 只读取当前 generation 最新 `issue_refresh` event。
- 若没有 event，则输出 `none observed` / 等价空态，不推断 `unchanged`。

### 任务 2：先写失败测试，再补 `issue_refresh` trace 记录

目标：

- 证明 continuation 刷新后，trace/context summary 能拿到稳定的只读增量摘要。

优先测试文件：

- `elixir/test/symphony_elixir/run_trace_test.exs`
- `elixir/test/symphony_elixir/core_test.exs`

最小覆盖：

- 有 `issue_refresh` event 时，`RunTrace.context_summary/2` 输出 `status / observed_changes / notes`。
- 没有 `issue_refresh` event 时，不伪装成 `unchanged`。
- `AgentRunner` continuation 链会记录 `issue_refresh` event。

### 任务 3：补 `Presenter` 与 `RunLive` 的 Context 只读展示

目标：

- 在既有 `Context` 区块内部增加 `Issue Refresh` 子段落，不新增顶级区块。

优先测试文件：

- `elixir/test/symphony_elixir/extensions_test.exs`

最小覆盖：

- `changed` 时显示 status、变化列表和说明。
- `unchanged` 时显示短文案与 partial-observation 降级说明。
- `unavailable` 时显示明确降级，而不是正常 changed/unchanged 文案。
- `none observed` 时显示空态。
- 既有 Context / Timeline / Event Detail 行为不回退。

### 任务 4：压缩 continuation prompt 的 `unchanged` 文案

目标：

- 减少“无变化”场景下重复 token 搬运，同时保留 partial-observation 边界。

涉及文件：

- `elixir/lib/symphony_elixir/prompt_builder.ex`
- `elixir/test/symphony_elixir/core_test.exs`

要点：

- `changed` 仍以变化字段为主。
- `unchanged` 改为更短的增量文案，但必须保留：
  - partial observation
  - 未覆盖 comments / threads / body revisions
  - `updated_at` 单独变化不代表语义字段变化
- `unavailable` 继续明确暴露降级。

### 任务 5：本地验证与 closeout 证据

目标：

- 用最轻但充分的验证证明三条链路一致：
  - prompt
  - trace/context
  - deep view

建议验证顺序：

1. `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/run_trace_test.exs`
2. `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/core_test.exs`
3. `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/extensions_test.exs`
4. `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix format --check-formatted`
5. `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix lint`

如果准备 create/update PR，则本卡命中 `elixir/**`，最终 push 前需再跑：

6. `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- make all`

## 实现红线

- 不得新开 deep view 顶级区块。
- 不得在 consumer 层重新比较 issue 快照。
- 不得把缺失 `issue_refresh` source 的 generation 当成 `unchanged`。
- 不得新增 comments / threads / body revision 覆盖假象。
- 不得把只读增量结果转译成执行建议、状态迁移或自动写回行为。

