# C-33 PR Checking Design

## Goal

把单卡在 `PR created / updated` 之后的闭环，从“提交了 `PR` 就可转人工”收紧成“必须等到当前 `PR` 最新 `head SHA` 的 `required checks` 收口完成，或明确进入异常升级路径”。

本次设计同时吸收用户在 2026-05-12 的最新更正：

- `PR` 收口成功条件改为：`PR` 仍然有效，且当前最新 `head SHA` 的 `required checks` 通过。
- 本卡不再要求 `PR` 已 merge，或 `Merging` 已完成，才算 `PR` 后半段收口成功。

## 2026-05-14 Auto-merge ordering correction

基于这次真实事故，本设计再追加一条更高优先级的执行顺序修正：

- 对 open PR 的任何新提交，必须在 `git push` 成功后的第一时间就尝试开启 auto-merge。
- 不得先读取 checks、review delta、mergeability 或 `viewerCanEnableAutoMerge` 再决定是否发起 auto-merge。
- `already enabled` 视为成功。
- `clean status` 视为“已经来到直接合并阶段”，不是权限错误。
- 只有 auto-merge 因其他原因失败时，才允许保留手动 merge 作为异常兜底；并且该失败原因必须先写入评论区。

## Scope Interpretation

### In Scope

- 固定 `Checking` 作为 `PR` 后半段闭环的运行时阶段。
- 固定“只认当前 `PR` 最新 `head SHA` 的 `required checks`”这条收口口径。
- 固定 checks 失败后默认留在同一个分支、同一个 `PR` 内继续修复。
- 固定第一版异常升级条件与异常评论最小字段、同因去重规则。
- 把上述语义落实到当前仓库实际承接面：`elixir/WORKFLOW.md` 与对应 prompt 渲染测试。

### Out of Scope

- 不新增独立 `PR Gatekeeper` 服务。
- 不新增 `GitHub / Linear webhook` 驱动的新事件系统。
- 不处理项目级 `Todo` 候选池扫描、并发派发。
- 不做 review 内容理解、业务验收自动化。
- 不把 `Merging -> Done` 流程并入本卡成功条件。

## Confirmed Current State

### 1. 当前运行合同会把 attached PR 过早收口到 `Human Review`

当前 [elixir/WORKFLOW.md](/home/ss/data/projects/symphony-workspaces/C-33/elixir/WORKFLOW.md) 仍固定要求：

- 正常执行结束时应进入 `Human Review`
- “Before moving to `Human Review`, perform one bounded PR feedback and checks pass”
- `Step 2` 的主干仍是 `Todo -> In Progress -> Human Review`

这套合同能表达“有 PR 时要看 checks”，但它还没有把 `Checking` 定义成一个必须持续等待最新 `head SHA` 收口完成的独立运行时阶段，因此会把“PR 已创建”误当成可转人工的接近完成信号。

### 2. 运行时 continuation 已经存在，可承接本卡第一版语义

当前运行时代码已经具备这两个关键能力：

- [elixir/lib/symphony_elixir/agent_runner.ex](/home/ss/data/projects/symphony-workspaces/C-33/elixir/lib/symphony_elixir/agent_runner.ex) 在 issue 仍处于 active state 时，会把一次正常 turn 结果上报为 `continuation_required`。
- [elixir/lib/symphony_elixir/orchestrator.ex](/home/ss/data/projects/symphony-workspaces/C-33/elixir/lib/symphony_elixir/orchestrator.ex) 会基于 active state continuation 继续调度，而不是把一次正常 turn 自动视为工单完成。

因此，第一版不必先引入新的程序化 PR gate 组件；先把 workflow contract 改准确，再用现有 continuation 机制承接，是当前仓库的最小正确落点。

### 3. 当前分支同步状态

2026-05-12 本地已按仓库规则执行同步检查：

- `git fetch origin`
- `git -c merge.conflictstyle=zdiff3 merge origin/main`

结果：

- 当前分支 `C-33` 的 `HEAD` 为 `c26ed66`
- `origin/main` 也是 `c26ed66`
- merge 结果为 `Already up to date.`

这说明本次设计与后续实现不需要先处理来自 `origin/main` 的冲突。

## Design Decision

### 1. 把 `Checking` 固定为 `PR` 后半段的运行时 phase

本卡不要求立刻新增 Linear 显式 issue state，但要求在 workflow contract 里明确：

- `PR created / updated` 只是进入 `Checking` 的起点，不是完成信号。
- attached `PR` 存在时，正常执行不能因为“已经有 PR”就提前转去 `Human Review`。
- 只要 `PR` 仍未达到收口条件，agent 就应继续停留在 active execution / continuation 语义里，而不是把卡伪装成已完成。

### 2. 固定新的 `PR` 收口成功条件

本卡负责的 `PR` 后半段闭环，只在下面两条同时满足时才算成功收口：

1. `PR` 仍然有效。
2. 当前 `PR` 最新 `head SHA` 的 `required checks` 通过。

明确排除：

