# C-33 PR Checking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修正 `PR created / updated` 之后的 workflow contract，使 `C-33` 的 `PR` 后半段只在 `PR` 有效且最新 `head SHA` 的 `required checks` 通过时才收口，不再要求已 merge。

**Architecture:** 先把 `elixir/WORKFLOW.md` 改成能明确表达 `Checking` 收口规则的合同，再用 `core_test.exs` 的 in-repo workflow prompt 渲染用例锁定这些关键词。若 contract 调整后仍无法避免 attached PR 被提前收口到 `Human Review`，再升级到 `agent_runner` / `orchestrator` 的 continuation 语义层处理。

**Tech Stack:** Markdown, Elixir, ExUnit, mise

---

### Task 1: 用 prompt 渲染测试锁定新的 PR 收口合同

**Files:**
- Modify: `elixir/test/symphony_elixir/core_test.exs:1383`
- Read: `elixir/WORKFLOW.md`

- [ ] **Step 1: 写出失败断言，要求 prompt 明确表达 C-33 的新口径**

在 [elixir/test/symphony_elixir/core_test.exs](/home/ss/data/projects/symphony-workspaces/C-33/elixir/test/symphony_elixir/core_test.exs) 的 `test "in-repo WORKFLOW.md renders correctly"` 里增加如下断言：

```elixir
assert prompt =~ "`PR created / updated` 只是进入 `Checking` 的起点，不是完成信号。"
assert prompt =~ "attached `PR` 存在时，正常执行不能因为“已经有 PR”就提前转去 `Human Review`。"
assert prompt =~ "本卡负责的 `PR` 后半段闭环，只在下面两条同时满足时才算成功收口："
assert prompt =~ "1. `PR` 仍然有效。"
assert prompt =~ "2. 当前 `PR` 最新 `head SHA` 的 `required checks` 通过。"
assert prompt =~ "本卡不再要求 `PR` 已 merge。"
assert prompt =~ "本卡不再要求 `Merging` 已完成。"
assert prompt =~ "当 `Checking` 期间又推了新 commit："
assert prompt =~ "收口判断只能重新以新的 `head SHA` 为准。"
```

- [ ] **Step 2: 运行定向测试，确认它先失败**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test \
  test/symphony_elixir/core_test.exs:1383
```

Expected:

- 失败点来自新增断言未命中当前 `WORKFLOW.md`
- 失败原因是合同文本尚未更新，而不是测试环境或 workflow 加载报错

- [ ] **Step 3: 记录当前失败信号，作为 C-33 的复现依据**

把失败摘要记录到 issue workpad / Notes 时，使用下面这类措辞：

```text
定向 prompt 渲染测试未命中新合同语义：当前 WORKFLOW.md 仍会把 attached PR 视为可转 Human Review 的近完成状态，未明确“PR 有效 + 最新 head SHA required checks 通过”才收口。
```

- [ ] **Step 4: Commit**

```bash
git add elixir/test/symphony_elixir/core_test.exs
git commit -m "test(c-33): 锁定 PR checking 新合同"
```

Expected:

- 若此步执行，提交应只包含失败测试断言
- 如果当前阶段不允许保留红测试提交，则跳过 commit，把改动留在工作树继续下一任务

### Task 2: 最小改动 WORKFLOW.md 落实 Checking 新语义

**Files:**
- Modify: `elixir/WORKFLOW.md`
- Test: `elixir/test/symphony_elixir/core_test.exs:1383`

- [ ] **Step 1: 更新 Step 2 主干与 PR feedback sweep 前置说明**

在 [elixir/WORKFLOW.md](/home/ss/data/projects/symphony-workspaces/C-33/elixir/WORKFLOW.md) 中，把下面几处语义改成 `Checking` 版本：

```md
- When a ticket has an attached PR, run this protocol before moving to `Human Review`.
- `PR created / updated` 只是进入 `Checking` 的起点，不是完成信号。
- attached `PR` 存在时，正常执行不能因为“已经有 PR”就提前转去 `Human Review`。
```

并把 `## Step 2: Execution phase (Todo -> In Progress -> Human Review)` 改成能表达 `Checking` 的标题，例如：

