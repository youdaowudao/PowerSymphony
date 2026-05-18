# 0518aa 观察层合同风险流程改版实施计划

**Goal:** 把新的角色制、观察层合同风险分流、合同前移检查、baseline 锁定、blocker ledger 与最终汇报口径，逐步改写成仓库内一致的规则文本与治理模板。

**Architecture:** 先固化 change 快照，再按“仓库执行规则 -> workflow 合同 -> 可复用治理层 -> closeout 验证”的顺序推进。所有规则修改都以本 change 定义的新主轴为准，不再保留旧人数主轴作为并行制度。

**Tech Stack:** Markdown, repo-local workflow contract, governance docs

---

## Phase 0: 固化 change 快照与硬边界

**Files:**

- Create: `docs/changes/0518aa/README.md`
- Create: `docs/changes/0518aa/10_design.md`
- Create: `docs/changes/0518aa/20_plan.md`

目标：

- 把这次已经确认的流程意见沉淀成稳定的 repo 文档快照。
- 明确这次不是“兼容旧规则”，而是“用新主轴替换旧主轴”。
- 先把五个最容易走样的边界钉死：
- 明确 `frozen artifact` 的承载位置、冻结时点与重冻规则。
- 明确角色适用矩阵，防止新角色制滑向默认全角色常开。
- `观察层合同风险`
- 角色独立性
- `contract checker` 失效条件
- `baseline lock` 失效条件
- `closeout` 回退规则

## Phase 1: 改写 repo 级执行规则

**Candidate Files:**

- Modify: `AGENTS.md`

目标：

- 删除旧的“默认固定 `1+2`、例外 `1+1`”主轴表述。
- 改写成新的阶段角色制主轴。
- 补入 `观察层合同风险` 的触发条件、判定时点、默认保守策略与争议记录要求。
- 补入 `frozen artifact`、`baseline 争议`、返工轮次与 baseline 记录协议的统一定义。
- 补入 `contract checker`、`baseline lock`、`blocker ledger`、最终汇报新口径。
- 把“禁止线程内切换角色”升级成“角色独立性硬约束”。

## Phase 2: 改写 `elixir/WORKFLOW.md` 合同

**Candidate Files:**

- Modify: `elixir/WORKFLOW.md`
- Modify: `elixir/README.md`

目标：

- 让 workflow 合同消费新的角色制，而不是旧人数模板。
- 在 document-phase 与 closeout 路径中补 `观察层合同风险` 的判定与消费时点。
- 加入 `contract checker -> baseline lock -> heavy validation -> final reviewer` 的默认主路径。
- 为 workflow 文本补齐失效与回退规则，防止顺序链在第一次返工后失真。
- 在高层说明中同步新主轴，但不把全部细节复制到 README。

## Phase 3: 同步可复用治理层

**Candidate Files:**

- Modify: `docs/governance/验证分层规则.md`
- Modify: `docs/governance/可复用仓库文档标准.md`
- Modify: `docs/governance/templates/change/变更模板.md`
- Modify: `docs/governance/templates/仓库级/AGENTS模板.md`

目标：

- 同步那些可复用、且不依赖 PowerSymphony 私有上下文的规则：
  - 风险驱动的角色覆盖优先于人数模板
  - frozen artifact 内可附窄版 `contract matrix`
  - 条件触发的合同检查与中途风险验证
  - `blocker ledger` 的最小审计字段
  - 最终汇报以角色到位性、独立性与放行性为主
- 不把仓库私有路径、GitHub 收口细节或 Linear 细节错误带入通用治理层。

## Phase 4: 文档级验证与零上下文复核

目标：

- 文档落点、链接和索引一致。
- 所有规则文本对 `观察层合同风险` 的定义一致。
- 所有规则文本对 `contract checker` 与 final reviewer 的职责边界一致。
- Workpad 单一真相源没有被破坏。
- 不再残留“是否保持 `1+2`”作为主汇报指标。
- 对文档改动本身完成一次零上下文 review。

## Exit Criteria

后续真正开始改规则文件前，应先确认：

1. 本 change 已被接受为新的顶级流程主轴快照。
2. 新主轴已经明确为“阶段角色制 + 角色独立性”，而不是旧人数模板。
3. `观察层合同风险`、`contract checker`、`baseline lock`、`blocker ledger`、最终汇报五组定义已经在文档中固定。
4. `closeout` 默认主路径与回退规则已经同时写清，不再只有主路径没有失效逻辑。
5. 后续规则文件 diff 的收口标准是“旧主轴退出生效文本”，而不是“新旧两套口径并存”。
