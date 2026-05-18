# 0518aa 观察层合同风险流程改版

## 目标

把本轮已经确认的新流程意见沉淀成可 review、可 handoff、可继续改规则文件的稳定 change 快照。

本 change 的目标不是兼容旧的默认 `1+2` / `1+1` 叙述，而是明确给出新的顶级流程主轴，供后续修改 `AGENTS.md`、`elixir/WORKFLOW.md` 与治理模板时直接引用。

## 需求快照

### 要解决什么问题

- 现有流程把多 Agent 协作主轴绑在固定人数模板上，容易把“是否凑齐编制”误当成“是否覆盖关键职责”。
- 观察层语义、摘要口径、角色计数与多消费面一致性这类合同问题暴露过晚，经常拖到 heavy validation 之后才被发现。
- `closeout` 阶段缺少稳定顺序，合同检查、baseline 判断、重门禁和最终复核容易交错发生。
- blocker 在返工流转中容易变形，主线程、reviewer 和文档各记一套，导致真实阻塞项与误判项混杂。
- 角色边界不够硬，分析线程被复用成实现或复核线程时，容易形成事实上的自证与审计失真。

### 成功标准

- 顶级流程主轴从“默认固定 `1+2` / 例外 `1+1`”改为“按阶段要求角色”，至少明确：
  - `blue analyst`
  - `red analyst`
  - `implementer`
  - `contract checker`
  - `final zero-context reviewer`
- 命中观察层合同风险的任务，文档阶段必须在 frozen artifact 内附窄版 `contract matrix`，且不得另起平行文档。
- 命中观察层合同风险的代码任务，`closeout` 默认路径被固定为：
  - `implementer`
  - `contract checker`
  - `baseline lock`
  - `heavy validation`
  - `final zero-context reviewer`
  - `push / PR / merge`
- 新流程明确要求角色独立性，而不是只要求“线程名称不同”：
  - `implementer`、`contract checker`、`final zero-context reviewer` 不得由同一 agent 兼任。
- `blocker ledger` 被收敛为 Workpad 内的唯一活记录，不再允许 comment-only、PR-only、reviewer-only 的平行阻塞台账。
- 角色制具备明确的适用矩阵与降阶边界，至少覆盖：
  - 命中观察层合同风险的代码或流程合同变更
  - 未命中观察层合同风险的普通代码变更
  - 不改变流程合同的普通文档变更
- 最终汇报从“是否保持 `1+2`”改为：
  - 实际使用了哪些角色
  - 必需角色是否到位
  - 是否命中观察层合同风险
  - 是否启用 `contract checker`
  - 是否开启 `blocker ledger`
  - 共几轮返工
  - 是否存在 baseline 争议
  - 最终 validation 结果
  - 最终可放行结论

### 明确不做什么

- 不保留旧的“默认 `1+2`、例外 `1+1`”作为新规则主轴。
- 不把 `contract checker` 扩成第二个全量 code reviewer。
- 不把 `contract matrix` 扩成第二份设计文档、第二份规则表或实时台账。
- 不把 `blocker ledger` 扩成新的长期系统或第二套真相源。
- 不让 `heavy validation` 取代 `final zero-context reviewer` 的最终放行职责。

### 固定约束

- 本轮处于规则修改阶段；若仓库原有顶级规则与本 change 冲突，应以后续规则修改结果为准，不保留旧主轴作为并行制度。
- `## Codex Workpad` 仍是唯一活真相源；repo change 文档只沉淀稳定边界、字段语义、回退规则和验证预期，不记录运行中的实时值。
- `contract matrix` 只能作为 frozen artifact 的组成部分存在，不能演化成独立平行文档。
- 观察层合同风险必须是显式判定的流程开关，不能等到实现完成或 heavy validation 开始后再补贴标签。
- 任何涉及角色制的新条文，都必须同时定义角色独立性，不允许只定义角色名称。
- 任何涉及 `baseline lock`、`contract checker`、`heavy validation` 的顺序条文，都必须同时定义失效条件与回退规则。
- `frozen artifact`、`baseline lock`、`baseline 争议`、返工轮次都必须有统一口径与证据落点，不能在具体规则改写时再临场补定义。

## 主要风险

1. `观察层合同风险` 如果定义不够硬，会退化成执行层自由裁量口。
2. `contract checker` 如果不限定职责，会膨胀成第二个 reviewer，重新拉长 `closeout`。
3. `baseline lock` 如果不写清锁定对象和失效条件，会沦为口头状态。
4. “禁止线程内切换角色”如果不升级成独立性约束，会退化成多窗口自审。
5. 如果只写主路径、不写回退规则，`closeout` 会在第一次返工后重新混乱。

## 文档索引

- [10_design.md](./10_design.md)
- [20_plan.md](./20_plan.md)