```md
## Step 2: Execution phase (Todo -> In Progress -> Checking -> Human Review)
```

- [ ] **Step 2: 写入新的 PR 收口成功条件**

在 `WORKFLOW.md` 中新增一段明确规则，内容至少包含：

```md
本卡负责的 `PR` 后半段闭环，只在下面两条同时满足时才算成功收口：

1. `PR` 仍然有效。
2. 当前 `PR` 最新 `head SHA` 的 `required checks` 通过。

明确排除：

- 旧 `head SHA` 的 checks 结果不能替代最新提交的收口依据。
- 本卡不再要求 `PR` 已 merge。
- 本卡不再要求 `Merging` 已完成。
```

- [ ] **Step 3: 固定 checks 失败和新 commit 覆盖旧 checks 的默认回路**

在 `WORKFLOW.md` 的 Step 2 区域补充：

```md
- 当 checks 未通过时，默认继续留在同一个分支、同一个 `PR` 内增量修复。
- 不新开卡，不新开 `PR`，也不因单次失败直接把 `Human Review` 当常规下一站。
- 当 `Checking` 期间又推了新 commit，旧 commit 的 checks 结果立即失效，收口判断只能重新以新的 `head SHA` 为准。
```

- [ ] **Step 4: 重新界定 Human Review 与 Merging**

在 `WORKFLOW.md` 中把 `Human Review` / `Merging` 的边界补齐，要求至少出现以下语义：

```md
- `Human Review` 在本卡里只承接两类结果：
  - `Checking` 已成功收口后的人工确认入口
  - 自动化无法继续时的异常升级入口
- `Merging -> Done` 仍保留给后续 `land` 流程，但不属于 `C-33` 的成功条件。
```

- [ ] **Step 5: 固定第一版异常升级与异常评论规则**

在 `WORKFLOW.md` 中新增或改写段落，至少包含：

```md
- 第一版异常升级至少覆盖：连续失败收益下降、merge conflict 无法安全自动解决、仓库保护规则要求人类动作、权限不足、checks 长时间异常、`PR` 关闭或失联。
- 第一版异常评论最小字段：异常原因、当前 `PR` 标识、当前 `head SHA`、受影响 checks / gate、建议人工动作。
- 同因去重：同一个 `PR`、同一个 `head SHA`、同一种异常原因，不重复刷评论。
```

- [ ] **Step 6: 运行定向测试，确认新合同通过**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test \
  test/symphony_elixir/core_test.exs:1383
```

Expected:

- PASS
- 新增 prompt 断言全部命中

- [ ] **Step 7: 自检 WORKFLOW.md 不误伤 Merging/land 语义**

Run:

```bash
rg -n "Merging|land|Human Review|required checks|head SHA|PR created / updated|helper path" \
  elixir/WORKFLOW.md
```

Expected:

- 仍保留 `Merging -> Done` 与 `land` 语义
- 不再出现“必须 merge 完成才算 C-33 成功”的表述
- `Human Review` 不再被描述成 attached PR 的默认下一站

- [ ] **Step 8: Commit**

```bash
git add elixir/WORKFLOW.md elixir/test/symphony_elixir/core_test.exs
git commit -m "feat(c-33): 修正 PR checking 收口合同"
```

### Task 3: 若 contract 不足，再升级到 continuation 运行时层

**Files:**
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Test: `elixir/test/symphony_elixir/core_test.exs`

- [ ] **Step 1: 只有在 Task 2 通过后仍发现行为缺口时，先写失败测试**

如果仅改 `WORKFLOW.md` 后，仍证明 attached PR 会被提前收口到 `Human Review`，新增一个最小行为测试，目标是表达：

```elixir
assert run_result.status == :continuation_required
assert run_result.reason in [:issue_still_active, :max_turns_reached]
```

并把测试场景命名成类似：

```elixir
test "attached PR checking remains in continuation until latest required checks pass"
```

- [ ] **Step 2: 运行单个失败测试确认 runtime 缺口真实存在**

Run:

```bash
cd elixir && LINE=$(rg -n 'attached PR checking remains in continuation until latest required checks pass' \
  test/symphony_elixir/core_test.exs | cut -d: -f1) && \
  SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test \
  test/symphony_elixir/core_test.exs:$LINE
