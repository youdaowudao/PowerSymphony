# C-53 PR 收口前移设计

## 设计目标

这次改造不是单纯把一句“建议跑 `make all`”换个位置，而是把收口模型从“双态切换”改成“单态硬门”：

- 旧模型：
  - 开发与命中 full-gate 路径的 PR create/update push 前默认走 `closeout gate`
  - CI 失败后再升级到本地 `make all`
- 新模型：
  - 日常开发阶段仍优先轻验证
  - 一旦进入“准备 create PR / update open PR”的 push 场景，并且命中 full-gate 路径，直接切到本地 `make all`

核心裁决是：既然旧模型最大的问题是执行者容易漏掉“升级到 full gate”的切换点，那就删除这个切换点。

## 现状确认

### 1. 当前仓库明确存在双态门禁

根 `AGENTS.md` 与 `elixir/AGENTS.md` 当前同时表达了这些事实：

- 开发阶段先看 `git diff`，优先最轻验证。
- PR create/update 前跑 `closeout gate`，包含格式检查、lint、定向测试。
- `make all` 不是默认开发命令，只用于重大修复、高风险改动或 CI 已失败后的最终确认。

这说明“第一次 PR push 不跑本地 `make all`”不是偶然执行失误，而是被当前制度允许的行为。

### 2. 远端 full gate 在命中路径上恒定存在

`.github/workflows/make-all.yml` 会在以下路径命中时，对 PR 执行完整 `make all`：

- `.github/workflows/make-all.yml`
- `elixir/**`
- `AGENTS.md`
- `SPEC.md`

因此，只要本地不先跑 `make all`，第一次远端 CI 天然就是 full-gate 的第一发现点。

### 3. 执行入口没有把 full gate 写成硬门

当前 repo-local `push` skill 只写“PR create/update 前跑 `AGENTS.md` 要求的 closeout gate”，没有在命中 full-gate 路径时切换到本地 `make all`。

`land` skill 也只说“确认 required local validation green”，并在 checks fail 后走 fix -> commit -> push 的循环，没有把“再次 push 前重新跑本地 full gate”写死。

另外，只要门禁文字仍写成 `current diff` / `the diff hits`，执行者就仍可能把 open PR update 错降成“只看本轮小补丁”的 closeout gate。基线必须改成更新后的累计 branch / PR diff。

还存在另一条绕过路径：

- 先把分支当普通开发分支 push 出去，只做 light validation
- 等到同一 head 准备用来开 PR 时，再把它包装成“现在才进入 PR closeout”

如果规则没有明确“普通开发分支默认 PR-bound”，那么“先推分支、后开 PR”就仍然可以绕开应有的 `Next Push Gate`。

### 4. 执行记录与 reviewer 输出缺少显式收口锚点

`WORKFLOW.md` 当前模板只要求：

- `## Execution Brief`
- `## Acceptance Criteria`
- `## Review Summary`
- `## Blockers`
- `## Codex Workpad`

其中 `Codex Workpad` 只有 `Plan / Validation / Notes / Confusions`，没有显式的：

- `Next Push Gate`
- `Push Readiness`

review 相关字段也聚焦于 review delta，而不是“当前是否允许再次 push”。

## 问题归因

### 1. 最大故障不是 gate 本身，而是 gate 切换点

coverage、dialyzer、格式、lint 都只是 `make all` 里的不同层。当前反复维修的问题，不是“某一层过于难修”，而是：

- 执行者先做最小修复
- 只盯当前远端暴露的第一个红灯
- 推完后再等远端暴露下一个红灯

只要门禁定义允许“第一次先不跑 full gate”，这种行为就不是例外，而是制度鼓励下的稳定产物。

### 2. 角色并非不存在，而是职责没被硬化

主线程当前已经承担“最终验证”职责；review 流程也要求处理 validation、review delta、closeout pass。

但这些要求没有被压缩成一个明确的 yes/no 裁决：

- 这次 push 是不是 PR create/update？
- 是否命中 full-gate 路径？
- 本地 `make all` 是否已完成并通过？
- 如果没有通过，是否禁止 push？

