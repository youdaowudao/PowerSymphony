# C-56 Coverage Policy Automation

## 目标

把长期 coverage policy 的第 4 步落成可执行、可复核、不会绕开现有 gate 的仓库内自动化校验。

这轮实现只做一件事：

> 在保持 `make all -> mix test --cover` 仍是总覆盖率真相源的前提下，新增一个仓库内 coverage policy 校验入口，用于检查 tier 门槛、diff coverage 和 `ignore_modules` 审计元数据，并把它接入现有 full gate。

## 需求快照

### 要解决什么问题

- 当前长期策略已经定义了总门槛、`Tier A/B/C`、diff coverage 和 `ignore_modules` 审计规则，但还没有仓库内自动化承载。
- 如果直接加一个独立 shell helper 或平行 CI job，很容易与 `make all`、`Next Push Gate`、`ignore_modules` 口径形成第二套 gate。
- 当前仓库需要一个能复用现有 `mix test --cover` 产物、并把 tier / diff coverage / ignore 审计显式化的校验入口。

### 成功标准

- 新增的 coverage policy 自动化不自己跑测试，而是消费现有 `mix test --cover` 产物。
- 总覆盖率仍由 `mix test --cover` 与 `mix.exs` 的 `test_coverage.summary.threshold` 决定。
- tier 门槛校验、diff coverage 校验、`ignore_modules` 审计元数据校验可以由仓库内命令直接执行。
- `make all` 走现有顺序，但在 coverage 之后增加该校验，而不是额外平行 gate。
- 本地与 CI 使用同一套阈值与 tier 配置来源。
- 当前立即硬门仅包含：`ignore_modules` 审计、`Tier A` 当前 baseline、diff coverage；`Tier B/C` 的 `97/95` 仍是长期目标，不在当前 task 里直接失败。
- 当前 `Tier A` baseline gate 只针对本次改动触达、且能映射到 changed lines 的 `Tier A` 模块；未触达的 `Tier A` 模块不会因本次 run 被硬失败。
- 本地 pre-push full gate 若走 `enforce` diff 模式，必须显式提供 `COVERAGE_POLICY_BASE_REF`；不得由 `Makefile` 默认猜测 `origin/main`。

### 明确不做什么

- 不引入新的外部 coverage 服务、第三方 SaaS 或独立平台。
- 不把 diff coverage 变成独立于 `make all` 的平行入口。
- 不改变 `Next Push Gate` 的选择逻辑。
- 不顺手重构现有测试结构、覆盖率统计方式或大量移除 `ignore_modules` 条目。

### 固定约束

- 现有 `mix test --cover` 输出必须继续作为总覆盖率真相源。
- 新自动化只能读取已有 coverage 产物，不能偷偷重跑另一套测试。
- 本轮必须在仓库内留一份机器可读的 tier / baseline / ignore 审计配置。
- 若实现需要依赖 PR base 分支信息，CI 与本地必须显式提供同一口径，不能靠隐式环境猜测。

## 风险判定结论

`已命中观察层合同风险`

命中原因：

- 存在聚合摘要，而非原样透传：模块覆盖率、diff coverage、审计结论都属于聚合结果。
- 存在计数、分类或归因口径：`Tier A/B/C`、diff coverage、ignore 审计都属于显式分类口径。
- 同一语义被多个消费面读取：本地 gate、CI、reviewer、文档都会读取同一套覆盖率策略语义。

## Source-of-Truth Chain

| 关键字段 / 语义 | 实际 source | 中间 projection | 最终 consumer |
|---|---|---|---|
| 仓库总覆盖率门槛 | `elixir/mix.exs` `test_coverage.summary.threshold` | `mix test --cover` 生成的 `cover/*.html` 与 summary | `make all`、CI、reviewer |
| Tier A/B/C 分类 | coverage policy 机器配置 | policy checker 对模块名 / 文件路径的 tier 判定 | policy checker、reviewer、长期文档 |
| Tier baseline / 最低门槛 | coverage policy 机器配置 | policy checker 对模块报告的阈值决策 | policy checker、reviewer |
| diff coverage 行集合 | `git diff` 相对 base ref 的新增 / 修改行 | policy checker 将 diff 行映射到 coverage 产物中的 hit / miss 行 | policy checker、CI、reviewer |
| ignore 审计元数据 | coverage policy 机器配置 | policy checker 将 `ignore_modules` 映射到审计记录 | policy checker、reviewer、后续策略维护者 |

## Contract Matrix

| field / view | source of truth | allowed transform | must not infer |
|---|---|---|---|
| repo total threshold | `mix.exs` `test_coverage.summary.threshold` | 读取数值并用于通过 / 失败判断 | 不得在 task / CI 脚本里再维护第二份总门槛 |
| tier classification | coverage policy 机器配置 | 由模块名 / 文件路径映射成 `A/B/C` | 不得从当次覆盖率高低反推 tier |
| module minimum | coverage policy 机器配置 | 当前 task 仅对 `Tier A` baseline 做硬失败比较，`Tier B/C` 目标值仅用于报告与后续收紧 | 不得根据文档描述或 reviewer 记忆临时推断最低门槛，也不得把 `Tier B/C` 长期目标提前升级为当前硬门 |
| diff coverage result | `git diff` + cover 产物 | 只统计可追踪、可映射到 coverage 行的新增 / 修改行 | 不得把未追踪或非可执行行当成 miss，也不得静默忽略无法解析的真正可执行行 |
| ignore audit view | `mix.exs` `ignore_modules` + coverage policy 机器配置 | 检查每个 ignored module 是否有审计元数据 | 不得把“已有 ignore 条目”自动视为已审计 |

## 实现方向冻结

主路径固定为：

- 新增一个仓库内 Mix task，执行 coverage policy 校验。
- 新增一个内部模块负责解析 cover 产物、读取 policy 配置、计算 diff coverage 与 ignore 审计。
- `make all` 在 `coverage` 之后接入该校验，使其成为原 full gate 的一部分，而不是平行 gate。
- 若 CI 需要 base ref 才能算 diff coverage，则在现有 workflow 中显式 fetch / 注入 base ref，不引入第二套 workflow。

不采用：

- 独立 shell helper 作为长期主入口
- 直接依赖第三方 diff coverage 服务
- 在文档里写策略，但让 reviewer 手工比对 cover HTML 代替自动化
