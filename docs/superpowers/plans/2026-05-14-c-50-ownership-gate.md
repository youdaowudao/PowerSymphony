# C-50 Ownership Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复 `C-50` 的 ownership split-brain 路径，严格保证单 orchestrator 实例内同一 issue 在 ownership 未明确释放前不会并发多跑 worker，并修正跨代 `session/thread/turn` 混拼。

**Architecture:** 在 orchestrator 内为每次 dispatch attempt 引入 `run_instance_id`，把 worker 停止与 claim 释放拆成两阶段，并通过 worker 内的 app-server `turn/interrupt` 做 best-effort 协作 stop。对无法确认已安全结束的旧 owner，一律收敛到 `blocked_claim(reason: :remote_stop_unconfirmed)`；同时让 `RunTrace` / `RunStateStore` / snapshot 只消费当前 generation 的运行态字段。

**Tech Stack:** Elixir, ExUnit, Jason, Codex app-server JSON schema, mise

---

## Execution Model

- 实现模式固定为 `1+3`：
  - `1` 个实现 agent
  - `1` 个 spec/contract reviewer
  - `1` 个 code quality reviewer
  - `1` 个 business-logic / regression reviewer
- 主线程不直接写业务代码；主线程负责派发、收敛、验证、汇报。
- 本地验证只跑定向测试和必要的 `mix format --check-formatted`；不跑 `make all`。

### Task 1: 用失败测试锁定 ownership gate 合同

