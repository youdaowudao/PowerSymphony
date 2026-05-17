# C-53 PR 收口前移实施计划

## 目标

把本仓库命中 full-gate 路径的 PR create/update push 收口模型，统一改成“PR create/update 前先本地 `make all`，通过后再 push”，并同步补齐执行入口、模板与 reviewer 输出锚点。

## 实施范围

本次需要改动的文件：

- 根规则：
  - `AGENTS.md`
- Elixir 子仓规则：
  - `elixir/AGENTS.md`
- GitHub 执行技能：
  - `.codex/skills/push/SKILL.md`
  - `.codex/skills/land/SKILL.md`
- 工作流与 issue body 模板：
  - `elixir/WORKFLOW.md`

## 计划原则

- 先改总规则，再改技能入口，最后改 workflow 模板，避免局部先行造成口径打架。
- 每个文件改完后都要做一次局部自检，确认：
  - full-gate 路径定义一致
  - PR create/update 前门槛定义一致
  - `make all` 的角色定性一致
  - `Next Push Gate` / `Push Readiness` 落点一致

## 任务拆分

### 任务 1：改根 `AGENTS.md`

目标：

- 删除“CI failed 后才升级到 `make all`”作为常规 PR 收口路径的表达
- 明确新制度下的单态门禁
- 保留开发阶段轻验证与本地资源安全红线

需要落下的结论：

- 日常开发阶段仍优先定向验证
- 普通开发分支默认视为 PR-bound；只要后续会 create/update PR，就按累计 diff 先决定 `Next Push Gate`
- 若同一 head 先按非 PR push 执行、后决定开 PR，则必须在 create PR 前补跑当前应有 gate
- 若准备 create/update PR，且更新后的当前分支 / PR head 相对 PR base 的累计 diff 命中 `.github/workflows/make-all.yml`、`elixir/**`、`AGENTS.md`、`SPEC.md`，必须先本地 `make all`
- 远端 full gate 保留，但改定性为最终复核器
- 新制度下首次远端 full-gate 红灯默认视为流程未执行到位
- PR create/update、review reply、comment 审计、merge 的默认唯一正常 GitHub 写路径是 `.codex/skills/github_api.py`
- 若发现关键 GitHub 写操作走了 GitHub UI、`gh`、ad-hoc CLI、其他 helper，且无授权/无 blocker 记录，则必须先记录 out-of-band write 审计，再重新确认 PR 状态、review delta、required checks，并按需重跑 gate
- 顺手把根 `AGENTS.md` 的 `1+1` / `1+2` / `1+3` 口径收敛成“默认 `1+3`，只有例外才可 `1+1`，`1+2` 仅是最小硬要求视角下的计数”这一致表述

### 任务 2：改 `elixir/AGENTS.md`

目标：

- 让 Elixir 子仓规则与根规则完全一致
- 避免继续保留 “Before opening/updating PR, run closeout gate” 的旧口径

需要落下的结论：

- PR create/update 前分流：
  - 命中 full-gate 路径 -> 本地 `make all`
  - 不命中 full-gate 路径 -> closeout gate
- 普通开发分支若后续会开 PR，同样按 PR-bound 规则处理，不能因为 PR 尚未存在而降级
- 若同一 head 先轻推、后开 PR，必须先补 gate 再 create PR
- `make all` 不再仅仅是“CI failed 后的最终确认”
- 对 docs-only、只读排查、Linear 分诊等场景继续保留轻验证
- 关键 GitHub 写旁路一旦被发现，必须先审计再继续 closeout/merge

### 任务 3：改 `push` skill

目标：

- 把门禁从“解释性建议”升级成“执行分支”

需要新增的逻辑结构：

- 判断本次 push 是否 create/update PR
- 判断当前分支是否已经因为后续要 create/update PR 而属于 PR-bound
- 判断更新后的累计 branch / PR diff 是否命中 full-gate 路径
- 根据结果选择：
  - `local make all`
  - `closeout gate`
  - `light validation`

需要同步修改的内容：

- 步骤说明
- commands 示例
- notes 中对门禁的解释
- 把 auto-merge 失败审计示例改成可直接执行的 `github_api.py issue-comment-create` 命令
- 增加 out-of-band write 违规后的停机、审计、重检、重跑 gate 补救步骤

### 任务 4：改 `land` skill

目标：

