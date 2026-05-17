# C-53 流程收紧实施计划

**Goal:** 在不削弱现有质量护栏的前提下，把 `原始需求.md` 中关于文档阶段收紧、风险前移、reviewer 可执行裁决、返工分流和活状态板 schema 的要求，逐步收敛成仓库内一致的规则文本与模板。

**Architecture:** 先固化稳定 change 快照，再按“仓库执行规则 -> workflow 合同 -> 可复用治理层 -> closeout 验证”的顺序推进。本 change 已把目标态写入实施范围；后续以规则文件 diff 落地作为真正收口标准。

**Tech Stack:** Markdown, repo-local workflow contract, governance docs

---

## Phase 0: 固化 change 快照并校正遗留文档口径

**Files:**

- Create: `docs/changes/c-53-workflow-tightening/README.md`
- Create: `docs/changes/c-53-workflow-tightening/10_design.md`
- Create: `docs/changes/c-53-workflow-tightening/20_plan.md`

目标：

- 把 incident 目录中的真实需求迁移为稳定 change 快照。
- 明确哪些遗留文档内容可继承，哪些必须校正或丢弃。
- 把“当前现状 `1+3`”与“目标态 `1+2`”拆开写清，禁止再用混合时态表述。
- 在进入规则实现前，先把 repo 文档、Linear `## Codex Workpad` 和 GitHub/PR 事件流的边界写清。

## Phase 1: 收紧 repo 级执行规则

**Candidate Files:**

- Modify: `AGENTS.md`

目标：

- 补入本 change 的 repo 级摘要约束：
  - 实现阶段默认协作模式从 `1+3` 收紧为 `1+2`
  - `spec freeze`
  - 一次定点补查
  - typed/core/integration 条件触发式中途风险门
  - reviewer `Change Review + Push Readiness`
  - `## Codex Workpad` 作为活状态板与流程指标唯一真相源
  - 返工分流规则
- 删除“`1+2` 仅是最小硬要求计数口径”的旧表达，把目标态规则正式写进生效文本。

## Phase 2: 收紧 `elixir/WORKFLOW.md` 合同

**Candidate Files:**

- Modify: `elixir/WORKFLOW.md`
- Modify: `elixir/README.md`

目标：

- 把 document-phase gate 收紧为“固定输出 + `spec freeze` + 一次定点补查”。
- 在 review / closeout 路径中加入 `Push Readiness` 的输出要求与消费时点。
- 明确中途风险门的触发条件与前移 full gate 的使用边界。
- 细化返工分流，不再把所有未通过都笼统写成同一路 `Rework`。
- 只在高层说明中补充原则，不把完整 workflow 细节复制进 README。

## Phase 3: 同步可复用治理层，但不塞入仓库私有执行细节

**Candidate Files:**

- Modify: `docs/governance/文档分类规则.md`
- Modify: `docs/governance/可复用仓库文档标准.md`
- Modify: `docs/governance/验证分层规则.md`
- Modify: `docs/governance/templates/change/变更模板.md`
- Modify: `docs/governance/templates/仓库级/AGENTS模板.md`

目标：

- 只同步那些确实可复用的规则：
  - 稳定文档与事件流的边界
  - 活状态板只存在于 issue body / Workpad
  - 条件触发式中途风险验证与轻量路径并存
  - change 文档中的目标快照、非目标、固定约束写法
- 不把 PowerSymphony 私有执行细节错误塞进 `docs/governance/`。

## Phase 4: 验证、零上下文复核与收口

目标：

- 手工复核所有规则修改后，以下护栏仍保持成立：
  - `reproduce first`
  - 零上下文复核
  - closeout gate
  - latest head required checks
  - unresolved review delta
  - push 后立即 auto-merge 尝试的优先顺序
  - 小修小改轻量路径
- 复核是否产生新的多源真相。
- 对文档与规则变更完成一次零上下文 review。
- 若后续改动仍然是 docs-only，则按最轻验证收口；若触及 workflow 行为或契约测试，再补最小定向验证。

## Exit Criteria

后续真正进入规则实现前，应先确认：

1. 当前 change 快照已经被接受为后续实现依据。
2. `1+2` 已被明确写入实施范围，且对应规则文件不再残留“`1+2` 只是计数口径”或默认 `1+3` 的旧表达。
3. `Push Readiness` 的非 gate 定位已经在文档中被说清。
4. `## Codex Workpad` 作为唯一活真相源的边界已经被接受。