**Files:**
- Modify: `elixir/test/symphony_elixir/app_server_test.exs`
- Modify: `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- Create: `elixir/test/symphony_elixir/run_state_store_test.exs`

- [ ] **Step 1: 在 `AppServer` 测试里先锁定 interrupt 协议**

把下面的失败用例加到 `elixir/test/symphony_elixir/app_server_test.exs`，要求 fake codex 先返回 `thread/start` 和 `turn/start`，随后等待客户端发送 `turn/interrupt`：

```elixir
test "app server sends turn interrupt when worker receives interrupt message" do
  test_root = Path.join(System.tmp_dir!(), "symphony-app-server-interrupt-#{System.unique_integer([:positive])}")

  try do
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-INT-1")
    codex_binary = Path.join(test_root, "fake-codex")
    trace_file = Path.join(test_root, "interrupt.trace")

    File.mkdir_p!(workspace)
    System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

    File.write!(codex_binary, """
    #!/bin/sh
    trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/interrupt.trace}"
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s\n' "$line" >> "$trace_file"
      case "$count" in
        1) printf '%s\n' '{"id":1,"result":{}}' ;;
        2) printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-int-1"}}}' ;;
        3) printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-int-1"}}}' ;;
        4) printf '%s\n' '{"method":"turn/cancelled","params":{"reason":"interrupted"}}'; exit 0 ;;
      esac
    done
    """)
    File.chmod!(codex_binary, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    issue = %Issue{id: "issue-int-1", identifier: "MT-INT-1", title: "Interrupt me", state: "In Progress"}

    parent = self()

    task =
      Task.async(fn ->
        assert {:ok, session} = AppServer.start_session(workspace)
        send(parent, {:session_ready, self()})
        result = AppServer.run_turn(session, "interrupt", issue)
        AppServer.stop_session(session)
        result
      end)

    assert_receive {:session_ready, worker_pid}
    send(worker_pid, {:interrupt_codex_turn, "run-int-1", :stall_detected})

    assert {:error, {:turn_cancelled, %{"reason" => "interrupted"}}} = Task.await(task, 2_000)

    trace = File.read!(trace_file)
    assert trace =~ ~s("method":"turn/interrupt")
  after
    File.rm_rf(test_root)
  end
end
```

- [ ] **Step 2: 在 orchestrator 测试里先锁定 stall 不得立刻放权**

把下面的失败用例加到 `elixir/test/symphony_elixir/orchestrator_status_test.exs`。目标是：stall 命中后，`claimed` 仍保留，`running` 仍保留或在 grace timeout 后转 `blocked_claim`，但绝不能立刻 `schedule_issue_retry`：

```elixir
test "stall detection requests cooperative stop before any redispatch" do
  write_workflow_file!(Workflow.workflow_file_path(),
    tracker_api_token: nil,
    codex_stall_timeout_ms: 1_000
  )

  issue_id = "issue-stop-gate"
  orchestrator_name = Module.concat(__MODULE__, :StopGateOrchestrator)
  {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

  on_exit(fn ->
    if Process.alive?(pid) do
      Process.exit(pid, :normal)
    end
  end)

  worker_pid =
    spawn(fn ->
      receive do
        {:interrupt_codex_turn, "run-stop-1", :stall_detected} ->
          receive do
            :done -> :ok
          end
      end
    end)

  stale_at = DateTime.add(DateTime.utc_now(), -5, :second)
  initial_state = :sys.get_state(pid)

  running_entry = %{
    pid: worker_pid,
    ref: Process.monitor(worker_pid),
    identifier: "MT-STOP-GATE",
    issue: %Issue{id: issue_id, identifier: "MT-STOP-GATE", state: "In Progress"},
    run_instance_id: "run-stop-1",
    session_id: "thread-stop-turn-stop",
    last_codex_timestamp: stale_at,
    started_at: stale_at
  }

  :sys.replace_state(pid, fn _ ->
    initial_state
    |> Map.put(:running, %{issue_id => running_entry})
    |> Map.put(:claimed, MapSet.new([issue_id]))
  end)

  send(pid, :tick)
  Process.sleep(50)

  state = :sys.get_state(pid)
  assert MapSet.member?(state.claimed, issue_id)
  refute Map.has_key?(state.retry_attempts, issue_id)
end
```

- [ ] **Step 3: 在 `RunStateStore` 测试里锁定 generation 过滤**

创建 `elixir/test/symphony_elixir/run_state_store_test.exs`，先写一条会失败的 generation mismatch 用例：

```elixir
defmodule SymphonyElixir.RunStateStoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{LogFile, RawEventStore, RunStateStore, RunTrace}
  alias SymphonyElixir.Linear.Issue

  test "summary_for_running_entry ignores events from older run_instance_id" do
    logs_root = Path.join(System.tmp_dir!(), "symphony-run-state-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(logs_root)
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))

    issue = %Issue{id: "issue-sum-1", identifier: "MT-SUM-1", title: "Summary", state: "In Progress"}
    trace = RunTrace.start!(issue, logs_root: logs_root)

    RawEventStore.append_event!(trace, %{
      "source" => "codex",
      "event_type" => "session_started",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "run_instance_id" => "run-old",
      "thread_id" => "thread-old",
      "turn_id" => "turn-old",
      "session_id" => "thread-old-turn-old"
    })

    RawEventStore.append_event!(trace, %{
      "source" => "codex",
      "event_type" => "session_started",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "run_instance_id" => "run-new",
      "thread_id" => "thread-new",
      "turn_id" => "turn-new",
      "session_id" => "thread-new-turn-new"
    })

    entry = %{
      issue: issue,
      run_trace: trace,
      run_instance_id: "run-new",
      session_id: "thread-new-turn-new",
      thread_id: "thread-new",
      turn_id: "turn-new"
    }

    summary = RunStateStore.summary_for_running_entry(entry)
    assert summary.session_id == "thread-new-turn-new"
    assert summary.thread_id == "thread-new"
    assert summary.turn_id == "turn-new"
  end
end
```

- [ ] **Step 4: 先跑定向测试，确认全部变红**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test \
  test/symphony_elixir/app_server_test.exs \
  test/symphony_elixir/orchestrator_status_test.exs \
  test/symphony_elixir/run_state_store_test.exs
```

Expected:

- `AppServer` interrupt 相关断言失败
- stall gating 相关断言失败
- generation summary 相关断言失败
- 失败应来自合同尚未实现，不应来自 fake codex 脚本语法或测试夹具本身

- [ ] **Step 5: 提交测试合同**

```bash
git add \
  elixir/test/symphony_elixir/app_server_test.exs \
  elixir/test/symphony_elixir/orchestrator_status_test.exs \
  elixir/test/symphony_elixir/run_state_store_test.exs
git commit -m "test(c-50): 锁定 ownership gate 回归合同"
```

### Task 2: 打通 generation plumbing，丢弃旧代消息并修正 summary 同代归并

**Files:**
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/lib/symphony_elixir/run_trace.ex`
- Modify: `elixir/lib/symphony_elixir/event_normalizer.ex`
- Modify: `elixir/lib/symphony_elixir/run_state_store.ex`
- Modify: `elixir/lib/symphony_elixir/state_reducer.ex`
- Test: `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- Test: `elixir/test/symphony_elixir/run_state_store_test.exs`

- [ ] **Step 1: 在 orchestrator running entry 里生成并保存 `run_instance_id`**

在 `dispatch_issue(...)` 受理 issue 时生成 generation，并把它放进 running entry、retry metadata、blocked claim metadata：

```elixir
defp new_run_instance_id do
  "run-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
end

running =
  Map.put(state.running, running_issue.id, %{
    pid: pid,
    ref: ref,
    identifier: running_issue.identifier,
    issue: running_issue,
    run_instance_id: new_run_instance_id(),
    session_id: nil,
    thread_id: nil,
    turn_id: nil,
    release_state: nil,
    run_trace: run_trace,
    started_at: DateTime.utc_now()
  })
```

- [ ] **Step 2: 让 worker 发回的每条 runtime 消息都带 `run_instance_id`**

修改 `AgentRunner` 的 `send_worker_runtime_info/4`、`send_codex_update/3`、`send_run_result/3`，把 generation 放进消息和 trace event：

```elixir
defp send_codex_update(recipient, %Issue{id: issue_id}, run_instance_id, message)
     when is_binary(issue_id) do
  message = Map.put(message, :run_instance_id, run_instance_id)
  RunTrace.record(:codex, message)

  if is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
  end

  :ok
end
```

同时让 `EventNormalizer.normalize!/3` 把 `run_instance_id` 放进标准字段：

```elixir
%{
  "event_id" => event_id,
  "run_id" => trace.run_id,
  "run_instance_id" => Map.get(attrs, :run_instance_id),
  "issue_id" => trace.issue_id,
  "session_id" => session_id,
  "thread_id" => thread_id,
  "turn_id" => turn_id,
  ...
}
```

- [ ] **Step 3: 在 orchestrator 侧丢弃旧代 update / result**

把 `handle_info` 的 runtime 分支改成 generation-aware；任何不匹配当前 running entry `run_instance_id` 的消息都直接忽略：

```elixir
defp current_generation?(%{run_instance_id: expected}, %{run_instance_id: actual})
     when is_binary(expected) and is_binary(actual) do
  expected == actual
end

defp current_generation?(_running_entry, _update), do: false

case Map.get(running, issue_id) do
  %{run_instance_id: _} = running_entry ->
    if current_generation?(running_entry, update) do
      {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)
      ...
    else
      {:noreply, state}
    end
end
```

- [ ] **Step 4: 把 `thread_id` / `turn_id` 也落回 running entry，并让 summary 只 reduce 当前 generation**

修改 `integrate_codex_update/2`，把当前 generation 的 `thread_id`、`turn_id` 与 `session_id` 一起存回 entry：

```elixir
Map.merge(running_entry, %{
  session_id: session_id_for_update(running_entry.session_id, update),
  thread_id: Map.get(update, :thread_id) || running_entry.thread_id,
  turn_id: Map.get(update, :turn_id) || running_entry.turn_id,
  last_codex_timestamp: timestamp,
  last_codex_event: event
})
```

再让 `RunStateStore` 在 reduce 前过滤当前 generation：

```elixir
defp events_for_generation(events, %{run_instance_id: run_instance_id})
     when is_binary(run_instance_id) do
  Enum.filter(events, &(&1["run_instance_id"] == run_instance_id))
end

defp events_for_generation(events, _entry), do: events

def summary_for_running_entry(entry, opts \\ []) when is_map(entry) do
  case Map.get(entry, :run_trace) do
    %RunTrace{} = trace ->
      events =
        trace
        |> RawEventStore.list_events()
        |> events_for_generation(entry)

      summary_from_events(events, Keyword.put(opts, :running_entry, entry))
    ...
  end
end
```

- [ ] **Step 5: 跑 generation 相关定向测试并提交**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test \
  test/symphony_elixir/orchestrator_status_test.exs \
  test/symphony_elixir/run_state_store_test.exs
```

Expected:

- stale generation update 测试通过
- summary generation mismatch 测试通过
- 旧测试不因为新增字段或 nil thread/turn 而回归

```bash
git add \
  elixir/lib/symphony_elixir/agent_runner.ex \
  elixir/lib/symphony_elixir/orchestrator.ex \
  elixir/lib/symphony_elixir/run_trace.ex \
  elixir/lib/symphony_elixir/event_normalizer.ex \
  elixir/lib/symphony_elixir/run_state_store.ex \
  elixir/lib/symphony_elixir/state_reducer.ex \
  elixir/test/symphony_elixir/orchestrator_status_test.exs \
  elixir/test/symphony_elixir/run_state_store_test.exs
git commit -m "fix(c-50): 加入 generation 隔离与同代摘要"
```

### Task 3: 引入协作 stop 路径，修正 stall 的 gate 释放时机

**Files:**
- Modify: `elixir/lib/symphony_elixir/codex/app_server.ex`
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Test: `elixir/test/symphony_elixir/app_server_test.exs`
- Test: `elixir/test/symphony_elixir/orchestrator_status_test.exs`

- [ ] **Step 1: 在 `AppServer.receive_loop/6` 中接收 interrupt 请求并发送 `turn/interrupt`**

给 `run_turn/4` 和 `receive_loop` 传入当前 `thread_id` / `turn_id`，并添加 mailbox 分支：

```elixir
defp receive_loop(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests, thread_id, turn_id) do
  receive do
    {:interrupt_codex_turn, run_instance_id, reason} ->
      send_message(port, %{
        "method" => "turn/interrupt",
        "id" => @turn_interrupt_id,
        "params" => %{
          "threadId" => thread_id,
          "turnId" => turn_id
        }
      })

      emit_message(
        on_message,
        :turn_interrupt_requested,
        %{run_instance_id: run_instance_id, reason: reason, thread_id: thread_id, turn_id: turn_id},
        %{}
      )

      receive_loop(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests, thread_id, turn_id)

    {^port, {:data, {:eol, chunk}}} ->
      ...
  after
    timeout_ms ->
      {:error, :turn_timeout}
  end
end
```

- [ ] **Step 2: 在 running entry 里引入 `release_state` 和 grace timer**

把 running entry 补成可描述“已经请求 stop，但尚未释放”的状态：

```elixir
%{
  pid: pid,
  ref: ref,
  run_instance_id: run_instance_id,
  session_id: nil,
  thread_id: nil,
  turn_id: nil,
  release_state: nil,
  stop_grace_timer_ref: nil,
  turn_terminal_seen?: false,
  ...
}
```

新增 `request_running_issue_stop/4`，只做下面几件事：

```elixir
defp request_running_issue_stop(%State{} = state, issue_id, reason, retry_metadata) do
  case Map.get(state.running, issue_id) do
    %{pid: pid, run_instance_id: run_instance_id} = running_entry ->
      send(pid, {:interrupt_codex_turn, run_instance_id, reason})

      timer_ref =
        Process.send_after(
          self(),
          {:stop_grace_timeout, issue_id, run_instance_id},
          Config.settings!().codex.stop_grace_timeout_ms
        )

      updated_entry =
        Map.merge(running_entry, %{
          release_state: %{status: :interrupt_requested, reason: reason, retry_metadata: retry_metadata},
          stop_grace_timer_ref: timer_ref
        })

      %{state | running: Map.put(state.running, issue_id, updated_entry), claimed: MapSet.put(state.claimed, issue_id)}

    _ ->
      state
  end
end
```

- [ ] **Step 3: 把 stall 路径从“立刻 terminate + retry”改成“先 request stop”**

把 `restart_stalled_issue/5` 改成只发 stop 请求，不再直接 `terminate_running_issue/3`：

```elixir
defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
  elapsed_ms = stall_elapsed_ms(running_entry, now)

  if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
    request_running_issue_stop(
      state,
      issue_id,
      :stall_detected,
      %{
        next_attempt: next_retry_attempt_from_running(running_entry),
        identifier: running_entry.identifier,
        error: "stalled for #{elapsed_ms}ms without codex activity",
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path),
        run_trace: Map.get(running_entry, :run_trace)
      }
    )
  else
    state
  end