所以问题不是“完全没人负责”，而是“负责者没有被强制在固定节点给出明确裁决”。

### 3. 现有 Workpad 只记录过程，不锚定门槛

`Codex Workpad` 现在能记录做了什么，但不能强迫执行者在 push 前回答：

- 这次 push 前的门到底是什么？
- 现在是否已经满足这个门？

所以它更像日志，不像闸门。

## 新制度

## 1. 收口门禁改成单态规则

### 规则定义

只要同时满足以下条件：

- 有代码改动或命中 full-gate 路径的规则改动
- 本次操作准备创建 PR，或者更新一个 open PR
- diff 命中 `.github/workflows/make-all.yml`、`elixir/**`、`AGENTS.md`、`SPEC.md`

则在任何 `git push` 之前，必须先本地执行：

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=<1|2|4> mise exec -- make all
```

并且只有在该命令通过后，才允许 push。

这里的 full-gate 判定基线统一为：

- 首开 PR：当前分支相对预计 PR base（默认 `origin/main`）的累计 diff
- open PR update：更新后的当前分支 / PR head 相对 PR base 的累计 diff
- planned PR create on same head：若先前同一 head 曾按非 PR push 执行，后来决定用它 create PR，则必须先补跑当前应有的 `Next Push Gate`

换句话说，open PR update 不能只看“这次还没 push 的小补丁”。

同时新增一条更硬的边界：

- 普通开发分支默认视为 PR-bound
- 只要当前分支后续会用于 create PR / update PR，就必须按上面的累计 diff 先选择 `Next Push Gate`
- 不能把“PR 还没创建”当成继续走 `light validation` 的理由
- 如果某次分支 push 已按非 PR push 执行，后来才决定用同一 head 开 PR，则必须先补跑当前应有的 `Next Push Gate`，补跑通过后才允许 create PR

### 不命中 full-gate 路径时

仍保留现有轻验证原则：

- docs-only 更新
- 只读排查
- Linear 分诊/清理
- 不命中上述 full-gate 路径的非代码改动

这些场景继续按最轻验证或 closeout gate 处理，不强制跑 `make all`。

## 2. `make all` 的角色重新定性

### 旧角色

- CI failed 后的升级动作
- 高风险修复的最终确认

### 新角色

- 命中 full-gate 路径的 PR create/update push 的本地前置门

远端 CI 仍保留完整 `make all`，但其角色改为：

- 校验本地 gate 是否在远端环境中可重现
- 作为最终复核器与保护网

而不是作为“第一次发现 coverage / dialyzer / 其他 full-gate 问题”的主要入口。

### 新定性

在新制度下，如果首次远端仍暴露 coverage、dialyzer 等 full-gate 问题，应定性为：

- 本地 `make all` 没有执行
- 或本地执行不符合要求
- 或存在真实环境漂移 / 不稳定性需要升级处理

不再把它当成正常波动。

## 3. `push` skill 变成硬门执行器

`push` skill 应该显式区分三类分支：

### A. 普通非 PR push

- 运行与 diff 匹配的最轻验证

### B. PR create/update 且命中 full-gate 路径

- 必须先运行本地 `make all`
- 如果失败，停止 push，先修复问题

### C. PR create/update 但不命中 full-gate 路径

- 继续使用 closeout gate

关键点是：这里必须写成执行分支，不再接受泛化表述。

此外，`push` skill 里的 auto-merge 示例不能再用 `enable-auto-merge || true` 吞错；必须改成显式捕获 exact failure text，并在进入任何 manual fallback 之前先写入 PR/issue comment stream。

同一个技能里还要补一条补救分支：

- 如果发现 PR create/update、review reply、comment 审计、merge 这些关键 GitHub 写操作是通过 GitHub UI、`gh`、ad-hoc CLI、其他 helper 做的
- 并且没有用户显式授权，也没有已记录的 `github_api.py unavailable` blocker
- 就不能继续把当前 PR 当成“正常 closeout 中”
- 必须先用 `.codex/skills/github_api.py` 把这次 out-of-band write 的事实与原因写进评论流
- 然后重新确认 PR 状态、review delta、required checks，必要时重跑对应 gate，再继续

## 4. `land` skill 继承同一门禁

`land` skill 在 CI 失败后的修复循环里，任何再次 push 都必须复用与 `push` skill 相同的门禁判定：

- 如果修复后的 diff 仍命中 full-gate 路径，并且这次 push 会更新 open PR，则再次 push 前重新跑本地 `make all`

不能因为已经进入 `land` 阶段，就退回到“只看 required local validation”的泛化口径。

## 5. 主线程 framing 改成“恢复 latest head full gate 全绿”

当远端或本地 full gate 失败时，主线程不应把目标拆成：

- 修 coverage
- 修 dialyzer
- 修 lint

而应统一表述成：

- 恢复 latest head 的 full gate 全绿

这样执行和 reviewer 都会围绕整条链路收口，而不是围绕单点红灯局部最优化。

## 6. Workpad 新增 `Next Push Gate`

`## Codex Workpad` 模板新增固定字段：

