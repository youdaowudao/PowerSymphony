# C-53 PR Full Gate Pre-Push

## 目标

把当前“命中 full-gate 路径的 PR create/update push 先跑 closeout gate，CI 失败后再升级到本地 `make all`”的双态收口规则，改成“命中 full-gate 路径的 PR create/update push 一律先本地 `make all`，绿了再 push”的单态收口规则。

## 需求快照

### 要解决什么问题

- 当前规则把 `closeout gate` 和本地 `make all` 分成两个阶段：
  - 开发阶段与 PR create/update 前，默认是格式检查、lint、定向测试。
  - 只有高风险改动或 CI 已失败后，才要求在再次 push 前跑本地 `make all`。
- 在 `.github/workflows/make-all.yml` 命中的路径上，远端 CI 仍会执行完整 `make all`，所以很多 PR 的第一次 full-gate 暴露实际上发生在远端。
- 这使得远端 `make all` 被实际用成“串行发现器”：先暴露 coverage，再暴露 dialyzer，必要时再暴露下一层 gate。
- 主线程、reviewer、Codex Workpad 与 `push/land` 执行器里都缺少一个显式的“本次 push 前到底该过哪一道门”的硬检查点，导致收口强依赖执行者记得在某个时刻切换心智模型。

### 成功标准

- 命中 `.github/workflows/make-all.yml`、`elixir/**`、`AGENTS.md`、`SPEC.md` 的 PR create/update push，在本地必须先完成 `SYMPHONY_TEST_MAX_CASES=<n> make all`，成功后才允许 push。
- 对 open PR update，以上 full-gate 判定基线统一是“更新后的当前分支 / PR head 相对 PR base（默认 `origin/main`）的累计 diff”，不得只看本轮未推送的小补丁。
- 普通开发分支默认视为 PR-bound；只要当前 head 后续会用于 create PR / update PR，就必须按该累计 diff 选择 `Next Push Gate`，不能把将来要开 PR 的分支 push 当成普通 light-validation push。
- 若某次分支 push 已按非 PR push 执行，后来才决定用同一 head 开 PR，则在 create PR 前必须先补跑当前应有的 `Next Push Gate`；未补跑前不得开 PR。
- 远端 CI 继续保留完整 `make all`，但它的角色改为最终复核器，而不是主要发现器。
- 根 `AGENTS.md`、`elixir/AGENTS.md`、`.codex/skills/push/SKILL.md`、`.codex/skills/land/SKILL.md`、`elixir/WORKFLOW.md` 的规则口径一致，不允许继续保留“第一次 PR push 可不跑本地 make all”的暗门。
- `Codex Workpad` 模板与 reviewer 输出都新增显式收口锚点，至少能清楚表达：
  - `Next Push Gate`
  - `Implementation Review`
  - `Push Readiness`
- 若发现关键 GitHub 写操作走了旁路，补救顺序必须固定为：先停 closeout / merge，再记录审计评论，然后重查 PR 状态 / review delta / latest head required checks，最后按需重跑 gate。
- 新规则明确规定：在新制度下，首次远端再暴露 coverage、dialyzer 等 full-gate 问题，应视为流程未执行到位，而不是正常波动。
- 若关键 GitHub 写操作被发现通过 GitHub UI、`gh`、ad-hoc CLI、其他 helper 完成，除非有用户显式授权或已记录 `github_api.py unavailable` blocker，否则视为流程违规；必须先用 `.codex/skills/github_api.py` 记录 out-of-band write 的事实与原因，再重新确认 PR 状态、review delta、required checks，并在需要时重跑对应 gate 后才能继续。

### 明确不做什么

- 不降低远端 CI coverage threshold，不删测试，不弱化 `.github/workflows/make-all.yml`。
- 不把本地 `make all` 提升成“每次编辑文件都要跑”的日常开发命令；它仍然只绑定到 PR create/update 前的收口点。
- 不改变本仓库现有 auto-merge、manual merge fallback、Linear 状态推进的总体流程。
- 不在这次改造里引入新的持久化状态机或额外 workflow 引擎；本轮只改规则文本、执行入口与执行记录模板。
- 不声称可以从技术上完全阻止 GitHub UI、`gh` 或其他 helper 绕过；本轮只做规则收紧、审计补救与停机线加固。
- 不改变默认多 Agent 模式仍是 `1+3` 的总原则；本轮只把 `1+2` 收敛为“实现 + 零上下文复核”的最小硬要求计数口径，避免把它误读成与默认 `1+3` 并列的常规模式。

### 固定约束

- 文档落点遵守本仓库规则，使用 `docs/changes/` 保存稳定设计与计划快照。
- 规则文本必须保持仓库内一致性；根 `AGENTS.md` 与 `elixir/AGENTS.md` 不能出现互相打架的门禁定义。
- `.codex/skills/github_api.py` 必须被收紧成 PR create/update、review reply、comment 审计、merge 的默认唯一正常写路径。
- 本地 `make all` 仍需遵守并发与资源安全红线：
  - 测试命令显式带 `SYMPHONY_TEST_MAX_CASES`
  - 重型测试带监控
  - 机器承载不了时必须显式报告，不能偷跳过
- `WORKFLOW.md` 中已有的 `Checking`、review delta、auto-merge 先后顺序、manual merge fallback 约束必须保留，并把实现后的零上下文 reviewer 串成 push 前硬节点。

## 文档索引

- [10_design.md](./10_design.md)
- [20_plan.md](./20_plan.md)