end
```

- [ ] **Step 4: 在 `{:DOWN, ...}` 与 `{:stop_grace_timeout, ...}` 上按证据收口**

实现两条规则：

1. `release_state` 存在且 `turn_terminal_seen? == true`
   - worker 退出后允许 retry / recheck / release
2. `release_state` 存在但 `turn_terminal_seen? == false`
   - 不允许自动 retry
   - 转 `blocked_claim(reason: :remote_stop_unconfirmed)`

可直接按这个分支写：

```elixir
defp finalize_requested_stop(state, issue_id, running_entry) do
  retry_metadata = get_in(running_entry, [:release_state, :retry_metadata]) || %{}

  if Map.get(running_entry, :turn_terminal_seen?) do
    schedule_issue_retry(state, issue_id, retry_metadata[:next_attempt], Map.delete(retry_metadata, :next_attempt))
  else
    block_issue_claim(state, issue_id, %{
      attempt: retry_metadata[:next_attempt] || 1,
      identifier: running_entry.identifier,
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      reason: :remote_stop_unconfirmed,
      issue: running_entry.issue,
      run_trace: Map.get(running_entry, :run_trace)
    })
  end
end
```

同时在 `integrate_codex_update/2` 看见 terminal 事件时打标：

```elixir
turn_terminal_seen? =
  Map.get(running_entry, :turn_terminal_seen?, false) or
    event in [:turn_completed, :turn_failed, :turn_cancelled]