- `Next Push Gate: local make all`
- `Next Push Gate: closeout gate`
- `Next Push Gate: light validation`

它的作用不是记录历史，而是在每次准备 push 前把注意力锚回当前门槛。

## 7. reviewer 输出统一为 `Implementation Review` + `Push Readiness`

reviewer 输出需要从“只评代码/规格合理性”升级成双结论结构：

- `Implementation Review`
  - 改动是否正确、是否命中需求、是否有明显回归
- `Push Readiness`
  - 当前是否满足再次 push 条件
  - 如果不满足，明确缺什么：例如缺本地 `make all`、缺 review delta 处理、缺某项定向验证

这不会新增 reviewer 角色数量，但会强化 reviewer 的输出格式。

## 8. 实现后的零上下文 reviewer 必须进主流程

文档阶段的 analysis subagents 只能解决“动手前方案是否站得住”，不能替代“实现完成后代码是否该 push”的独立复核。

因此需要新增一个实现后的硬节点：

- 只要涉及代码新增、删除、重构或行为变更
- 在任何 create PR / update open PR 的 `git push` 之前
- 必须完成一次零上下文 reviewer
- reviewer 看到的是实现后的累计 diff、验证结果、风险和必要文件，而不是作者线程的历史推理
- reviewer 结论必须落进 issue body 的稳定字段
- 未通过时不得 push，也不得把工单推进到 `Human Review`

这样才能把“提交前必须复核”从 AGENTS 里的原则句，变成 workflow 里的执行门。

## 9. 主线程承担最终 push readiness 裁决

在默认 `1+3` 模式下，主线程都必须在 push 前给出最终裁决；只有小修小改或强探索阶段才允许退回 `1+1`。若只看最小硬要求，则实现 + 零上下文复核只构成默认模型或合规例外模型里的 `1+2` 计数子集，而不是一个与 `1+3` 并列的默认模式：

- 本次 push 前门是什么
- 当前是否已满足
- 如果没满足，为什么不得 push

这实际上是把原有“最终验证”职责显式化，而不是新增一个全新角色。

## 10. `WORKFLOW.md` 由原则句改成检查表问题

`WORKFLOW.md` 中 push 前相关描述需要更接近以下问题式检查表：

- 本次 push 是否创建或更新 PR？
- 这个分支是否已经因为“当前 head 后续将用于 create/update PR”而默认成为 PR-bound？
- 当前 diff 是否命中 full-gate 路径？
- 当前门应为 `local make all`、`closeout gate` 还是 `light validation`？
- 当前门是否已被本地证明通过？
- 若未通过，是否停止 push？

并且还要增加违规补救问句：

- 关键 GitHub 写操作是否全部走了 `.codex/skills/github_api.py`？
- 如果发现 out-of-band write，是否已经先记录事实与原因、再重新确认 PR closeout 信号？

这样执行时不容易被抽象口号绕过。

