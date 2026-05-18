# C-54 只读增量上下文接线与关注成本优化收口

## 目标

把 `C-45 / M4-7A` 已经落地的 issue 快照只读差分结果，稳定接到两条既有只读消费链里：

- continuation prompt
- `C-44` 深看页既有 `Context` 区块

本 change 的目标不是重写“什么算变化”，而是把已有只读差分事实变成可复用的第一版只读增量上下文包，并在“无变化”场景下压缩重复上下文搬运与重复 token 成本。

## 需求快照

### 要解决什么问题

- `C-45` 已经让 `AgentRunner` 能基于前后两份 `%SymphonyElixir.Linear.Issue{}` 快照生成只读 diff，但当前稳定 consumer 仍只有 continuation prompt 文本。
- continuation prompt 现在直接内联完整多行 diff 文本；即使“无变化”，也会重复带上整段观察范围与说明文案。
- `C-44` 深看页的 `Context` 区块目前只能看到 thread / conversation / continuation / tools / shell / sub-agent，只读差分结果没有被接进这个既有消费面。
- 结果是：
  - 人类无法在既有深看页里直接复核“上一轮刷新到底变了什么”。
  - continuation 链虽然已接到差分结果，但没有共享的只读增量上下文包，`无变化` 路径也还没有被压缩成更便宜的输入。

### 成功标准

- continuation prompt 与深看页 `Context` 区块共享同一份第一版只读增量上下文语义，而不是两边各自猜测。
- `AgentRunner` 在 continuation 刷新点生成稳定的只读 `issue_refresh` 摘要，并写入现有 run trace / context summary 链路。
- `RunTrace.context_summary/2`、`Presenter.run_context_payload/1` 与 `RunLive` 能在不重开 `C-44` 页面主结构的前提下展示该只读增量结果。
- `无变化` 场景下 continuation prompt 使用更短的只读增量文案，而不是每轮重复搬运完整多行 diff 说明。
- `有变化` 场景下 continuation prompt 与深看页都优先复用 `IssueDiff` 的现有结果，而不是回退到整张 ticket 的全量重述。
- 全链路保持只读：
  - 不产出执行建议
  - 不自动判断 rework
  - 不自动迁移状态
  - 不自动写回 Linear

### 明确不做什么

- 不重开 `C-44` 的页面区块、折叠策略、Timeline 过滤或 Event Detail 结构。
- 不改 `C-43` 的 attention 语义、排序规则或面板结构。
- 不重写 `C-45` 的字段 diff 规则、source 选择或未观测对象降级语义。
- 不把 comments / threads / body revision history 并入第一版稳定合同。
- 不把 `issue_refresh` 结果升级成调度建议、状态判断、依赖推断或自动重跑信号。

### 固定约束

- 差分 source 只允许来自 `AgentRunner` continuation 决策时同时持有的前后两份 `%SymphonyElixir.Linear.Issue{}` 快照。
- 深看页新增消费只能落在既有 `Context` 区块内部，不允许新开顶级页面区块。
- `issue_refresh` 必须沿用 `C-45` 的“partial observation only”边界；未观测对象必须继续显式降级，不能伪装成“无变化”。
- `issue_refresh` trace event 的 payload 必须优先直接承载 `IssueDiff.describe/2` 的结构化结果，至少稳定包含：
  - `status`
  - `status_text`
  - `observed_changes`
  - `updated_at_changed?`
  - `notes`
- continuation prompt 与深看页展示都必须复用同一条 `source -> projection -> consumer` 链，而不是一边看 trace、一边重新比较 issue。
- 若某次 run / generation 没有稳定 `issue_refresh` source，Context 只能显示 `none observed` 或等价降级，不得反推“没有变化”。
- `none observed` 的判定固定为：当前 generation 内不存在 `issue_refresh` event 时统一展示 `none observed`；只有存在 `issue_refresh` event 且其 `status == issue_snapshot_unavailable` 时，才展示 `unavailable`。

## 风险判定

### 任务类型识别

- 类型：普通代码变更，但命中观察层合同风险。
- 原因：
  - 存在只读聚合摘要，而非原样透传。
  - 同一差分语义会同时被 continuation prompt 与深看页 `Context` 两个 consumer 读取。
  - 存在字段变化列表、变化计数和降级说明的展示压缩。

### 讨论级别

- 我判断这轮属于 `Level 3`。
- 建议方法：轻量红蓝对抗。
- 原因：实现范围不大，但 source-of-truth、partial observation、无变化压缩和多 consumer 一致性都需要独立反向挑战。

## Source-of-Truth Chain