```

- [ ] **Step 5: 跑协作 stop / stall 定向测试并提交**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test \
  test/symphony_elixir/app_server_test.exs \
  test/symphony_elixir/orchestrator_status_test.exs
```

Expected:

- interrupt 测试通过
- stall 不再立刻放权
- 无 terminal 证据的 stop 最终进入 `blocked_claim(:remote_stop_unconfirmed)`

```bash
git add \
  elixir/lib/symphony_elixir/codex/app_server.ex \
  elixir/lib/symphony_elixir/agent_runner.ex \
  elixir/lib/symphony_elixir/orchestrator.ex \
  elixir/test/symphony_elixir/app_server_test.exs \
  elixir/test/symphony_elixir/orchestrator_status_test.exs
git commit -m "fix(c-50): 收紧 stall stop 与 ownership gate"
```

### Task 4: 做最终回归、自检和 1+3 零上下文复核

**Files:**
- Read: `docs/superpowers/specs/2026-05-14-c-50-ownership-gate-design.md`
- Read: `docs/superpowers/plans/2026-05-14-c-50-ownership-gate.md`
- Verify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Verify: `elixir/lib/symphony_elixir/agent_runner.ex`
- Verify: `elixir/lib/symphony_elixir/codex/app_server.ex`
- Verify: `elixir/lib/symphony_elixir/run_state_store.ex`
- Verify: `elixir/test/symphony_elixir/app_server_test.exs`
- Verify: `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- Verify: `elixir/test/symphony_elixir/run_state_store_test.exs`

- [ ] **Step 1: 跑最终定向测试组合**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test \
  test/symphony_elixir/app_server_test.exs \
  test/symphony_elixir/orchestrator_status_test.exs \
  test/symphony_elixir/run_state_store_test.exs
```