```

Expected:

- FAIL
- 失败原因是 runtime 仍把 attached PR 过早视为可完成，而不是测试写错

- [ ] **Step 3: 只写最小实现，保持 continuation 语义优先**

若需要改 [agent_runner.ex](/home/ss/data/projects/symphony-workspaces/C-33/elixir/lib/symphony_elixir/agent_runner.ex) 或 [orchestrator.ex](/home/ss/data/projects/symphony-workspaces/C-33/elixir/lib/symphony_elixir/orchestrator.ex)，实现目标只限于：

```elixir
# 伪约束，不是最终代码
# attached PR 未达到“PR 有效 + 最新 head SHA required checks 通过”前，
# issue 仍应留在 active execution / continuation 语义里。
```

不要：

- 新增独立 gatekeeper 进程
- 新增项目级调度逻辑
- 擅自扩成 webhook / polling 系统重写

- [ ] **Step 4: 重跑定向测试，确认升级后的行为收口正确**

Run:

```bash
cd elixir && LINE=$(rg -n 'attached PR checking remains in continuation until latest required checks pass' \
  test/symphony_elixir/core_test.exs | cut -d: -f1) && \
  SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test \
  test/symphony_elixir/core_test.exs:1383 \
  test/symphony_elixir/core_test.exs:$LINE
```

Expected:

- PASS
- prompt 合同与 runtime continuation 语义同时满足

- [ ] **Step 5: Commit**

```bash
git add \
  elixir/lib/symphony_elixir/agent_runner.ex \
  elixir/lib/symphony_elixir/orchestrator.ex \
  elixir/test/symphony_elixir/core_test.exs
git commit -m "fix(c-33): 收紧 PR checking continuation 语义"
```

### Task 4: 跑分层验证并准备执行收尾

**Files:**
- Modify: `docs/superpowers/plans/2026-05-12-c-33-pr-checking.md`
- Verify: `elixir/WORKFLOW.md`
- Verify: `elixir/test/symphony_elixir/core_test.exs`

- [ ] **Step 1: 运行本卡首轮需要的定向验证**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test \
  test/symphony_elixir/core_test.exs:1383
```

Expected:

- `1 test, 0 failures`

如果 Task 3 被触发，则改为：

```bash
cd elixir && LINE=$(rg -n 'attached PR checking remains in continuation until latest required checks pass' \
  test/symphony_elixir/core_test.exs | cut -d: -f1) && \
  SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test \
  test/symphony_elixir/core_test.exs:1383 \
  test/symphony_elixir/core_test.exs:$LINE
```

- [ ] **Step 2: 每轮测试结束后立即检查临时进程残留**

Run:

```bash
ps -ef | rg "fake-codex|symphony-elixir-agent-runner|beam.smp" || true
```

Expected:

- 没有本轮测试遗留的额外 fake worker / fake codex 进程
- 若有残留，先清理再继续下一步

- [ ] **Step 3: 检查最终 diff 只覆盖 C-33 最小实现面**

Run:

```bash
git diff -- \
  elixir/WORKFLOW.md \
  elixir/test/symphony_elixir/core_test.exs \
  elixir/lib/symphony_elixir/agent_runner.ex \
  elixir/lib/symphony_elixir/orchestrator.ex \
  docs/superpowers/plans/2026-05-12-c-33-pr-checking.md
```

Expected:

- 若未触发 Task 3，diff 只应主要落在 `WORKFLOW.md` 与 `core_test.exs`
- 若触发 Task 3，runtime 改动也必须只服务于 attached PR continuation 语义

- [ ] **Step 4: Commit plan document after execution begins or finishes**

```bash
git add docs/superpowers/plans/2026-05-12-c-33-pr-checking.md
git commit -m "docs(c-33): 补充 PR checking 实现计划"
```
