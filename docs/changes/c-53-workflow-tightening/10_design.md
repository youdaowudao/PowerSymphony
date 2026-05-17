# C-53 流程收紧设计

## Goal

把 incident 中关于“单卡单主线程如何减少编排开销、如何把高风险问题前移、如何让 reviewer 输出更可执行”的结论，收敛成当前仓库可继续实现的稳定合同。

本设计只负责定义边界、路由和字段语义，不在这一层直接宣称某条仓库规则已经改完。

## Confirmed Input

本设计以 [原始需求.md](../../incidents/c-53-workflow-tightening/原始需求.md) 给出的当前现实约束为输入，不重写问题定义：

- 当前默认仍是一张卡对应一个主线程。
- 文档阶段 review 规则已经锁定为：
  - 小修改 `1` 个分析子代理
  - 大修改 `2` 个分析子代理做轻量红蓝对抗
- 目标不是强制切线程，而是在现有现实里压缩流程损耗、把风险前移。
- 不能为了提效削弱完工质量。

## Legacy Assessment

### 1. `README旧.md` 可作为稳定入口骨架

它已经把目标、问题、成功标准和固定约束压成了适合迁移到 `docs/changes/` 的入口结构。

需要修正的核心点，是把旧的“当前默认仍是 `1+3`”现状约束，改写成这次实施必须主动消除的冲突源。

### 2. `10_design旧.md` 的大部分设计判断成立

下面这些判断与原始需求一致，可继续保留：

- `spec freeze`
- reviewer 触发的一次定点补查
- typed/core/integration 风险的条件触发式中途风险门
- reviewer 固定输出 `Change Review + Push Readiness`
- 返工分类路由
- `## Codex Workpad` 作为活状态板和最小观测字段的唯一真相源

需要修正的核心点只有一条：

- “实现阶段默认 `1+2`”这个目标本身需要保留，并且要继续推进到规则文件 diff 落地，不能停留在 change 口头目标。

### 3. `20_plan旧.md` 只适合作为后续实施顺序草案

它适合保留为“后续应该按什么顺序改动”的输入，但不应原封不动迁入稳定快照，原因有二：

- 它把多个待改文件直接写成既定执行范围，容易让读者误解为这些改动已经被本轮确认。
- 它把“文档迁移”与“规则实现”混在同一条执行线里；当前回合需要先把 change 文档独立收口。

## Design Decisions

### 1. 先收紧流程结构，不先改主状态机

本 change 的核心是流程结构收紧，而不是 runtime state machine 改造。

因此本轮设计首先固定：

- 卡片边界怎么定
- 文档阶段何时停止探索
- reviewer 应输出什么
- 风险何时前移
- 返工如何分流
- 哪些信息属于活真相源，哪些只属于稳定文档

不在本层直接引入：

- 新 Linear state
- 新审批层
- 强制切线程系统
- 重 UI / 重平台能力

### 2. 文档阶段收紧为“固定输出 + `spec freeze` + 一次定点补查”

文档阶段需要保留多视角，但必须严格限制探索扩散。

`proceed` 前，主线程至少要收敛出：

- 这次要交付的单一可独立验证行为变化是什么
- 验收边界是什么
- 明确不做什么
- 不会动什么
- 风险点落在哪里
- 验证准备怎么映射

`proceed` 后进入 `spec freeze`：

- freeze 后禁止继续开广谱探索型子代理
- 只允许 `1` 次由 reviewer 明确指出 blocker 或覆盖缺口后触发的定点补查
- 这次补查只能回答一个明确缺口，不能重新发散成第二轮广谱探索

### 3. 中途风险门只在高风险条件命中时触发

typed/core/integration 风险需要前移，但不能把所有任务默认抬成重门禁。

因此中途风险门只在命中下面任一条件时触发：

- 触达 BEAM / typed core path
- 触达 event normalization
- 触达 state machine / concurrency boundary
- reviewer 明确标记 type / integration risk
- 已经发生 `1` 次返工，且 diff 仍跨多个风险点

风险门的目标是：

- 提前暴露高风险问题
- 在必要时把 full gate 前移到 PR 前
- 避免把首次远端 full-gate 红灯继续当成主要发现器

风险门不意味着：

- 每张卡都默认重门禁
- 小修小改失去轻量路径

### 4. `Push Readiness` 是 reviewer 输出，不是新 gate

reviewer 固定输出两段：

- `Change Review`
- `Push Readiness`

