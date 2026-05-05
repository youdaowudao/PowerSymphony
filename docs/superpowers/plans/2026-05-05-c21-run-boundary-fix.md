# C-21 Run Boundary Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修正 `turn/completed` 在单项目 Symphony 执行链中被过早升级为健康 run 完成的问题，并保留 `agent.max_turns` 打满后的合法 continuation。

**Architecture:** 在 `AgentRunner` 内部把 turn 级结束映射为结构化 run 结果，并通过显式消息把 run 结果上报给 `Orchestrator`。`Orchestrator` 只根据 run 结果决定是否 continuation 或失败重试，不再把所有 `:normal` worker 退出都视为 continuation 候选。

**Tech Stack:** Elixir, ExUnit, GenServer, Task.Supervisor

---

### Task 1: 先写失败测试，固定 run 级结果边界

**Files:**
- Modify: `elixir/test/symphony_elixir/core_test.exs`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`

- [ ] **Step 1: 在 `core_test.exs` 为 `AgentRunner` 新增 run 结果测试**

```elixir
test "agent runner reports run_result continuation_required when active issue remains after a normal turn" do
  # 复用现有 fake codex turn/completed 场景
  # 断言 AgentRunner.run/3 返回 :ok
  # 断言收到 {:agent_run_result, issue_id, %{status: :continuation_required, reason: :issue_still_active, turn_count: 1}}
end

test "agent runner reports run_result max_turns_reached when issue is still active at max_turns" do
  # 复用现有 max_turns 场景
  # 断言收到 {:agent_run_result, issue_id, %{status: :continuation_required, reason: :max_turns_reached, turn_count: 2}}
end
```

- [ ] **Step 2: 运行定向测试，确认当前代码红灯**

Run: `cd elixir && mix test test/symphony_elixir/core_test.exs --only focus`
Expected: FAIL，原因是当前没有 `:agent_run_result` 消息或结果结构不匹配

- [ ] **Step 3: 在 `core_test.exs` 为 `Orchestrator` 新增 run 结果路由测试**

```elixir
test "normal worker exit without continuation run_result does not schedule active-state continuation retry" do
  # 构造 running entry
  # 先发送 {:agent_run_result, issue_id, %{status: :completed, reason: :issue_inactive}}
  # 再发送 {:DOWN, ref, :process, self(), :normal}
  # 断言 retry_attempts 中没有该 issue
end

test "normal worker exit with continuation_required run_result schedules continuation retry" do
  # 先发送 {:agent_run_result, issue_id, %{status: :continuation_required, reason: :max_turns_reached}}
  # 再发送 :DOWN
  # 断言 delay_type 是 continuation，attempt=1
end
```

- [ ] **Step 4: 运行定向测试，确认当前代码红灯**

Run: `cd elixir && mix test test/symphony_elixir/core_test.exs --only focus`
Expected: FAIL，原因是 `Orchestrator` 当前忽略 run 结果并对所有 `:normal` 退出统一 continuation

### Task 2: 实现 AgentRunner 结构化 run 结果与 prompt 收紧

**Files:**
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
- Modify: `elixir/lib/symphony_elixir/prompt_builder.ex`
- Test: `elixir/test/symphony_elixir/core_test.exs`

- [ ] **Step 1: 定义 run 结果结构与发送函数**

```elixir
@type run_result_status :: :completed | :continuation_required

defp send_run_result(recipient, %Issue{id: issue_id}, attrs)
    when is_binary(issue_id) and is_pid(recipient) and is_map(attrs) do
  send(recipient, {:agent_run_result, issue_id, attrs})
  :ok
end
```

- [ ] **Step 2: 把 `do_run_codex_turns/8` 改为显式返回 run 结果，并在结束点发送消息**

```elixir
{:ok, %{status: :completed, reason: :issue_inactive, turn_count: turn_number}}
{:ok, %{status: :continuation_required, reason: :max_turns_reached, turn_count: turn_number}}
```

- [ ] **Step 3: 保持 active issue 下的内部 continuation，但不再把它记录为 “Completed agent run”**

```elixir
Logger.info("Completed agent turn for ...")
Logger.info("Continuing agent run for ...")
```

- [ ] **Step 4: 第 1 轮 prompt 增加“active issue 未闭环时不要过早结束 turn”约束**

```elixir
@default_prompt_template """
...
- Do not end the turn merely because you have posted an interim update while the Linear issue remains active.
- Only stop the turn early when you are truly blocked or when the issue is ready for correct closeout.
"""
```

- [ ] **Step 5: 运行目标测试，确认 Task 1 红灯转绿**

Run: `cd elixir && mix test test/symphony_elixir/core_test.exs`
Expected: PASS，新增 `AgentRunner` / prompt builder / orchestration 相关用例通过

### Task 3: 实现 Orchestrator 基于 run 结果的 continuation 判定

**Files:**
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Test: `elixir/test/symphony_elixir/core_test.exs`

- [ ] **Step 1: 在 running entry 中保存最新 run 结果**

```elixir
run_result: nil
```

- [ ] **Step 2: 增加 `handle_info({:agent_run_result, ...}, state)`**

```elixir
def handle_info({:agent_run_result, issue_id, run_result}, %{running: running} = state) do
  # 更新 running entry.run_result
end
```

- [ ] **Step 3: 把 `:DOWN` 的 `:normal` 分支改成按 run 结果路由**

```elixir
case Map.get(running_entry, :run_result) do
  %{status: :continuation_required} ->
    # schedule continuation retry
  %{status: :completed} ->
    # 只 complete_issue，不 schedule retry
  _ ->
    # 保守收敛为失败重试，避免无结果静默吞掉
end
```

- [ ] **Step 4: 保留 crash/timeout 等异常退出的原失败重试路径**

```elixir
# 非 :normal 的 reason 维持原逻辑
```

- [ ] **Step 5: 运行定向测试，确认 run 结果路由符合预期**

Run: `cd elixir && mix test test/symphony_elixir/core_test.exs`
Expected: PASS，`normal worker exit ...` 两个关键测试通过，旧的 crash retry 用例继续通过

### Task 4: 收紧 AppServer 可见文案并做最终验证

**Files:**
- Modify: `elixir/lib/symphony_elixir/codex/app_server.ex`
- Test: `elixir/test/symphony_elixir/core_test.exs`
- Test: `elixir/test/symphony_elixir/app_server_test.exs`

- [ ] **Step 1: 把模糊日志从 `Codex session completed` 改成 turn 级表达**

```elixir
Logger.info("Codex turn completed for #{issue_context(issue)} session_id=#{session_id}")
```

- [ ] **Step 2: 跑本轮相关测试集**

Run: `cd elixir && mix test test/symphony_elixir/core_test.exs test/symphony_elixir/app_server_test.exs test/symphony_elixir/orchestrator_status_test.exs`
Expected: PASS

- [ ] **Step 3: 跑更小范围的回归验证并记录结果**

Run: `cd elixir && mix test`
Expected: PASS；若失败，仅允许处理本轮暴露出的同根因测试脆弱性

- [ ] **Step 4: 提交前自检**

Run: `git status --short`
Expected: 仅包含本任务相关改动