| 关键字段 / 语义 | 实际 source | 中间 projection | 最终 consumer |
| --- | --- | --- | --- |
| `issue_refresh.status` / `issue_refresh.notes` / `issue_refresh.observed_changes` | `AgentRunner` continuation 刷新点持有的前后 `%Linear.Issue{}` 快照 | `IssueDiff.describe/2` -> trace `issue_refresh` payload -> `RunTrace.context_summary/2` -> `Presenter.run_context_payload/1` | `RunLive` 既有 `Context` 区块 |
| continuation 的只读增量输入 | 同一对前后 `%Linear.Issue{}` 快照 | `IssueDiff.describe/2` -> `PromptBuilder` 的 continuation diff renderer | continuation prompt |
| “无变化时是否只需短文案” | `IssueDiff.describe/2` 的 `status` / `notes` | prompt renderer 的 compact path | continuation prompt |

若后续发现某些 consumer 想读取 comments / threads / body revisions，则必须先补稳定 source，再重开合同，而不是在本卡里推断。

## Contract Matrix

| field / view | source of truth | allowed transform | must not infer |
| --- | --- | --- | --- |
| `context.issue_refresh.status` | `IssueDiff.describe/2` 的顶层结论 | 可映射成稳定字符串、只读 label 或空态 copy | 不得把 `issue_snapshot_unchanged` 解释成整张 ticket 全量无变化 |
| `context.issue_refresh.observed_changes[]` | `IssueDiff.describe/2` 的 `observed_changes` | 可按现有 bullet text 展示、可显示 count | 不得伪造未观测字段变化；不得泄露完整 description/body 正文 |
| `context.issue_refresh.notes[]` | `IssueDiff.describe/2` 的 `notes` | 可压缩为只读说明文案 | 不得转译为执行建议、状态推进建议或 rework 建议 |
| `context.issue_refresh.none_observed` 空态 | 当前 generation 内不存在 `issue_refresh` trace event | 可显示固定 `none observed` 文案 | 不得把“没有 event”解释成 `unchanged` 或“ticket 没变化” |
| continuation prompt 的增量 diff 文案 | `IssueDiff.describe/2` | 可按 `changed / unchanged / unavailable` 走不同长度的只读模板 | 不得回退成整张 ticket 全量重述；不得声称 comments / threads 已比较 |

## 当前实现判断

- `IssueDiff.describe/2` 已经是稳定 source，且已经正确处理：
  - `unchanged`
  - `changed`
  - `unavailable`
  - description 文本摘要脱敏
  - `updated_at` 仅作为补充观测信号
- `PromptBuilder.build_continuation_prompt/4` 已经消费 `IssueDiff`，但仍直接嵌入完整多行文本，`无变化` 路径偏啰嗦。
- `RunTrace.context_summary/2` 当前只输出：
  - `anchor`
  - `conversation`
  - `continuation`
  - `tools`
  - `shell`
  - `subagents`
- `RunLive` 的 `Context` 区块已有稳定展示壳，因此最小改动路径是：
  - 给 context payload 增加 `issue_refresh`
  - 在既有 `Context` 区块内部增加一个只读子段落
  - 不改页面主区块结构

## 设计结论

本卡采用“共享同一份 `IssueDiff` 投影，同时接 continuation prompt 与 Context 区块”的方案：

- 在 `AgentRunner` continuation 刷新点记录一个只读 `issue_refresh` trace event。
- `RunTrace.context_summary/2` 读取当前 generation 最新的 `issue_refresh` event，形成第一版只读增量上下文包。
- `Presenter.run_context_payload/1` 暴露 `issue_refresh` 字段。
- `RunLive` 在既有 `Context` 区块内部增加 `Issue Refresh` 子段落，显示：
  - status
  - observed changes
  - notes
- `PromptBuilder` 保留 `IssueDiff` 作为 source，但把 continuation 文案改成按状态分支的紧凑版本：
  - `unchanged`：短文案 + 必要降级说明
  - `changed`：变化字段优先
  - `unavailable`：明确降级，不伪装成正常 changed/unchanged

## 验证锚点

- `IssueDiff` / `PromptBuilder` 测试覆盖：
  - `unchanged` 时 continuation prompt 使用更短的只读增量文案。
  - `changed` 时 continuation prompt 仍只展示已观测字段变化。
  - `unavailable` 时 continuation prompt 明确暴露降级。
- `RunTrace` / `RunStateStore` 测试覆盖：
  - `issue_refresh` event 能进入 context summary。
  - 缺少 `issue_refresh` event 时走显式空态，不伪造无变化。
- `Presenter` / `RunLive` 测试覆盖：
  - Context 区块在既有结构内展示 `Issue Refresh`。
  - `unchanged` / `changed` / `unavailable` / `none observed` 都有稳定只读文案。
  - 既有 `Context`、`Timeline`、`Event Detail` 行为不回退。
