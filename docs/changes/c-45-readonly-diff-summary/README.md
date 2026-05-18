# C-45 差分检测与只读变化摘要

## 目标

在现有 agent 连续执行链路里，为“同一 issue 在继续执行前先刷新 Linear 状态”补上第一版稳定、只读的变化摘要，让后续执行面和 prompt 接线可以回答：

- 这次刷新后是否真的有变化。
- 变化发生在哪些已接入的关键字段上。
- 哪些变化只是可观察事实，哪些值得后续 consumer 继续关注。
- 没有变化时，后续 consumer 可以短路，不必把整张卡重新当成全量新上下文。

## 需求快照

### 要解决什么问题

- 当前 `AgentRunner` 在正常 turn 结束后会刷新一次 Linear issue，再决定是否继续执行。
- 刷新后的结果目前只用于“是否继续跑”这种状态判断，没有稳定的“变化摘要”合同。
- 结果是后续 consumer 只能看到一份新的 issue 快照，无法区分“真正变了什么”和“只是又拉了一遍同样的内容”。
- 这会让后续只读增量上下文接线难以稳定复用，也会让“无变化短路”只能停留在口头约定。

### 成功标准

- 系统能对同一 issue 的前后两份快照做稳定的只读 diff。
- 当快照没有关键字段变化时，能返回明确的 `issue_snapshot_unchanged` 或等价局部结论，而不是把整张 ticket 宣称为“无变化”。
- 当快照有变化时，能返回结构化摘要，且顶层结论必须明确它只覆盖当前已观测的 issue 快照字段，至少覆盖第一版已接入字段：
  - `title`
  - `description`
  - `state`
  - `priority`
  - `assignee`
  - `labels`
  - `blocked_by`
  - `updated_at`
- 摘要必须区分“字段变化事实”与“只读关注结论”，而不是把所有变化压成单个字符串。
- 摘要必须同时暴露“当前只覆盖 issue snapshot”的观察范围，并对未观测对象给出显式降级语义，而不是沉默缺席。
- 第一版摘要可以被 continuation / 后续增量上下文 consumer 稳定读取，而不要求改写现有 deep-view 或 run summary 合同。

### 明确不做什么

- 不在本卡新增新的 Linear 写操作。
- 不在本卡改造 deep-view UI、run timeline、run summary 首屏合同。
- 不在本卡做完整评论流、thread 正文或历史 body 版本浏览器。
- 不做执行建议、自动继续、自动 reroute 或新的状态迁移逻辑。
- 不把“Checking / review delta / PR delta”混入这张卡的字段 diff 合同。

### 固定约束

- 第一版 source 仅允许来自当前已拉取的 `SymphonyElixir.Linear.Issue` 快照，或为满足本卡而在同一抓取链路中做的最小增量扩展。
- 若某类目标对象当前没有稳定 source，就必须显式降级为 `unavailable` / `not_yet_observed` / `out_of_scope_in_v1`，不能伪造“无变化”。
- 变化摘要是只读投影，不得反向承担调度、状态推进或写回职责。
- 变化摘要必须能在“前一快照 -> 中间 projection -> 最终 consumer”链路中清楚定位来源，不允许在 consumer 层二次猜测。
- `updated_at` 的变化不得被解释成“已知字段一定变化”；它只能作为补充观测信号，并允许指向“可能存在当前 v1 未覆盖对象变化”。
- repo 文档只冻结稳定边界与合同；实时执行状态、baseline、blocker 仍只留在 Linear `## Codex Workpad`。

## 风险判定

- 本卡已命中 `观察层合同风险`。
- 命中理由：
  - 存在聚合摘要，而非原样透传。
  - 存在字段级变化计数、分类与归因口径。
  - 同一语义预期会被多个 consumer surface 读取。

## 任务类型识别

- 类型：普通代码变更，但命中观察层合同风险。
- 当前冻结路径要求：
  - `blue analyst`
  - `red analyst`
  - `implementer`
  - `contract checker`
  - `final zero-context reviewer`