`Push Readiness` 只回答两件事：

- 现在能不能 push
- 如果不能，push 前最小还缺什么

它不是：

- 新的 Linear state
- 新的 merge 权限来源
- required checks / unresolved review delta 的替代
- `git push` 后 auto-merge 顺序的前置挡板

它的价值只在于给主线程一个可执行裁决，减少“review 有发现，但不知道下一步怎么办”的空转。

### 5. 返工按原因分流，而不是一律打回文档阶段

返工至少分成以下几类：

- 实现缺陷
  - 回实现线程修复，再由原 reviewer 复审
- 验证缺口
  - 回实现线程补验证，再由原 reviewer 复审
- 需求边界变化
  - 回轻量文档复核，再恢复实现/验证
- review 误解或强观点冲突
  - 主线程收敛分歧，必要时触发 `1` 次定点补查
- 需要人工裁决
  - 立即停工，请求用户帮助

这样做的目的，是把“什么时候该继续实现、什么时候必须回规格边界”写成明确路由，而不是靠主线程临场猜。

### 6. `## Codex Workpad` 是唯一活真相源

repo change 文档只记录稳定合同，不记录实时值。

活的状态板和最小流程观测字段统一放在 Linear issue body 的 `## Codex Workpad`，并至少支持：

- `Status Board`
  - 当前阶段
  - 已完成 gate
  - 当前 blocker / 下一 gate
  - 当前 reviewer 结论
  - 返工次数
- `Flow Metrics`
  - `timeUsedSeconds`
  - `tokensUsed`
  - `subagent_count`
  - `rework_count`
  - `first_risk_detected_stage`
  - `full_gate_before_pr`

repo change 文档在这里的职责只有两个：

- 定义这些字段的语义和边界
- 解释为什么它们必须只保留一个活真相源

### 7. 实现阶段默认 `1+2` 已写入实施范围，需由规则文件 diff 消除旧口径

本 change 需要保留的，不是“`1+2` 这个说法本身”，而是它背后的目标态：

- 实现阶段默认协作模式收紧为 `1+2`
- `1+1` 仍只保留给“小修小改 / 强探索”例外
- 独立验证不能被删除，也不能再退化成“可选 reviewer”

本 change 已经把以下实施要求冻结下来：

- Phase 1 必须显式修改 `AGENTS.md`、`WORKFLOW.md` 与相关模板
- 默认实现协作模式必须改为 `1+2`
- `1+1` 仍只保留给“小修小改 / 强探索”例外
- 任何“`1+2` 只是计数口径”的旧表达都必须删除

因此这里不再把 `1+2` 只写成抽象目标，而是把它视为已确认的实施范围；真正的收口标准，是对应规则文件 diff 落地后，仓库内不再残留 `1+3` 旧口径。

这样既保留了原始需求里“不要堆无效代理，但不能删独立验证”的核心意图，也避免把目标态伪装成已经生效的现状。

## Walkthrough

一张高风险代码卡在这套设计下的标准路径应当是：

1. 主线程先按“单一可独立验证行为变化”定义卡片边界。
2. 文档阶段按 `Small change / Large change` 规则完成受控分析并进入 `spec freeze`。
3. 实现线程按 freeze 后的边界完成改动，主线程不再重新打开广谱探索。
4. reviewer 输出 `Change Review`；若已到 push 准备态，再补 `Push Readiness`。
5. 如果命中高风险条件，则在 closeout 前插入中途风险门，必要时把 full gate 前移到 PR 前。
6. 如果 reviewer 未通过，则按返工原因分流；只有需求边界真的改变时才回轻量文档复核。
7. 活的状态板和流程指标始终只更新在 `## Codex Workpad`，repo change 文档不复制实时值。

## Primary Risks

1. 把“按行为拆卡”执行成过度拆卡。
2. 把“风险门前移”执行成每张卡默认重门禁。
3. 把 `Push Readiness` 误写成新的审批层。
4. 把“一次定点补查”重新演化成 explorer 扩散。
5. 规则文件改到一半，导致仓库内同时残留新旧口径，形成新的冲突源。

## Verification Focus

后续进入实现阶段时，至少要验证以下几点：

1. 质量护栏没有被削弱。
2. 高风险问题能在 closeout 前更早暴露。
3. 文档阶段 agent 数量与停止条件被硬控制。
4. reviewer 输出能直接推动主线程决定下一步。
5. repo 文档没有演化成 `## Codex Workpad` 的实时镜像。