## 11. GitHub 关键写路径必须收紧成默认唯一通道

当前“standard path”或“repo-local helper or equivalent path”的说法还不够硬，仍然会给 GitHub UI、`gh`、其他 helper 留出常规绕行空间。

至少以下关键写操作要收紧成默认唯一允许路径：

- PR create/update
- review reply
- PR/issue comment 审计
- merge

默认都走 `.codex/skills/github_api.py`。只有用户显式授权，或 helper 不可用且已记录 blocker 时，才允许例外。

一旦发现违规写入，补救动作也必须固定：

1. 立即停止后续 closeout / merge。
2. 用 `.codex/skills/github_api.py` 在 PR / issue comment stream 记录 exact fact 与 exact reason。
3. 重新确认 PR 状态、review delta、latest head required checks。
4. 若后续仍要继续 push 或 merge，再按当下 head / PR 状态重跑对应 `Next Push Gate`。

这层规则的目标是压缩“绕过后直接继续推进”的空间，而不是声称技术上完全阻止绕过。

这里要明确两点：

1. 这是一条流程规则，不是技术隔离边界。
2. 一旦发现违规写入，补救动作不是“口头说明一下”，而是：
   - 先暂停 closeout / merge
   - 再用 `.codex/skills/github_api.py` 把 out-of-band write 的事实与原因写入评论流
   - 再重新确认 PR 状态、review delta、latest head required checks
   - 若 closeout 依据已经被污染或失效，则重跑对应 gate

## 12. repeated failures 的角色收窄

在新制度下，repeated failures 主要用于识别以下问题：

- 本地 full gate 已跑过，远端仍反复不过
- 机器资源承载不足
- 环境漂移
- 测试隔离不稳
- reviewer 或实现对实际问题误判

它不再主要用于补救“忘记从轻验证升级到 `make all`”。

## 风险与边界

### 1. 不把 `make all` 变成日常命令

这次改造必须反复强调：

- 写代码过程中仍是定向验证优先
- 只有在 PR create/update 前，且命中 full-gate 路径时，才要求本地 `make all`

否则容易把新制度误读成“每次改一行都得跑 full gate”。

### 2. 本机资源压力必须显式处理

新制度会提高本地 `make all` 的使用频率，因此必须同步保留并强调：

- `SYMPHONY_TEST_MAX_CASES=4` 起步
- 资源紧张降到 `2`，再到 `1`
- 仍不稳则停止并明确报告机器扛不住当前 full gate

不能因为心理抗拒而偷偷跳过。

### 3. 文本一致性风险

这次要同时改：

- 根 `AGENTS.md`
- `elixir/AGENTS.md`
- `push` / `land` skill
- `WORKFLOW.md`

如果只改其中一部分，会制造新的歧义。因此实施必须以“所有入口文本一致”为完成条件。

## 二次讨论焦点

这份设计的核心结论有三条：

1. 我同意把本地 `make all` 前移到命中 full-gate 路径的 PR create/update push 前。
2. 我同意通过 `Next Push Gate` 和 `Push Readiness` 把收口责任显式化，而不是继续依赖执行者记忆。
3. 我同意把普通开发分支默认视为 PR-bound，并补上“同一 head 先轻推、后开 PR”时必须先补 gate 的规则。
4. 我同意把关键 GitHub 写操作收紧到 `.codex/skills/github_api.py` 这一条默认唯一正常路径，并在发现 out-of-band write 时先停机审计再继续。
5. 我同意顺手把根 `AGENTS.md` 中 `1+1` / `1+2` / `1+3` 的口径做最小修正：默认 `1+3`，只有小修小改或强探索阶段才允许 `1+1`，而 `1+2` 只保留为最小硬要求视角下的计数表达，避免执行与汇报口径继续互相打架。
6. 我不同意把问题表述成“原先完全没人负责”；更准确的说法是“已有角色存在，但职责没有被硬化成 push readiness 的硬门”。

如果进入实施，后续所有规则修改都应围绕这三条保持一致。