## Source-of-Truth Chain

| 关键字段 / 语义 | 实际 source | 中间 projection | 最终 consumer |
| --- | --- | --- | --- |
| issue 当前字段快照 | `Linear.Client` 拉取并归一化后的 `%Linear.Issue{}` | `IssueDiff` / read-only change summary | continuation prompt 或后续增量上下文 consumer |
| 是否真的发生变化 | 前一轮 issue 快照 + 本轮刷新后的 issue 快照 | diff classifier (`changed` / `unchanged` / `unavailable`) | continuation gate 后的只读上下文消费面 |
| 变化字段列表 | `%Linear.Issue{}` 中第一版已接入字段 | field-level diff entries | 摘要渲染层 / prompt 接线层 |
| 只读关注结论 | field-level diff entries | summary presenter / formatter | prompt 或后续只读 context wiring |

若实现期发现 comment / thread / body 子对象没有稳定 source-of-truth，则不得直接把它们并入第一版稳定合同。

## Contract Matrix

| field / view | source of truth | allowed transform | must not infer |
| --- | --- | --- | --- |
| `issue_snapshot_changed` / `issue_snapshot_unchanged` 结论 | 前后两份 `%Linear.Issue{}` 对比结果 | 仅可按字段等值 / 规范化集合比较得出 | 不得把它解释成整张 ticket 全量变化结论；不得从 `updated_at` 单独推断具体字段一定变化 |
| `field_changes[]` | `%Linear.Issue{}` 已接入字段 | 可转成稳定字段名、前后值、变化类型 | 不得输出未接入字段的伪变化 |
| `attention` / “值得继续看” | 已确认变化的字段集合 | 只可做只读分类与文案压缩 | 不得生成执行建议、状态推进建议或评论建议 |
| `comment changes` / `thread changes` / `body revision changes` | 仅当本卡实现中新增稳定 source 后才允许 | 若未接入则必须显式降级为 `not_yet_observed` / `out_of_scope_in_v1` | 不得把缺失 source 解释成“无相关变化” |

## 当前实现判断

- `AgentRunner` 已经持有“上一轮 issue 快照”和“刷新后的新快照”，这是最小可行 diff 锚点。
- 当前 continuation prompt 只输出泛化 guidance，没有任何 refresh diff 信息。
- `Linear.Client` 目前稳定拉取的字段已经覆盖 `title`、`description`、`priority`、`state`、`assignee`、`labels`、`blocked_by`、`updated_at`，足够支撑第一版 issue-level diff。
- 当前没有稳定评论流或 thread 子对象进入 `%Linear.Issue{}`；因此 card 文案里提到的 comment / thread 目标，在第一版只能显式降级，而不能假装已支持。

## 第一版实现结论

- 第一版先冻结为“issue 快照字段 diff + 只读变化摘要”。
- 第一版顶层结论必须明确是“部分观测结论”，不能复用会被误读为 ticket 全量结论的宽口径命名。
- 不把 comment / thread 变化并入稳定合同，除非实现期明确把它们接入同一 source 链并补齐测试。
- 第一版 consumer 以 continuation prompt 为最小落点；后续更广的只读增量上下文接线由后继卡消费该合同。

## 验证锚点

- 单元测试覆盖：
  - 无变化时返回 `unchanged`。
  - `title` / `description` / `state` / `labels` / `blocked_by` 等关键字段变化时能稳定分类。
  - 缺失或不可比较字段时走明确降级，而不是伪装成无变化。
- `AgentRunner` / prompt 级测试覆盖：
  - continuation turn 读取刷新后的只读变化摘要。
  - 无变化时 continuation 文本不会伪造变化，也不会把结果表述成“ticket 全量无变化”。
  - 有变化时 continuation 文本只呈现已接入字段的只读摘要，不重述整个原始 ticket。
  - continuation 文本会明确声明当前摘要不覆盖 comments / threads / body revisions 等未观测对象。