Expected:

- 全部 PASS
- 没有卡住的 fake worker、端口残留或异常长时间 CPU 飙升

- [ ] **Step 2: 跑局部格式检查**

Run:

```bash
cd elixir && mise exec -- mix format --check-formatted \
  lib/symphony_elixir/agent_runner.ex \
  lib/symphony_elixir/orchestrator.ex \
  lib/symphony_elixir/codex/app_server.ex \
  lib/symphony_elixir/run_trace.ex \
  lib/symphony_elixir/event_normalizer.ex \
  lib/symphony_elixir/run_state_store.ex \
  lib/symphony_elixir/state_reducer.ex \
  test/symphony_elixir/app_server_test.exs \
  test/symphony_elixir/orchestrator_status_test.exs \
  test/symphony_elixir/run_state_store_test.exs
```

Expected:

- 退出码 `0`
- 不触发全量格式化

- [ ] **Step 3: 做 `1+3` 零上下文复核**

执行顺序固定：

```text
1. spec/contract reviewer:
   - 检查实现是否只承诺“单实例 single owner”，没有偷偷承诺跨 worker resume。
2. code quality reviewer:
   - 检查 orchestrator 状态机、timer 清理、message filtering、nil safety。
3. business-logic reviewer:
   - 检查 “stop 无确认 -> blocked_claim” 是否真的阻止重大错误复发。
```

每个 reviewer 都必须只收到：

```text
- C-50 需求
- 本设计文档
- 本计划文档
- 变更 diff
- 测试结果
- 已知剩余风险
```

- [ ] **Step 4: 收口提交**

```bash
git add docs/superpowers/specs/2026-05-14-c-50-ownership-gate-design.md \
  docs/superpowers/plans/2026-05-14-c-50-ownership-gate.md \
  elixir/lib/symphony_elixir/agent_runner.ex \
  elixir/lib/symphony_elixir/orchestrator.ex \
  elixir/lib/symphony_elixir/codex/app_server.ex \
  elixir/lib/symphony_elixir/run_trace.ex \
  elixir/lib/symphony_elixir/event_normalizer.ex \
  elixir/lib/symphony_elixir/run_state_store.ex \
  elixir/lib/symphony_elixir/state_reducer.ex \
  elixir/test/symphony_elixir/app_server_test.exs \
  elixir/test/symphony_elixir/orchestrator_status_test.exs \
  elixir/test/symphony_elixir/run_state_store_test.exs
git commit -m "fix(c-50): 收紧 ownership gate 防止多开线程"
```

- [ ] **Step 5: PR / Linear 前置门禁**

只有满足下面条件，才能进入 PR 与 Linear 收口：

```text
- 本地定向测试已通过
- 1+3 复核已通过
- 推送后 required checks 全绿
- 若 PR 存在 review/comment，已确认没有未处理的 review delta
```

若任一条件不满足：

```text
- 不更新 Linear 状态
- 不宣称问题已闭环
- 继续返工或停工求助
```