- 保证 CI 失败后的修复循环不会退回旧口径

需要落下的结论：

- 任何修复后的 branch update push，只要更新后的累计 branch / PR diff 相对 PR base 仍命中 full-gate 路径，再次 push 前就重新跑本地 `make all`
- `land` 依赖 `push` skill 的同一门禁，不允许保留单独的宽松说法
- review reply、merge、审计评论这些关键写操作继续只走 `.codex/skills/github_api.py`
- 若发现 out-of-band write，先停 closeout/merge，再审计、重检、按需重跑 gate

### 任务 5：改 `WORKFLOW.md`

目标：

- 把抽象原则写成更接近检查表的问题
- 给 Workpad 和 reviewer 输出补充显式收口锚点

需要修改的区域：

- 默认姿态与执行规则中的 push 前 validation 定义
- `Step 2` 里 “Before every git push attempt” 的要求
- `Checking` closeout 相关说明
- 末尾 issue body 模板

需要新增的模板字段：

- 在 `## Codex Workpad` 中新增：
  - `Next Push Gate: <local make all | closeout gate | light validation | None>`
- 在 `## Review Summary` 或紧邻 review 输出要求处新增：
  - `Implementation Review: <pass | revise | not required>`
  - `Implementation Review Notes: <实现后的零上下文 reviewer 结论>`
  - `Push Readiness: <ready | not ready>`
  - `Push Readiness Notes: <缺什么/为什么>`
- 并把实现后的零上下文 reviewer 明确串成 push 前硬节点，不能再只依赖文档阶段 analysis subagents
- 同时把 PR-bound 分支、同一 head 补 gate、以及 out-of-band write 补救路径都写进 workflow 问答式检查表

### 任务 6：二次讨论收敛

目标：

- 基于文档成稿与拟修改的规则，做一轮明确的二次讨论
- 把“完全同意”、“需要收窄表述”、“新增约束”三类结论再次压实

二次讨论至少要覆盖：

- 新制度下首次远端 full-gate 红灯的定性
- 普通开发分支默认 PR-bound 与“同一 head 先轻推、后开 PR”的补 gate 规则
- `Next Push Gate` 与 `Push Readiness` 的最终语义
- `Implementation Review` 字段和实现后 reviewer gate 的最终语义
- 主线程、reviewer、`push` skill、`land` skill 的职责边界
- `make all` 仍不是日常开发命令，而是 PR create/update 前的单态前置门
- `.codex/skills/github_api.py` 作为关键 GitHub 写操作默认唯一正常路径的边界
- out-of-band write 发现后的停机、审计、重检与重跑 gate 顺序

## 验证计划

本次文档与规则修改完成后，至少执行：

```bash
git diff -- AGENTS.md elixir/AGENTS.md .codex/skills/push/SKILL.md .codex/skills/land/SKILL.md elixir/WORKFLOW.md docs/changes/c-53-pr-full-gate-prepush
```

检查点：

- 不再出现“命中 full-gate 路径的 PR create/update push 第一次可不跑本地 make all”的旧口径
- full-gate 路径列表与“累计 diff 判定基线”在所有文件里一致
- `push` 与 `land` skill 中的门禁分支一致
- `WORKFLOW.md` 模板确实新增 `Implementation Review` / `Next Push Gate` / `Push Readiness`
- auto-merge 失败审计示例已改成 `github_api.py issue-comment-create`
- 关键 GitHub 写路径已收紧到 `.codex/skills/github_api.py`
- 已明确写出 out-of-band write 发现后的补救流程

如需进一步做文本一致性检索，再执行：

```bash
rg -n "closeout gate|make all|Next Push Gate|Push Readiness|CI failed" \
  AGENTS.md \
  elixir/AGENTS.md \
  .codex/skills/push/SKILL.md \
  .codex/skills/land/SKILL.md \
  elixir/WORKFLOW.md
```

## 交付标准

这次变更只有在以下条件都满足时才算完成：

- 变更文档完整，能让 reviewer 不依赖 Linear 理解目标、方案与计划
- 根规则、子仓规则、技能入口、workflow 模板四层文本一致
- `Next Push Gate` 与 `Push Readiness` 已成为明确的执行锚点
- 二次讨论结论已明确区分：
  - 完全同意的部分
  - 需要收窄措辞的部分
  - 仍需保留的边界与非目标
