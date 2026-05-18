# C-54 Agent Closeout Ownership

## 目标

收紧 agent 侧的任务识别、返工 ownership、closeout 前 closure check，以及最终汇报口径，修复已经暴露的 4 个失控点；本轮以 `AGENTS.md` 为主落点，只在 `elixir/WORKFLOW.md` 存在直接冲突时做最小对齐。

## 需求快照

### 要解决什么问题

- 小任务会被误判成普通实现，跨边界字段 / 投影链任务在未列清真实链路前直接进入实现。
- reviewer 在首次 `revise` 后没有稳定 ownership，返工链容易变成重新自由扫 diff。
- full gate 被迫承担 query / projection / consumer surface 的主要 discovery，而不是只做最终复核。
- 最终汇报默认产出派生审计叙事，容易出现 agent 数、返工次数等压缩失真，而不是保留 transcript 可追溯的原始索引。

### 成功标准

- `AGENTS.md` 明确规定：命中跨边界字段 / 透传 / 多层 consumer 任务时，必须先列 `source -> projection -> consumer` 小链路；链路列不出来不得进入实现。
- `AGENTS.md` 明确规定：首次 `Change Review = revise` 后默认锁定原 reviewer 继续复审；换 reviewer 必须满足例外条件并附最小 handoff。
- `AGENTS.md` 明确规定：命中多层 consumer / contract 风险任务时，进入 closeout / push readiness 前必须完成 `closure check`，确认 `source / projection / consumer / verification` 四项对齐。
- `AGENTS.md` 最终汇报默认只要求原始索引，移除执行线程对 agent 数、返工次数、二次维修统计、耗时估算等派生审计数据的默认汇报职责。
- `AGENTS.md` 明确规定：`source-of-truth chain` 默认记录在当前 run 已要求的载体中；只有当前 run 本来就需要 `frozen artifact` 时，才在该 artifact 中引用或概述，不因 chain 单独新增 repo 文档门禁。
- `AGENTS.md` 明确规定：`reviewer ownership` 绑定到当前 `blocker id` 与角色类型，不覆盖既有二次维修停线规则，也不把 `contract checker` 与 `final zero-context reviewer` 混成同一复审角色。
- `AGENTS.md` 与 `elixir/WORKFLOW.md` 都明确规定：`closure check` 只是进入 `Push Readiness` 前的有界对齐证明，不是新的 `Next Push Gate`、不是新的 review state，也不要求额外重跑 full gate。
- `elixir/WORKFLOW.md` 若存在与上述规则直接冲突的 agent 行为描述，完成最小同步，避免同仓规则互相打架。

### 明确不做什么

- 不重写整个 `elixir/WORKFLOW.md`，不扩展新的大流程层级。
- 不把所有任务都升级成链路表、closure check 或更重 review。
- 不引入新的长期台账、固定 repo 模板、固定落盘文件名或额外审批层。
- 不改变现有 `观察层合同风险` 的命中定义，也不新增新的 checker 角色。

### 固定约束

- 本轮优先改 agent 侧约束，触发条件必须写成可识别任务特征，不能使用“复杂任务”“高风险任务”这类泛词。
- `source-of-truth chain` 是实现前的小检查动作；可写在 workpad、任务包或子 agent 指令里，但不要求默认新建 repo 文档。
- `closure check` 只适用于命中多层 consumer / contract 风险的任务，不替代 `make all`、code review 或 full gate。
- `source-of-truth chain` 不单独触发 `docs/changes/<change-id>/README.md` 新建要求；若当前 run 已命中必须冻结 `frozen artifact`，可在 artifact 中引用或概述该链路，否则沿用 `## Codex Workpad`、任务包或子 agent 指令等现有载体。
- `reviewer ownership` 只约束同一 `blocker id` 的后续复审 owner；若 `blocker id` 被替换、原 reviewer 不可用，或已触发二次维修停线，则允许换 reviewer，但必须附最小 handoff。
- `closure check` 只提供 `source / projection / consumer / verification` 四项对齐证据，不新增 gate 枚举、不新增审批层，也不替代 `contract checker` 与 `final zero-context reviewer` 的职责边界。
- 默认保留现有角色独立性、返工最小回退和 `Push Readiness` 口径。
- 执行线程仍保留 transcript、PR、commit、branch 等原始证据；派生审计数据交给后置 review workflow，而不是在最终汇报里手工压缩。

## 风险判定结论

- 已命中 `观察层合同风险`。
- 命中依据：
  - 同一语义会被多个消费面读取：主 agent、implementer、reviewer、closeout / push readiness。
  - 涉及字段来源、projection、consumer、验证点之间的跨消费面语义一致性。
  - 涉及 reviewer findings、ownership、handoff 与最终汇报索引的口径收紧。

## contract matrix

| field / view | source of truth | allowed transform | must not infer |
| --- | --- | --- | --- |
| 跨边界任务触发条件 | `AGENTS.md` 中可识别特征列表 | 可按“字段来源 / 透传 / 多层 consumer / 多层投影链 / 既有状态语义复用”归并成规则条目 | 不得把“复杂”“高风险”“看起来像展示任务”当成替代触发条件 |
| source-of-truth chain | 实现前的 workpad / 任务包 / 子 agent 指令 | 允许压缩成四列小表：关键字段、实际 source、中间 projection、最终 consumer | 不得要求所有任务固定落盘、固定模板或冗长文档 |
| reviewer ownership | 首次给出 findings 的原 reviewer 线程 | 允许在明确例外下交接，并附最小 handoff | 不得把返工默认视为重开一轮全量 review |
| closure check | 命中多层 consumer / contract 风险任务的 closeout 前检查 | 仅检查 `source / projection / consumer / verification` 四项对齐 | 不得把 closure check 等同于 full gate、额外审批层或全量验证重跑 |
| 最终汇报默认项 | transcript、main session、PR / commit / branch、当前状态 | 允许保留原始索引链接或标识 | 不得要求执行线程默认生成人数、返工次数、二次维修、耗时等派生审计统计 |

## 受影响文件

- `AGENTS.md`
- `elixir/WORKFLOW.md`（仅当存在直接冲突时最小对齐）
