# C-53 单卡主线程流程收紧

## 目标

把 [docs/incidents/c-53-workflow-tightening/原始需求.md](../../incidents/c-53-workflow-tightening/原始需求.md) 中已经明确的流程收紧要求，迁移成一组可 review、可 handoff、可继续实现的稳定 change 快照。

本 change 已把目标态写入实施范围：后续需要同步修改仓库规则、workflow 合同、README 与治理模板，让仓库生效文本和本快照完全一致；incident 目录里的执行态草稿不再作为后续真相源。

## 需求快照

### 要解决什么问题

- 文档阶段前置探索过重，容易从受控分析漂移成广谱探索。
- typed/core/integration 风险发现过晚，问题经常拖到 closeout 或更后面才暴露。
- reviewer 输出不够可执行，主线程无法快速判断“现在能不能继续推进”。
- 返工回路缺少清晰分流，容易在实现、验证和需求边界之间来回空转。
- 活状态板与最小流程观测缺少统一 schema，长会话容易重复解释、上下文漂移。

### 成功标准

- 本 change 明确把“实现阶段默认协作模式收紧为 `1+2`”定义为目标态要求：
  - 主线程负责编排、收敛、验证与汇报
  - `1` 个实现子线程负责改动
  - `1` 个独立验证视角负责零上下文复核或窄门专项检查
  - `1+1` 仍只保留给“小修小改 / 强探索”例外
- 文档阶段的固定约束被写成稳定合同：
  - `Small change` 只允许 `1` 个分析子代理。
  - `Large change` 只允许 `2` 个分析子代理做轻量红蓝对抗。
  - `proceed` 后进入 `spec freeze`。
  - freeze 后禁止继续开广谱探索型子代理。
  - 只允许 `1` 次由 reviewer 明确触发的定点补查。
- typed/core/integration 风险前移被定义成条件触发的中途风险门，而不是所有任务默认重门禁。
- reviewer 固定输出 `Change Review` 与 `Push Readiness`，且 `Push Readiness` 只回答：
  - 现在能不能 push
  - 如果不能，push 前最小还缺什么
- 返工分流被写清：什么情况只回实现/验证，什么情况必须回轻量文档复核。
- `## Codex Workpad` 被定义为活状态板与最小流程观测字段的唯一真相源；repo change 文档只定义字段语义和边界，不镜像实时值。
- repo 文档、Linear issue body、GitHub/PR 事件流的边界被重新写清，不再混成多源真相。
- 以上收紧不会削弱现有质量护栏：
  - `reproduce first`
  - 零上下文复核
  - closeout gate
  - required checks / review delta / auto-merge 的既有收口顺序
  - 小修小改的轻量路径

### 明确不做什么

- 不引入强制切线程设计。
- 不新增 Linear 主状态，也不把 `Push Readiness` 升格成新的审批层。
- 不把 repo change 文档变成实时执行台账。
- 不把 typed/core/integration 风险表扩成所有 ticket 的默认重模板。
- 不把 change 快照本身当成规则已全部落地的替代物。

### 固定约束

- 本 change 已将实现阶段默认协作模式收紧为 `1+2`、`spec freeze`、一次定点补查、中途风险门、`Change Review` / `Push Readiness`、`## Codex Workpad` 唯一活真相源等目标态纳入实施范围。
- 这些目标态只有在 `AGENTS.md`、`WORKFLOW.md`、README 与治理模板的对应 diff 全部落地后，仓库生效文本才算完全消除现状/目标态冲突。
- 在规则文件 diff 落地完成前，任何中间稿都不得把未修改的旧文本当作新的稳定依据。
- `git push` 成功后的第一优先级 GitHub 动作仍然必须是立即尝试开启 auto-merge；不能因为引入 `Push Readiness` 而改变该顺序。
- 活的状态板和观测字段只能写在 Linear issue body 的 `## Codex Workpad`；repo 文档只定义 schema 与使用边界。
- 文档阶段收紧不能削弱 `reproduce first`、依赖边界识别和验证设计前置，也不能把高风险问题重新后移到 closeout。
- 小修小改仍允许保留轻量路径；本 change 不能把所有任务默认抬成高负担流程。

## 遗留文档评估

### 可直接继承的部分

- [docs/incidents/c-53-workflow-tightening/原始需求.md](../../incidents/c-53-workflow-tightening/原始需求.md)
  - 这是本次 change 的真实需求来源，应继续作为 incident 侧原始材料保留。

### 需要校正后再继承的部分

- 遗留文档想表达“实现阶段默认协作模式应收紧为 `1+2`”，这一目标保留。
- 但遗留文档把目标态 `1+2` 直接写成了当前已生效事实，这一点必须改写。
- 遗留计划把后续会修改的文件集直接当成既定实施范围；本 change 保留这些文件作为明确实施面，但要求在规则文件 diff 落地前持续标明“待对应文件改完才算生效”。
- 遗留文档有把 repo 文档、执行态台账和实施进度混写的倾向；迁移后需要只保留稳定合同，不保留实时值和轮询态细节。

### 不继续继承的部分

- `README旧.md`、`10_design旧.md`、`20_plan旧.md` 已完成评估，但不再作为现行真相源或持续引用入口。
- 任何把目标态 `1+2` 误写成“当前仓库已生效规则”的表述，一律废弃，不得迁入本 change。
- 任何把 `Push Readiness` 写成新的 gate、state、审批层或 merge 权限来源的表述，一律废弃。
- 任何把 repo 文档当作 `## Codex Workpad` 实时镜像、承载实时值或执行态进度的写法，一律废弃。
- 任何让 `spec freeze` 后继续广谱探索扩散的写法，一律废弃。
- 任何把 change 快照本身等同于“规则文件已经全部落地”的写法，一律废弃。

## 文档索引

- [10_design.md](./10_design.md)
- [20_plan.md](./20_plan.md)
- [90_verification.md](./90_verification.md)

## 关联材料

- Incident 目录入口：
  - [docs/incidents/c-53-workflow-tightening/原始需求.md](../../incidents/c-53-workflow-tightening/原始需求.md)
