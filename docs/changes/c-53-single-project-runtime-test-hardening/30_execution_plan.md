# C-53 运行时测试补强实现前执行计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不新建独立测试平台的前提下，把 C-53 首批运行时硬化测试和低耦合第二批补强落进现有 ExUnit 主套件，并尽量把首次 PR-bound `make all` 压到一次。

**Architecture:** 以现有测试文件为边界，按业务语义分成 Precheck、Dispatch/Retry、Resume Barrier、Observability 四个测试桶推进。开发阶段只跑定向测试，全部桶完成并通过零上下文复核后，再做第一次本地 `make all`。

**Tech Stack:** Elixir, ExUnit, existing test helpers, repo-local workflow gate

---

### Task 1: 固化 Precheck 桶

**Files:**
- Modify: `elixir/test/symphony_elixir/m3_precheck_test.exs`
- Optional verify: `elixir/test/symphony_elixir/extensions_test.exs`

- [ ] **Step 1: 新增 `current_work` 不可重复开工的失败测试**

```elixir
test "todo already present in current_work is not redispatched in the same round" do
  issue = %Issue{id: "issue-current-work", identifier: "MT-C53-1", title: "Already running", state: "Todo", blocked_by: []}

  result =
    SymphonyElixir.M3Precheck.run([issue], %{
      current_project_slug: "alpha",
      current_project_id: "project-alpha",
      m3_enabled: true,
      max_concurrent_agents: 2,
      active_running_count: 1,
      current_work: %{
        count: 1,
        entries: [%{issue_id: "issue-current-work", issue_identifier: "MT-C53-1", state: "In Progress"}]
      },
      terminal_states: ["Done"]
    })

  assert Enum.map(result.dispatched_todos, & &1.identifier) == []
end
```

- [ ] **Step 2: 运行 Precheck 定向测试确认失败点**

Run:
```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/m3_precheck_test.exs
```

Expected:
- 当前新增 case 失败，或暴露现有 `current_work` 语义缺口

- [ ] **Step 3: 最小修正测试与实现，使 Precheck 合同完整**

需要补齐的目标：
- `eligible`
- `blocked`
- `capacity_queued`
- `current_work`
- `blocked_but_in_progress`

只允许最小实现改动；如果现有 `m3_precheck` 已经满足，优先只补测试与更贴近业务的 case 名。

- [ ] **Step 4: 重新运行 Precheck 定向测试**

Run:
```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/m3_precheck_test.exs
```

Expected:
- PASS

### Task 2: 固化 Dispatch / Retry / Generation Fence 桶

**Files:**
- Modify: `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- Optional support: `elixir/test/symphony_elixir/core_test.exs`

- [ ] **Step 1: 新增 retry 必换代际的失败测试**

```elixir
test "retry assigns a new run_instance_id for the next generation" do
  issue_id = "issue-c53-retry-generation"
  # 目标断言：
  # 1. 第一次 running entry 带旧 run_instance_id
  # 2. 触发 retry 后，新的 retry / dispatch 不复用旧 run_instance_id
  # 3. 新旧 generation 的 update/result 只消费各自代际
end
```

- [ ] **Step 2: 新增 dispatch 一致性测试**

```elixir
test "dispatch acceptance keeps claim, running entry, and trace in sync" do
  issue_id = "issue-c53-dispatch-sync"
  # 目标断言：
  # 1. dispatch_started / dispatch_accepted trace 成对出现
  # 2. state.claimed 保持该 issue
  # 3. running entry 含当前 generation 的 run_instance_id
end
```

- [ ] **Step 3: 运行 orchestrator 定向测试确认失败点**

Run:
```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs
```

Expected:
- 新增 case 失败，暴露 retry generation 或 dispatch sync 缺口

- [ ] **Step 4: 最小修正 orchestrator / helper 逻辑**

允许触达：
- `elixir/lib/symphony_elixir/orchestrator.ex`
- `elixir/lib/symphony_elixir/agent_runner.ex`

禁止顺手扩张到无关 UI 或通用 harness 重构。

- [ ] **Step 5: 重新运行 orchestrator 定向测试**

Run:
```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs
```

Expected:
- PASS

### Task 3: 固化 Resume Barrier / Terminal Finalization 桶

**Files:**
- Modify: `elixir/test/symphony_elixir/app_server_test.exs`

- [ ] **Step 1: 新增 `completed` 只是 provisional success 的正向合同测试**

```elixir
test "turn completed is not treated as final success until thread resume confirms it" do
  # 目标断言：
  # 1. 收到 turn/completed 后不会立即把结果当健康成功返回
  # 2. 只有 thread/resume 给出 finalized completed turn 后才成功
end
```

- [ ] **Step 2: 运行 app_server 定向测试确认失败点**

Run:
```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/app_server_test.exs
```

Expected:
- 新增 case 失败，或暴露 `completed -> resume barrier` 合同仍是隐含而非显式

- [ ] **Step 3: 最小修正 barrier 语义或测试组织**

允许触达：
- `elixir/lib/symphony_elixir/codex/app_server.ex`

优先目标：
- 把现有 late cancel / late fail 合同与正向 finalized success 对齐

- [ ] **Step 4: 重新运行 app_server 定向测试**

Run:
```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/app_server_test.exs
```

Expected:
- PASS

### Task 4: 固化 Observability 与低耦合第二批项

**Files:**
- Modify: `elixir/test/symphony_elixir/run_state_store_test.exs`
- Optional support: `elixir/test/symphony_elixir/run_trace_test.exs`

- [ ] **Step 1: 新增 summary / timeline 对当前 generation 的业务向断言**

```elixir
test "summary and timeline stay aligned with the current run generation after retry" do
  # 目标断言：
  # 1. summary 只看当前 run_instance_id
  # 2. timeline / detail 不暴露旧 generation 的 late events
end
```

- [ ] **Step 2: 运行 run_state_store 定向测试确认失败点**

Run:
```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/run_state_store_test.exs
```

Expected:
- 新增 case 失败，或暴露当前 summary/timeline 业务表达仍不完整

- [ ] **Step 3: 最小修正观测层过滤或 trace 补证**

允许触达：
- `elixir/lib/symphony_elixir/run_state_store.ex`
- `elixir/test/symphony_elixir/run_trace_test.exs`

禁止把 `run_live` 扩成第一批主实现面。

- [ ] **Step 4: 重新运行观测层定向测试**

Run:
```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/run_state_store_test.exs
```

Expected:
- PASS

### Task 5: 一次性 closeout 准备

**Files:**
- Verify only: current branch diff

- [ ] **Step 1: 运行四个主测试桶的定向回归**

Run:
```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/m3_precheck_test.exs
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/app_server_test.exs
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/run_state_store_test.exs
```

Expected:
- 四个主测试桶全部 PASS

- [ ] **Step 2: 运行格式与 lint**

Run:
```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix format --check-formatted
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix lint
```

Expected:
- PASS

- [ ] **Step 3: 只在准备 create/update PR 时第一次运行本地 `make all`**

Run:
```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- make all
```

Expected:
- PASS

说明：
- 这一步的目标是把首次 PR-bound full gate 压到一次
- 如果失败，按仓库规则修复后必须再次运行，不得以“想少跑一次”为理由跳过