- 旧 `head SHA` 的 checks 结果不能替代最新提交的收口依据。
- 本卡不再要求 `PR` 已 merge。
- 本卡不再要求 `Merging` 已完成。

### 3. 固定 checks 失败后的默认回路

当 checks 未通过时，默认路径是：

- 继续留在同一个分支
- 继续留在同一个 `PR`
- 在同一个卡内增量修复

不做：

- 不新开卡
- 不新开 `PR`
- 不因单次失败直接把 `Human Review` 当常规下一站

### 4. 固定新 commit 覆盖旧 checks 的规则

当 `Checking` 期间又推了新 commit：

- 旧 commit 的 checks 结果立即失效。
- 收口判断只能重新以新的 `head SHA` 为准。

这条规则要在 workflow contract 里写死，否则“旧 checks 偶然已绿”会错误收口新提交。

### 5. 重新界定 `Human Review` 与 `Merging`

在本卡里：

- `Human Review` 不再是“PR 一创建就进入的常规等待站”。
- `Human Review` 只承接两类结果：
  - `Checking` 已按本卡规则成功收口后的人工确认入口
  - 自动化无法继续时的异常升级入口

`Merging` 仍保留，但其语义只限于：

- 人工已经批准
- 进入 `land` 流程
- 最终由 `Merging -> Done` 完成合并与终态收口

换句话说，`Merging -> Done` 仍是系统整体流程的一部分，但不属于 `C-33` 这张卡定义的 `PR` 后半段成功条件。

## Exception Escalation

### 1. 第一版异常升级触发条件

第一版 `Human Review` 异常升级至少覆盖：

- 连续失败后继续自动修复的收益明显下降
- merge conflict 无法安全自动解决
- 仓库保护规则要求人类动作
- 权限不足
- checks 长时间异常或迟迟不收口
- `PR` 关闭、失联，或状态无法可靠判断

### 2. 第一版异常评论最小字段

异常评论最小字段固定为：

- 异常原因
- 当前 `PR` 标识
- 当前 `head SHA`
- 受影响的 checks / gate
- 建议人工动作

### 3. 同因去重

异常评论只在“明显异常”时写，且遵守同因去重：

- 同一个 `PR`
- 同一个 `head SHA`
- 同一种异常原因

在没有新增诊断价值之前，不重复刷同类评论。

## Minimal Implementation Surface

### First Pass

首轮只改这两个面：

- [elixir/WORKFLOW.md](/home/ss/data/projects/symphony-workspaces/C-33/elixir/WORKFLOW.md)
- [elixir/test/symphony_elixir/core_test.exs](/home/ss/data/projects/symphony-workspaces/C-33/elixir/test/symphony_elixir/core_test.exs)

原因：

- 本卡第一版的主要缺口是 workflow contract 不准确。
- 当前 continuation 运行时已经存在，不必先扩成新的 gatekeeper 代码。
- `core_test` 已承担 in-repo workflow prompt 渲染断言，是当前最直接的合同回归面。

### Escalation Surface

只有当下面任一条件成立时，才升级到运行时代码改动：

- 仅改 `WORKFLOW.md` 无法让 prompt 明确表达 `Checking` 新语义
- 仅改 contract 后，现有 continuation 行为仍会让 attached PR 被提前收口到 `Human Review`
- 定向测试证明 `agent_runner` / `orchestrator` 对 active state continuation 的承接仍不足

若升级，下一层核查面是：

- [elixir/lib/symphony_elixir/agent_runner.ex](/home/ss/data/projects/symphony-workspaces/C-33/elixir/lib/symphony_elixir/agent_runner.ex)
- [elixir/lib/symphony_elixir/orchestrator.ex](/home/ss/data/projects/symphony-workspaces/C-33/elixir/lib/symphony_elixir/orchestrator.ex)

## Validation Strategy

### Targeted Tests First

本卡首轮只做定向验证，不跑 full gate。

优先验证：

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test \
  test/symphony_elixir/core_test.exs:1342
```

该用例已经覆盖 in-repo `WORKFLOW.md` 渲染断言，适合直接验证新合同关键词是否进入 prompt。

如有必要，再补 continuation 相关定向用例，确保 contract 文案与现有 active-state continuation 语义不冲突。

### Process Cleanup

每轮本地测试结束后，必须立即检查并清理该轮命令显式拉起的临时进程、fake worker 和端口占用，避免叠加残留。

## Exit Criteria

本次 `C-33` 设计可以进入实现计划，当且仅当下面条件同时成立：

1. `PR` 收口成功条件已经明确修正为“`PR` 有效 + 最新 `head SHA` 的 `required checks` 通过”。
2. spec 中已明确排除“必须已 merge 才能算本卡成功”的旧口径。
3. `Human Review`、`Merging`、`Done` 的新边界已经写清楚。
4. 首轮改动面已收敛到 `WORKFLOW.md` 与 prompt 渲染测试。
5. 若 contract 改动不足，再升级到运行时代码，而不是预先扩 scope。
