defmodule SymphonyElixir.OrchestratorStatusTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{LogFile, RawEventStore, RunTrace}

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp assert_eventually(fun, attempts \\ 40)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition was not met in time")

  test "snapshot returns :timeout when snapshot server is unresponsive" do
    server_name = Module.concat(__MODULE__, :UnresponsiveSnapshotServer)
    parent = self()

    pid =
      spawn(fn ->
        Process.register(self(), server_name)
        send(parent, :snapshot_server_ready)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :snapshot_server_ready, 1_000
    assert Orchestrator.snapshot(server_name, 10) == :timeout

    send(pid, :stop)
  end

  test "orchestrator schedule_issue_retry_for_test records retry scheduling into run trace" do
    logs_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-orchestrator-trace-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    File.mkdir_p!(logs_root)

    issue = %Issue{id: "issue-orch-trace", identifier: "MT-TRACE-ORCH", title: "Trace retry", state: "In Progress"}
    trace = RunTrace.start!(issue, logs_root: logs_root)

    orchestrator_name = Module.concat(__MODULE__, :TraceOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      File.rm_rf(logs_root)
    end)

    state = :sys.get_state(pid)

    new_state =
      Orchestrator.schedule_issue_retry_for_test(state, "issue-orch-trace", 1, %{
        identifier: "MT-TRACE-ORCH",
        error: "boom",
        run_trace: trace
      })

    :sys.replace_state(pid, fn _ -> new_state end)

    events = RawEventStore.list_events(trace)
    assert Enum.any?(events, &(&1["source"] == "orchestrator"))
    assert Enum.any?(events, &(&1["event_type"] == "retry_scheduled"))
  end

  test "orchestrator retry scheduling trace survives current generation summary filtering" do
    logs_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-orchestrator-retry-generation-trace-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    File.mkdir_p!(logs_root)

    issue = %Issue{id: "issue-orch-retry-generation", identifier: "MT-TRACE-GEN", title: "Trace retry generation", state: "In Progress"}
    trace = RunTrace.start!(issue, logs_root: logs_root)

    orchestrator_name = Module.concat(__MODULE__, :RetryGenerationTraceOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      File.rm_rf(logs_root)
    end)

    state = :sys.get_state(pid)

    new_state =
      Orchestrator.schedule_issue_retry_for_test(state, issue.id, 1, %{
        identifier: issue.identifier,
        error: "boom",
        run_trace: trace,
        run_instance_id: "run-current"
      })

    :sys.replace_state(pid, fn _ -> new_state end)

    summary =
      SymphonyElixir.RunStateStore.summary_for_running_entry(%{
        issue: issue,
        run_trace: trace,
        run_instance_id: "run-current"
      })

    assert summary.current_phase == "retry_scheduled"
    assert summary.current_action == "retry scheduled"
  end

  test "orchestrator traces accepted dispatch and normal worker exit retry flow" do
    logs_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-orchestrator-dispatch-trace-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    File.mkdir_p!(logs_root)

    issue_id = "issue-orch-dispatch-trace"
    ref = make_ref()
    issue = %Issue{id: issue_id, identifier: "MT-TRACE-ORCH-2", title: "Dispatch trace", state: "In Progress"}
    trace = RunTrace.start!(issue, logs_root: logs_root)

    orchestrator_name = Module.concat(__MODULE__, :DispatchTraceOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      File.rm_rf(logs_root)
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      worker_host: "worker-a",
      workspace_path: "/tmp/orch-trace",
      run_trace: trace,
      retry_attempt: 1,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:agent_run_result, issue_id, %{status: :failed, reason: :turn_timeout, turn_count: 1}})
    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)

    events = RawEventStore.list_events(trace)
    assert Enum.any?(events, &(&1["event_type"] == "worker_exit_normal"))
    assert Enum.any?(events, &(&1["event_type"] == "retry_scheduled"))
  end

  test "orchestrator real retry dispatch path records dispatch_started and dispatch_accepted into one trace" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)

    logs_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-orchestrator-real-dispatch-trace-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(logs_root, "workspaces")

    issue = %Issue{
      id: "issue-orch-real-dispatch",
      identifier: "MT-TRACE-ORCH-REAL",
      title: "Real dispatch trace",
      description: "Drive retry dispatch through the real path",
      state: "In Progress",
      labels: []
    }

    try do
      File.mkdir_p!(logs_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        max_concurrent_agents: 1
      )

      Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      trace = RunTrace.start!(issue, logs_root: logs_root)
      orchestrator_name = Module.concat(__MODULE__, :RealDispatchTraceOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        File.rm_rf(logs_root)
      end)

      initial_state = :sys.get_state(pid)
      retry_token = make_ref()

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:max_concurrent_agents, 1)
        |> Map.put(:claimed, MapSet.new([issue.id]))
        |> Map.put(:retry_attempts, %{
          issue.id => %{
            attempt: 1,
            timer_ref: nil,
            retry_token: retry_token,
            due_at_ms: System.monotonic_time(:millisecond) + 30_000,
            identifier: issue.identifier,
            error: "retrying",
            run_trace: trace
          }
        })
      end)

      send(pid, {:retry_issue, issue.id, retry_token})

      assert_eventually(fn ->
        events = RawEventStore.list_events(trace)

        Enum.any?(events, &(&1["event_type"] == "dispatch_started")) and
          Enum.any?(events, &(&1["event_type"] == "dispatch_accepted"))
      end)

      state = :sys.get_state(pid)

      if running_entry = state.running[issue.id] do
        if Process.alive?(running_entry.pid) do
          Process.exit(running_entry.pid, :shutdown)
        end
      end
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
    end
  end

  test "orchestrator traces premature turn end convergence to blocked claim" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)

    logs_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-orchestrator-blocked-trace-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "In Review"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
    )

    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    File.mkdir_p!(logs_root)

    issue_id = "issue-orch-blocked-trace"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-TRACE-ORCH-3",
      title: "Blocked trace",
      description: "Premature hold convergence",
      state: "In Progress",
      labels: []
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    trace = RunTrace.start!(issue, logs_root: logs_root)

    orchestrator_name = Module.concat(__MODULE__, :BlockedTraceOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if is_nil(previous_memory_issues) do
        Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      else
        Application.put_env(:symphony_elixir, :memory_tracker_issues, previous_memory_issues)
      end

      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      File.rm_rf(logs_root)
    end)

    initial_state = :sys.get_state(pid)
    first_retry_token = make_ref()

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 3,
          timer_ref: nil,
          retry_token: first_retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 1_000,
          identifier: issue.identifier,
          error: "premature turn end",
          delay_type: :premature_turn_end_hold,
          run_trace: trace
        }
      })
    end)

    send(pid, {:retry_issue, issue_id, first_retry_token})
    Process.sleep(50)

    events = RawEventStore.list_events(trace)
    assert Enum.any?(events, &(&1["event_type"] == "retry_converged_to_blocked_claim"))
  end

  test "checking retry uses cooldown interval and remains gated until due" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress", "Checking"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
      checking_interval_ms: 600_000
    )

    state = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new(["issue-orch-checking-cooldown"]),
      blocked_claims: %{},
      retry_attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    issue = %Issue{
      id: "issue-orch-checking-cooldown",
      identifier: "MT-CHECKING-ORCH",
      title: "Checking recheck",
      description: "Dispatch only when cooldown expires",
      state: "Checking",
      labels: []
    }

    scheduled_state =
      Orchestrator.schedule_issue_retry_for_test(state, issue.id, 1, %{
        identifier: issue.identifier,
        delay_type: :checking_recheck
      })

    assert %{attempt: 1, due_at_ms: due_at_ms, delay_type: :checking_recheck} =
             scheduled_state.retry_attempts[issue.id]

    assert is_integer(due_at_ms)
    assert Orchestrator.retry_delay_for_test(1, %{delay_type: :checking_recheck}) == 600_000
    refute Orchestrator.should_dispatch_issue_for_test(issue, scheduled_state)
  end

  test "fresh poll does not immediately dispatch checking issue before updated_at cooldown expires" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress", "Checking"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
      checking_interval_ms: 600_000
    )

    recent_update = DateTime.utc_now()

    issue = %Issue{
      id: "issue-orch-checking-fresh",
      identifier: "MT-CHECKING-FRESH",
      title: "Checking fresh poll gate",
      description: "Fresh poll must respect checking cooldown",
      state: "Checking",
      updated_at: recent_update,
      labels: []
    }

    state = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new(),
      blocked_claims: %{},
      retry_attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "fresh poll allows checking issue dispatch after updated_at cooldown elapsed" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress", "Checking"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
      checking_interval_ms: 600_000
    )

    stale_update = DateTime.add(DateTime.utc_now(), -601, :second)

    issue = %Issue{
      id: "issue-orch-checking-due",
      identifier: "MT-CHECKING-DUE",
      title: "Checking fresh poll due",
      description: "Fresh poll may dispatch once cooldown elapsed",
      state: "Checking",
      updated_at: stale_update,
      labels: []
    }

    state = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new(),
      blocked_claims: %{},
      retry_attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "orchestrator dispatches checking retry in restricted recheck mode after cooldown" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-orchestrator-checking-recheck-#{System.unique_integer([:positive])}"
      )

    logs_root = Path.join(test_root, "logs")
    workspace_root = Path.join(test_root, "workspaces")
    template_repo = Path.join(test_root, "source")
    codex_binary = Path.join(test_root, "fake-codex")
    trace_file = Path.join(test_root, "codex.trace")

    try do
      File.mkdir_p!(logs_root)
      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-orch-checking"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-orch-checking"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      issue =
        %Issue{
          id: "issue-orch-checking-recheck",
          identifier: "MT-ORCH-CHECKING",
          title: "Restricted checking recheck",
          description: "Retry should use restricted checking prompt",
          state: "Checking",
          updated_at: DateTime.add(DateTime.utc_now(), -601, :second),
          labels: []
        }

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        tracker_active_states: ["Todo", "In Progress", "Checking"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
        checking_interval_ms: 600_000,
        max_concurrent_agents: 1
      )

      Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      orchestrator_name = Module.concat(__MODULE__, :CheckingRecheckOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        File.rm_rf(test_root)
      end)

      initial_state = :sys.get_state(pid)
      retry_token = make_ref()

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:claimed, MapSet.new([issue.id]))
        |> Map.put(:retry_attempts, %{
          issue.id => %{
            attempt: 1,
            timer_ref: nil,
            retry_token: retry_token,
            due_at_ms: System.monotonic_time(:millisecond),
            identifier: issue.identifier,
            delay_type: :checking_recheck
          }
        })
      end)

      send(pid, {:retry_issue, issue.id, retry_token})

      assert_eventually(fn ->
        case File.read(trace_file) do
          {:ok, contents} ->
            contents =~ "Checking recheck only:" and
              not String.contains?(contents, "You are an agent for this repository.")

          _ ->
            false
        end
      end)

      state = :sys.get_state(pid)

      if running_entry = state.running[issue.id] do
        if Process.alive?(running_entry.pid) do
          Process.exit(running_entry.pid, :shutdown)
        end
      end
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end
  end

  test "orchestrator snapshot reflects last codex update and session id" do
    issue_id = "issue-snapshot"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-188",
      title: "Snapshot test",
      description: "Capture codex state",
      state: "In Progress",
      url: "https://example.org/issues/MT-188"
    }

    orchestrator_name = Module.concat(__MODULE__, :SnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: started_at
    }

    state_with_issue =
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))

    :sys.replace_state(pid, fn _ -> state_with_issue end)

    now = DateTime.utc_now()

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :session_started,
         session_id: "thread-live-turn-live",
         timestamp: now
       }}
    )

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{method: "some-event"},
         timestamp: now
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.issue_id == issue_id
    assert snapshot_entry.session_id == "thread-live-turn-live"
    assert snapshot_entry.turn_count == 1
    assert snapshot_entry.last_codex_timestamp == now
    assert snapshot_entry.linear_state == "In Progress"
    assert snapshot_entry.current_phase == "unknown"
    assert snapshot_entry.current_action == "unknown event"
    assert snapshot_entry.health == "normal"

    assert snapshot_entry.last_codex_message == %{
             event: :notification,
             message: %{method: "some-event"},
             timestamp: now
           }
  end

  test "orchestrator ignores stale generation codex updates and run results" do
    issue_id = "issue-generation-fence"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-GEN-FENCE",
      title: "Generation fence",
      description: "Drop stale worker messages",
      state: "In Progress",
      url: "https://example.org/issues/MT-GEN-FENCE"
    }

    orchestrator_name = Module.concat(__MODULE__, :GenerationFenceOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      run_instance_id: "run-current",
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      run_result: nil,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    old_at = DateTime.add(started_at, 1, :second)
    current_at = DateTime.add(started_at, 2, :second)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :session_started,
         run_instance_id: "run-old",
         session_id: "thread-old-turn-old",
         thread_id: "thread-old",
         turn_id: "turn-old",
         timestamp: old_at
       }}
    )

    send(
      pid,
      {:agent_run_result, issue_id,
       %{
         status: :failed,
         reason: :turn_timeout,
         turn_count: 9,
         run_instance_id: "run-old"
       }}
    )

    stale_state = :sys.get_state(pid)
    stale_entry = stale_state.running[issue_id]
    assert stale_entry.session_id == nil
    assert Map.get(stale_entry, :thread_id) == nil
    assert Map.get(stale_entry, :turn_id) == nil
    assert stale_entry.run_result == nil
    assert stale_entry.turn_count == 0

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :session_started,
         run_instance_id: "run-current",
         session_id: "thread-current-turn-current",
         thread_id: "thread-current",
         turn_id: "turn-current",
         timestamp: current_at
       }}
    )

    send(
      pid,
      {:agent_run_result, issue_id,
       %{
         status: :completed,
         reason: :issue_inactive,
         turn_count: 1,
         run_instance_id: "run-current"
       }}
    )

    current_state = :sys.get_state(pid)
    current_entry = current_state.running[issue_id]
    assert current_entry.session_id == "thread-current-turn-current"
    assert current_entry.thread_id == "thread-current"
    assert current_entry.turn_id == "turn-current"
    assert current_entry.turn_count == 1

    assert current_entry.run_result == %{
             status: :completed,
             reason: :issue_inactive,
             turn_count: 1,
             run_instance_id: "run-current"
           }
  end

  test "orchestrator snapshot includes reduced run summary fields for checking issues" do
    issue_id = "issue-checking-snapshot"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-CHECKING",
      title: "Checking snapshot",
      description: "Preserve linear state and checking phase",
      state: "Checking",
      updated_at: DateTime.utc_now(),
      url: "https://example.org/issues/MT-CHECKING"
    }

    logs_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-orchestrator-checking-snapshot-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    File.mkdir_p!(logs_root)
    trace = RunTrace.start!(issue, logs_root: logs_root)

    orchestrator_name = Module.concat(__MODULE__, :CheckingSnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      File.rm_rf(logs_root)
    end)

    started_at = DateTime.utc_now()
    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: "thread-checking-turn-checking",
      codex_app_server_pid: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      turn_count: 1,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: started_at,
      run_trace: trace
    }

    RunTrace.record(trace, :orchestrator, %{
      event: :retry_scheduled,
      summary: "orchestrator:retry_scheduled",
      payload: %{issue_id: issue_id, delay_type: "checking_recheck"}
    })

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
      |> Map.put(:next_poll_due_at_ms, System.monotonic_time(:millisecond) + 60_000)
      |> Map.put(:poll_check_in_progress, false)
    end)

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.linear_state == "Checking"
    assert snapshot_entry.current_phase == "checking_tracker_state"
    assert snapshot_entry.health == "normal"
    assert snapshot_entry.current_action =~ "retry"
  end

  test "orchestrator snapshot tracks codex thread totals and app-server pid" do
    issue_id = "issue-usage-snapshot"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-201",
      title: "Usage snapshot test",
      description: "Collect usage stats",
      state: "In Progress",
      url: "https://example.org/issues/MT-201"
    }

    orchestrator_name = Module.concat(__MODULE__, :UsageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    now = DateTime.utc_now()

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :session_started,
         session_id: "thread-usage-turn-usage",
         timestamp: now
       }}
    )

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "thread/tokenUsage/updated",
           "params" => %{
             "tokenUsage" => %{
               "total" => %{"inputTokens" => 12, "outputTokens" => 4, "totalTokens" => 16}
             }
           }
         },
         timestamp: now,
         codex_app_server_pid: "4242"
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_app_server_pid == "4242"
    assert snapshot_entry.codex_input_tokens == 12
    assert snapshot_entry.codex_output_tokens == 4
    assert snapshot_entry.codex_total_tokens == 16
    assert snapshot_entry.turn_count == 1
    assert is_integer(snapshot_entry.runtime_seconds)

    send(pid, {:DOWN, process_ref, :process, self(), :normal})
    completed_state = :sys.get_state(pid)

    assert completed_state.codex_totals.input_tokens == 12
    assert completed_state.codex_totals.output_tokens == 4
    assert completed_state.codex_totals.total_tokens == 16
    assert is_integer(completed_state.codex_totals.seconds_running)
  end

  test "orchestrator snapshot tracks turn completed usage when present" do
    issue_id = "issue-turn-completed-usage"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-202",
      title: "Turn completed usage test",
      description: "Track final turn usage",
      state: "In Progress",
      url: "https://example.org/issues/MT-202"
    }

    orchestrator_name = Module.concat(__MODULE__, :TurnCompletedUsageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :turn_completed,
         payload: %{
           method: "turn/completed",
           usage: %{"input_tokens" => "12", "output_tokens" => 4, "total_tokens" => 16}
         },
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_input_tokens == 12
    assert snapshot_entry.codex_output_tokens == 4
    assert snapshot_entry.codex_total_tokens == 16

    send(pid, {:DOWN, process_ref, :process, self(), :normal})
    completed_state = :sys.get_state(pid)
    assert completed_state.codex_totals.input_tokens == 12
    assert completed_state.codex_totals.output_tokens == 4
    assert completed_state.codex_totals.total_tokens == 16
  end

  test "orchestrator snapshot tracks codex token-count cumulative usage payloads" do
    issue_id = "issue-token-count-snapshot"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-220",
      title: "Token count snapshot test",
      description: "Validate token-count style payloads",
      state: "In Progress",
      url: "https://example.org/issues/MT-220"
    }

    orchestrator_name = Module.concat(__MODULE__, :TokenCountOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    now = DateTime.utc_now()

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "token_count",
               "info" => %{
                 "total_token_usage" => %{
                   "input_tokens" => "2",
                   "output_tokens" => 2,
                   "total_tokens" => 4
                 }
               }
             }
           }
         },
         timestamp: now
       }}
    )

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "token_count",
               "info" => %{
                 "total_token_usage" => %{
                   "prompt_tokens" => 10,
                   "completion_tokens" => 5,
                   "total_tokens" => 15
                 }
               }
             }
           }
         },
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_input_tokens == 10
    assert snapshot_entry.codex_output_tokens == 5
    assert snapshot_entry.codex_total_tokens == 15

    send(pid, {:DOWN, process_ref, :process, self(), :normal})
    completed_state = :sys.get_state(pid)

    assert completed_state.codex_totals.input_tokens == 10
    assert completed_state.codex_totals.output_tokens == 5
    assert completed_state.codex_totals.total_tokens == 15
  end

  test "orchestrator snapshot tracks codex rate-limit payloads" do
    issue_id = "issue-rate-limit-snapshot"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-221",
      title: "Rate limit snapshot test",
      description: "Capture codex rate limit state",
      state: "In Progress",
      url: "https://example.org/issues/MT-221"
    }

    orchestrator_name = Module.concat(__MODULE__, :RateLimitOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    rate_limits = %{
      "limit_id" => "codex",
      "primary" => %{"remaining" => 90, "limit" => 100},
      "secondary" => nil,
      "credits" => %{"has_credits" => false, "unlimited" => false, "balance" => nil}
    }

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "event_msg",
               "payload" => %{
                 "type" => "token_count",
                 "rate_limits" => rate_limits
               }
             }
           }
         },
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.rate_limits == rate_limits
  end

  test "orchestrator token accounting prefers total_token_usage over last_token_usage in token_count payloads" do
    issue_id = "issue-token-precedence"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-222",
      title: "Token precedence",
      description: "Prefer per-event deltas",
      state: "In Progress",
      url: "https://example.org/issues/MT-222"
    }

    orchestrator_name = Module.concat(__MODULE__, :TokenPrecedenceOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "event_msg",
               "payload" => %{
                 "type" => "token_count",
                 "info" => %{
                   "last_token_usage" => %{
                     "input_tokens" => 2,
                     "output_tokens" => 1,
                     "total_tokens" => 3
                   },
                   "total_token_usage" => %{
                     "input_tokens" => 200,
                     "output_tokens" => 100,
                     "total_tokens" => 300
                   }
                 }
               }
             }
           }
         },
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_input_tokens == 200
    assert snapshot_entry.codex_output_tokens == 100
    assert snapshot_entry.codex_total_tokens == 300
  end

  test "orchestrator token accounting accumulates monotonic thread token usage totals" do
    issue_id = "issue-thread-token-usage"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-223",
      title: "Thread token usage",
      description: "Accumulate absolute thread totals",
      state: "In Progress",
      url: "https://example.org/issues/MT-223"
    }

    orchestrator_name = Module.concat(__MODULE__, :ThreadTokenUsageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    for usage <- [
          %{"input_tokens" => 8, "output_tokens" => 3, "total_tokens" => 11},
          %{"input_tokens" => 10, "output_tokens" => 4, "total_tokens" => 14}
        ] do
      send(
        pid,
        {:codex_worker_update, issue_id,
         %{
           event: :notification,
           payload: %{
             "method" => "thread/tokenUsage/updated",
             "params" => %{"tokenUsage" => %{"total" => usage}}
           },
           timestamp: DateTime.utc_now()
         }}
      )
    end

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_input_tokens == 10
    assert snapshot_entry.codex_output_tokens == 4
    assert snapshot_entry.codex_total_tokens == 14
  end

  test "orchestrator token accounting ignores last_token_usage without cumulative totals" do
    issue_id = "issue-last-token-ignored"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-224",
      title: "Last token ignored",
      description: "Ignore delta-only token reports",
      state: "In Progress",
      url: "https://example.org/issues/MT-224"
    }

    orchestrator_name = Module.concat(__MODULE__, :LastTokenIgnoredOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    process_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      started_at: started_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "codex/event/token_count",
           "params" => %{
             "msg" => %{
               "type" => "event_msg",
               "payload" => %{
                 "type" => "token_count",
                 "info" => %{
                   "last_token_usage" => %{
                     "input_tokens" => 8,
                     "output_tokens" => 3,
                     "total_tokens" => 11
                   }
                 }
               }
             }
           }
         },
         timestamp: DateTime.utc_now()
       }}
    )

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [snapshot_entry]} = snapshot
    assert snapshot_entry.codex_input_tokens == 0
    assert snapshot_entry.codex_output_tokens == 0
    assert snapshot_entry.codex_total_tokens == 0
  end

  test "orchestrator snapshot includes retry backoff entries" do
    orchestrator_name = Module.concat(__MODULE__, :RetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    retry_entry = %{
      attempt: 2,
      timer_ref: nil,
      due_at_ms: System.monotonic_time(:millisecond) + 5_000,
      identifier: "MT-500",
      error: "agent exited: :boom"
    }

    initial_state = :sys.get_state(pid)
    new_state = %{initial_state | retry_attempts: %{"mt-500" => retry_entry}}
    :sys.replace_state(pid, fn _ -> new_state end)

    snapshot = GenServer.call(pid, :snapshot)
    assert is_list(snapshot.retrying)

    assert [
             %{
               issue_id: "mt-500",
               attempt: 2,
               due_in_ms: due_in_ms,
               identifier: "MT-500",
               error: "agent exited: :boom"
             }
           ] = snapshot.retrying

    assert due_in_ms > 0
  end

  test "orchestrator snapshot includes poll countdown and checking status" do
    orchestrator_name = Module.concat(__MODULE__, :PollingSnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    now_ms = System.monotonic_time(:millisecond)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | poll_interval_ms: 30_000,
          tick_timer_ref: nil,
          tick_token: make_ref(),
          next_poll_due_at_ms: now_ms + 4_000,
          poll_check_in_progress: false
      }
    end)

    snapshot = GenServer.call(pid, :snapshot)

    assert %{
             polling: %{
               checking?: false,
               poll_interval_ms: 30_000,
               next_poll_in_ms: due_in_ms
             }
           } = snapshot

    assert is_integer(due_in_ms)
    assert due_in_ms >= 0
    assert due_in_ms <= 4_000

    :sys.replace_state(pid, fn state ->
      %{state | poll_check_in_progress: true, next_poll_due_at_ms: nil}
    end)

    snapshot = GenServer.call(pid, :snapshot)
    assert %{polling: %{checking?: true, next_poll_in_ms: nil}} = snapshot
  end

  test "orchestrator triggers an immediate poll cycle shortly after startup" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      poll_interval_ms: 5_000
    )

    orchestrator_name = Module.concat(__MODULE__, :ImmediateStartupOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    assert %{polling: %{checking?: true}} =
             wait_for_snapshot(
               pid,
               fn
                 %{polling: %{checking?: true}} ->
                   true

                 _ ->
                   false
               end,
               500
             )

    assert %{
             polling: %{
               checking?: false,
               next_poll_in_ms: next_poll_in_ms,
               poll_interval_ms: 5_000
             }
           } =
             wait_for_snapshot(
               pid,
               fn
                 %{polling: %{checking?: false, next_poll_in_ms: due_in_ms}}
                 when is_integer(due_in_ms) and due_in_ms <= 5_000 ->
                   true

                 _ ->
                   false
               end,
               500
             )

    assert is_integer(next_poll_in_ms)
    assert next_poll_in_ms >= 0
  end

  test "orchestrator poll cycle resets next refresh countdown after a check" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      poll_interval_ms: 50
    )

    orchestrator_name = Module.concat(__MODULE__, :PollCycleOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | poll_interval_ms: 50,
          poll_check_in_progress: true,
          next_poll_due_at_ms: nil
      }
    end)

    send(pid, :run_poll_cycle)

    snapshot =
      wait_for_snapshot(pid, fn
        %{polling: %{checking?: false, poll_interval_ms: 50, next_poll_in_ms: next_poll_in_ms}}
        when is_integer(next_poll_in_ms) and next_poll_in_ms <= 50 ->
          true

        _ ->
          false
      end)

    assert %{
             polling: %{
               checking?: false,
               poll_interval_ms: 50,
               next_poll_in_ms: next_poll_in_ms
             }
           } = snapshot

    assert is_integer(next_poll_in_ms)
    assert next_poll_in_ms >= 0
    assert next_poll_in_ms <= 50
  end

  test "orchestrator requests cooperative interrupt before retrying stalled workers" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      codex_stall_timeout_ms: 1_000
    )

    issue_id = "issue-stall"
    orchestrator_name = Module.concat(__MODULE__, :StallOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    parent = self()

    worker_pid =
      spawn(fn ->
        receive do
          {:interrupt_codex_turn, "run-stall-1", :stall_detected} ->
            send(parent, :stall_worker_interrupted)

            receive do
              :done -> :ok
            end

          :done ->
            :ok
        end
      end)

    stale_activity_at = DateTime.add(DateTime.utc_now(), -5, :second)
    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: worker_pid,
      ref: Process.monitor(worker_pid),
      identifier: "MT-STALL",
      issue: %Issue{id: issue_id, identifier: "MT-STALL", state: "In Progress"},
      run_instance_id: "run-stall-1",
      session_id: "thread-stall-turn-stall",
      last_codex_message: nil,
      last_codex_timestamp: stale_activity_at,
      last_codex_event: :notification,
      started_at: stale_activity_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(pid, :tick)

    assert_receive :stall_worker_interrupted, 1_000

    state = :sys.get_state(pid)

    assert Process.alive?(worker_pid)
    assert MapSet.member?(state.claimed, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)

    assert %{
             release_state: %{
               status: :stall_interrupt_requested,
               reason: :stall_detected,
               retry_metadata: %{
                 identifier: "MT-STALL",
                 error: "stalled for " <> _
               }
             }
           } = state.running[issue_id]

    refute Orchestrator.should_dispatch_issue_for_test(running_entry.issue, state)
  end

  test "stall preserves local ownership until retry convergence" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      codex_stall_timeout_ms: 1_000
    )

    issue_id = "issue-stop-gate"
    orchestrator_name = Module.concat(__MODULE__, :StopGateOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    parent = self()

    worker_pid =
      spawn(fn ->
        receive do
          {:interrupt_codex_turn, "run-stop-1", :stall_detected} ->
            send(parent, :worker_interrupted)

            receive do
              :done -> :ok
            end
        end
      end)

    on_exit(fn ->
      if Process.alive?(worker_pid) do
        Process.exit(worker_pid, :shutdown)
      end

      if Process.alive?(pid) do
        Process.exit(pid, :normal)
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

    assert_eventually(fn ->
      state = :sys.get_state(pid)

      received_worker_interrupt? =
        receive do
          :worker_interrupted -> true
        after
          0 -> false
        end

      received_worker_interrupt? or
        not MapSet.member?(state.claimed, issue_id) or Map.has_key?(state.retry_attempts, issue_id)
    end)

    state = :sys.get_state(pid)
    assert MapSet.member?(state.claimed, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)
    refute Orchestrator.should_dispatch_issue_for_test(running_entry.issue, state)
  end

  test "stall grace timeout without terminal evidence blocks claim instead of retrying" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      codex_stall_timeout_ms: 10
    )

    issue_id = "issue-stall-unconfirmed"
    orchestrator_name = Module.concat(__MODULE__, :StallUnconfirmedOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    parent = self()

    worker_pid =
      spawn(fn ->
        receive do
          {:interrupt_codex_turn, "run-stall-unconfirmed-1", :stall_detected} ->
            send(parent, :unconfirmed_worker_interrupted)

            receive do
              :done -> :ok
            end
        end
      end)

    on_exit(fn ->
      if Process.alive?(worker_pid) do
        Process.exit(worker_pid, :shutdown)
      end

      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    stale_at = DateTime.add(DateTime.utc_now(), -5, :second)
    initial_state = :sys.get_state(pid)
    issue = %Issue{id: issue_id, identifier: "MT-STALL-UNCONFIRMED", state: "In Progress"}

    running_entry = %{
      pid: worker_pid,
      ref: Process.monitor(worker_pid),
      identifier: issue.identifier,
      issue: issue,
      run_instance_id: "run-stall-unconfirmed-1",
      session_id: "thread-stall-unconfirmed-turn-stall-unconfirmed",
      last_codex_timestamp: stale_at,
      started_at: stale_at
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
    end)

    send(pid, :tick)

    assert_receive :unconfirmed_worker_interrupted, 1_000

    assert_eventually(fn ->
      state = :sys.get_state(pid)

      not Map.has_key?(state.running, issue_id) and
        Map.has_key?(state.blocked_claims, issue_id) and
        not Map.has_key?(state.retry_attempts, issue_id)
    end)

    state = :sys.get_state(pid)
    assert MapSet.member?(state.claimed, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)

    assert %{
             reason: :remote_stop_unconfirmed,
             identifier: "MT-STALL-UNCONFIRMED",
             run_instance_id: "run-stall-unconfirmed-1"
           } = state.blocked_claims[issue_id]

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "stall worker exit without terminal evidence blocks claim instead of retrying" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      codex_stall_timeout_ms: 1_000
    )

    issue_id = "issue-stall-exit-unconfirmed"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :StallExitUnconfirmedOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    issue = %Issue{id: issue_id, identifier: "MT-STALL-EXIT-UNCONFIRMED", state: "In Progress"}
    worker_pid = spawn(fn -> Process.sleep(:infinity) end)

    running_entry = %{
      pid: worker_pid,
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      run_instance_id: "run-stall-exit-unconfirmed-1",
      release_state: %{
        status: :stall_interrupt_requested,
        reason: :stall_detected,
        requested_at: DateTime.utc_now(),
        retry_metadata: %{
          next_attempt: 1,
          identifier: issue.identifier,
          error: "stalled for 5000ms without codex activity",
          run_instance_id: "run-stall-exit-unconfirmed-1"
        }
      },
      turn_terminal_seen?: false,
      session_id: "thread-stall-exit-turn-stall-exit",
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
    end)

    send(pid, {:DOWN, ref, :process, worker_pid, :shutdown})

    assert_eventually(fn ->
      state = :sys.get_state(pid)

      not Map.has_key?(state.running, issue_id) and
        Map.has_key?(state.blocked_claims, issue_id) and
        not Map.has_key?(state.retry_attempts, issue_id)
    end)

    state = :sys.get_state(pid)
    assert MapSet.member?(state.claimed, issue_id)

    assert %{
             reason: :remote_stop_unconfirmed,
             identifier: "MT-STALL-EXIT-UNCONFIRMED",
             run_instance_id: "run-stall-exit-unconfirmed-1"
           } = state.blocked_claims[issue_id]
  end

  test "retry dispatch does not bypass blocked local ownership gate" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)

    issue = %Issue{
      id: "issue-retry-blocked-gate",
      identifier: "MT-RETRY-BLOCKED-GATE",
      title: "Retry blocked gate",
      description: "Retry callback must not bypass blocked local claim",
      state: "In Progress",
      labels: []
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :RetryBlockedGateOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      restore_app_env(:memory_tracker_issues, previous_memory_issues)

      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    retry_token = make_ref()
    initial_state = :sys.get_state(pid)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:claimed, MapSet.new([issue.id]))
      |> Map.put(:blocked_claims, %{
        issue.id => %{
          attempt: 1,
          identifier: issue.identifier,
          reason: :remote_stop_unconfirmed,
          issue: issue,
          run_instance_id: "run-retry-blocked-gate-1"
        }
      })
      |> Map.put(:retry_attempts, %{
        issue.id => %{
          attempt: 1,
          timer_ref: nil,
          retry_token: retry_token,
          due_at_ms: System.monotonic_time(:millisecond),
          identifier: issue.identifier,
          error: "blocked claim should gate retry",
          run_instance_id: "run-retry-blocked-gate-1"
        }
      })
    end)

    send(pid, {:retry_issue, issue.id, retry_token})
    Process.sleep(50)

    state = :sys.get_state(pid)
    refute Map.has_key?(state.running, issue.id)
    assert MapSet.member?(state.claimed, issue.id)
    assert Map.has_key?(state.blocked_claims, issue.id)
    assert %{attempt: 2, retry_token: new_retry_token} = state.retry_attempts[issue.id]
    refute new_retry_token == retry_token
  end

  test "status dashboard renders offline marker to terminal" do
    rendered =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = StatusDashboard.render_offline_status()
      end)

    assert rendered =~ "app_status=offline"
    refute rendered =~ "Timestamp:"
  end

  test "status dashboard renders linear project link in header" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0)

    assert rendered =~ "https://linear.app/project/project/issues"
    refute rendered =~ "Dashboard:"
  end

  test "status dashboard renders dashboard url on its own line when server port is configured" do
    previous_port_override = Application.get_env(:symphony_elixir, :server_port_override)

    on_exit(fn ->
      if is_nil(previous_port_override) do
        Application.delete_env(:symphony_elixir, :server_port_override)
      else
        Application.put_env(:symphony_elixir, :server_port_override, previous_port_override)
      end
    end)

    Application.put_env(:symphony_elixir, :server_port_override, 4000)

    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0)

    assert rendered =~ "│ Project:"
    assert rendered =~ "https://linear.app/project/project/issues"
    assert rendered =~ "│ Dashboard:"
    assert rendered =~ "http://127.0.0.1:4000/"
  end

  test "status dashboard prefers the bound server port and normalizes wildcard hosts" do
    assert StatusDashboard.dashboard_url_for_test("0.0.0.0", 0, 43_123) ==
             "http://127.0.0.1:43123/"

    assert StatusDashboard.dashboard_url_for_test("::1", 4000, nil) ==
             "http://[::1]:4000/"
  end

  test "status dashboard renders next refresh countdown and checking marker" do
    waiting_snapshot =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil,
         polling: %{checking?: false, next_poll_in_ms: 2_000, poll_interval_ms: 30_000}
       }}

    waiting_rendered = StatusDashboard.format_snapshot_content_for_test(waiting_snapshot, 0.0)
    assert waiting_rendered =~ "Next refresh:"
    assert waiting_rendered =~ "2s"

    checking_snapshot =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil,
         polling: %{checking?: true, next_poll_in_ms: nil, poll_interval_ms: 30_000}
       }}

    checking_rendered = StatusDashboard.format_snapshot_content_for_test(checking_snapshot, 0.0)
    assert checking_rendered =~ "checking now…"
  end

  test "status dashboard adds a spacer line before backoff queue when no agents are active" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0)
    plain = Regex.replace(~r/\e\[[0-9;]*m/, rendered, "")

    assert plain =~ ~r/No active agents\r?\n│\s*\r?\n├─ Backoff queue/
  end

  test "status dashboard adds a spacer line before backoff queue when agents are active" do
    snapshot_data =
      {:ok,
       %{
         running: [
           %{
             identifier: "MT-777",
             state: "running",
             session_id: "thread-1234567890",
             codex_app_server_pid: "4242",
             codex_total_tokens: 3_200,
             runtime_seconds: 75,
             turn_count: 7,
             last_codex_event: "turn_completed",
             last_codex_message: %{
               event: :notification,
               message: %{
                 "method" => "turn/completed",
                 "params" => %{"turn" => %{"status" => "completed"}}
               }
             }
           }
         ],
         retrying: [],
         codex_totals: %{
           input_tokens: 90,
           output_tokens: 12,
           total_tokens: 102,
           seconds_running: 75
         },
         rate_limits: nil
       }}

    rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0)
    plain = Regex.replace(~r/\e\[[0-9;]*m/, rendered, "")

    assert plain =~ ~r/MT-777.*\r?\n│\s*\r?\n├─ Backoff queue/s
  end

  test "status dashboard renders an unstyled closing corner when the retry queue is empty" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0)

    assert rendered |> String.split("\n") |> List.last() == "╰─"
  end

  test "status dashboard coalesces rapid updates to one render per interval" do
    dashboard_name = Module.concat(__MODULE__, :RenderDashboard)
    parent = self()
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    orchestrator_child_configured? =
      SymphonyElixir.Application.child_specs(SymphonyElixir.runtime_mode())
      |> Enum.any?(fn
        %{id: SymphonyElixir.Orchestrator} -> true
        SymphonyElixir.Orchestrator -> true
        _ -> false
      end)

    on_exit(fn ->
      if orchestrator_child_configured? and is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    if is_pid(orchestrator_pid) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
    end

    {:ok, pid} =
      StatusDashboard.start_link(
        name: dashboard_name,
        enabled: true,
        refresh_ms: 60_000,
        render_interval_ms: 16,
        render_fun: fn content ->
          send(parent, {:render, System.monotonic_time(:millisecond), content})
        end
      )

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    StatusDashboard.notify_update(dashboard_name)
    assert_receive {:render, first_render_ms, _content}, 200

    :sys.replace_state(pid, fn state ->
      %{state | last_snapshot_fingerprint: :force_next_change, last_rendered_content: nil}
    end)

    StatusDashboard.notify_update(dashboard_name)
    StatusDashboard.notify_update(dashboard_name)

    assert_receive {:render, second_render_ms, _content}, 200
    assert second_render_ms > first_render_ms
    refute_receive {:render, _third_render_ms, _content}, 60
  end

  test "status dashboard computes rolling 5-second token throughput" do
    assert StatusDashboard.rolling_tps([], 10_000, 0) == 0.0

    assert StatusDashboard.rolling_tps([{9_000, 20}], 10_000, 40) == 20.0

    # sample older than 5s is dropped from the window
    assert StatusDashboard.rolling_tps([{4_900, 10}], 10_000, 90) == 0.0

    tps =
      StatusDashboard.rolling_tps(
        [{9_500, 10}, {9_000, 40}, {8_000, 80}],
        10_000,
        95
      )

    assert tps == 7.5
  end

  test "status dashboard throttles tps updates to once per second" do
    {first_second, first_tps} =
      StatusDashboard.throttled_tps(nil, nil, 10_000, [{9_000, 20}], 40)

    {same_second, same_tps} =
      StatusDashboard.throttled_tps(first_second, first_tps, 10_500, [{9_000, 20}], 200)

    assert same_second == first_second
    assert same_tps == first_tps

    {next_second, next_tps} =
      StatusDashboard.throttled_tps(same_second, same_tps, 11_000, [{10_500, 200}], 260)

    assert next_second == 11
    refute next_tps == same_tps
  end

  test "status dashboard formats timestamps at second precision" do
    dt = ~U[2026-02-15 21:36:38.987654Z]
    assert StatusDashboard.format_timestamp_for_test(dt) == "2026-02-15 21:36:38Z"
  end

  test "status dashboard renders 10-minute TPS graph snapshot for steady throughput" do
    now_ms = 600_000
    current_tokens = 6_000

    samples =
      for timestamp <- 575_000..0//-25_000 do
        {timestamp, div(timestamp, 100)}
      end

    assert StatusDashboard.tps_graph_for_test(samples, now_ms, current_tokens) ==
             "████████████████████████"
  end

  test "status dashboard renders 10-minute TPS graph snapshot for ramping throughput" do
    now_ms = 600_000

    rates_per_bucket =
      1..24
      |> Enum.map(&(&1 * 2))

    {current_tokens, samples} = graph_samples_from_rates(rates_per_bucket)

    assert StatusDashboard.tps_graph_for_test(samples, now_ms, current_tokens) ==
             "▁▂▂▂▃▃▃▃▄▄▄▅▅▅▆▆▆▆▇▇▇██▅"
  end

  test "status dashboard keeps historical TPS bars stable within the active bucket" do
    now_ms = 600_000
    current_tokens = 74_400
    next_current_tokens = current_tokens + 120
    samples = graph_samples_for_stability_test(now_ms)

    graph_at_now = StatusDashboard.tps_graph_for_test(samples, now_ms, current_tokens)

    graph_next_second =
      StatusDashboard.tps_graph_for_test(samples, now_ms + 1_000, next_current_tokens)

    historical_changes =
      graph_at_now
      |> String.graphemes()
      |> Enum.zip(String.graphemes(graph_next_second))
      |> Enum.take(23)
      |> Enum.count(fn {left, right} -> left != right end)

    assert historical_changes == 0
  end

  test "application configures a rotating file logger handler" do
    assert {:ok, handler_config} = :logger.get_handler_config(:symphony_disk_log)
    assert handler_config.module == :logger_disk_log_h

    disk_config = handler_config.config
    assert disk_config.type == :wrap
    assert is_list(disk_config.file)
    assert disk_config.max_no_bytes > 0
    assert disk_config.max_no_files > 0
  end

  test "status dashboard renders last codex message in EVENT column" do
    row =
      StatusDashboard.format_running_summary_for_test(%{
        identifier: "MT-233",
        state: "running",
        session_id: "thread-1234567890",
        codex_app_server_pid: "4242",
        codex_total_tokens: 12,
        runtime_seconds: 15,
        last_codex_event: :notification,
        last_codex_message: %{
          event: :notification,
          message: %{
            "method" => "turn/completed",
            "params" => %{"turn" => %{"status" => "completed"}}
          }
        }
      })

    plain = Regex.replace(~r/\e\[[\\d;]*m/, row, "")

    assert plain =~ "turn completed (completed)"
    assert (String.split(plain, "turn completed (completed)") |> length()) - 1 == 1
    refute plain =~ " notification "
  end

  test "status dashboard strips ANSI and control bytes from last codex message" do
    payload =
      "cmd: " <>
        <<27>> <>
        "[31mRED" <>
        <<27>> <>
        "[0m" <>
        <<0>> <>
        " after\nline"

    row =
      StatusDashboard.format_running_summary_for_test(%{
        identifier: "MT-898",
        state: "running",
        session_id: "thread-1234567890",
        codex_app_server_pid: "4242",
        codex_total_tokens: 12,
        runtime_seconds: 15,
        last_codex_event: :notification,
        last_codex_message: payload
      })

    plain = Regex.replace(~r/\e\[[0-9;]*m/, row, "")

    assert plain =~ "cmd: RED after line"
    refute plain =~ <<27>>
    refute plain =~ <<0>>
  end

  test "status dashboard expands running row to requested terminal width" do
    terminal_columns = 140

    row =
      StatusDashboard.format_running_summary_for_test(
        %{
          identifier: "MT-598",
          state: "running",
          session_id: "thread-1234567890",
          codex_app_server_pid: "4242",
          codex_total_tokens: 123,
          runtime_seconds: 15,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              "method" => "turn/completed",
              "params" => %{"turn" => %{"status" => "completed"}}
            }
          }
        },
        terminal_columns
      )

    plain = Regex.replace(~r/\e\[[\d;]*m/, row, "")

    assert String.length(plain) == terminal_columns
    assert plain =~ "turn completed (completed)"
  end

  test "status dashboard humanizes full codex app-server event set" do
    event_cases = [
      {"turn/started", %{"params" => %{"turn" => %{"id" => "turn-1"}}}, "turn started"},
      {"turn/completed", %{"params" => %{"turn" => %{"status" => "completed"}}}, "turn completed"},
      {"turn/diff/updated", %{"params" => %{"diff" => "line1\nline2"}}, "turn diff updated"},
      {"turn/plan/updated", %{"params" => %{"plan" => [%{"step" => "a"}, %{"step" => "b"}]}}, "plan updated"},
      {"thread/tokenUsage/updated",
       %{
         "params" => %{
           "usage" => %{"input_tokens" => 8, "output_tokens" => 3, "total_tokens" => 11}
         }
       }, "thread token usage updated"},
      {"item/started",
       %{
         "params" => %{
           "item" => %{
             "id" => "item-1234567890abcdef",
             "type" => "commandExecution",
             "status" => "running"
           }
         }
       }, "item started: command execution"},
      {"item/completed", %{"params" => %{"item" => %{"type" => "fileChange", "status" => "completed"}}}, "item completed: file change"},
      {"item/agentMessage/delta", %{"params" => %{"delta" => "hello"}}, "agent message streaming"},
      {"item/plan/delta", %{"params" => %{"delta" => "step"}}, "plan streaming"},
      {"item/reasoning/summaryTextDelta", %{"params" => %{"summaryText" => "thinking"}}, "reasoning summary streaming"},
      {"item/reasoning/summaryPartAdded", %{"params" => %{"summaryText" => "section"}}, "reasoning summary section added"},
      {"item/reasoning/textDelta", %{"params" => %{"textDelta" => "reason"}}, "reasoning text streaming"},
      {"item/commandExecution/outputDelta", %{"params" => %{"outputDelta" => "ok"}}, "command output streaming"},
      {"item/fileChange/outputDelta", %{"params" => %{"outputDelta" => "changed"}}, "file change output streaming"},
      {"item/commandExecution/requestApproval", %{"params" => %{"parsedCmd" => "git status"}}, "command approval requested (git status)"},
      {"item/fileChange/requestApproval", %{"params" => %{"fileChangeCount" => 2}}, "file change approval requested (2 files)"},
      {"item/tool/call", %{"params" => %{"tool" => "linear_graphql"}}, "dynamic tool call requested (linear_graphql)"},
      {"item/tool/requestUserInput", %{"params" => %{"question" => "Continue?"}}, "tool requires user input: Continue?"}
    ]

    Enum.each(event_cases, fn {method, payload, expected_fragment} ->
      message = Map.put(payload, "method", method)

      humanized =
        StatusDashboard.humanize_codex_message(%{event: :notification, message: message})

      assert humanized =~ expected_fragment
    end)
  end

  test "status dashboard humanizes dynamic tool wrapper events" do
    completed = %{
      event: :tool_call_completed,
      message: %{
        payload: %{"method" => "item/tool/call", "params" => %{"name" => "linear_graphql"}}
      }
    }

    failed = %{
      event: :tool_call_failed,
      message: %{
        payload: %{"method" => "item/tool/call", "params" => %{"tool" => "linear_graphql"}}
      }
    }

    unsupported = %{
      event: :unsupported_tool_call,
      message: %{
        payload: %{"method" => "item/tool/call", "params" => %{"tool" => "unknown_tool"}}
      }
    }

    assert StatusDashboard.humanize_codex_message(completed) =~
             "dynamic tool call completed (linear_graphql)"

    assert StatusDashboard.humanize_codex_message(failed) =~
             "dynamic tool call failed (linear_graphql)"

    assert StatusDashboard.humanize_codex_message(unsupported) =~
             "unsupported dynamic tool call rejected (unknown_tool)"
  end

  test "status dashboard unwraps nested codex payload envelopes" do
    wrapped = %{
      event: :notification,
      message: %{
        payload: %{
          "method" => "turn/completed",
          "params" => %{
            "turn" => %{"status" => "completed"},
            "usage" => %{"input_tokens" => "10", "output_tokens" => 2, "total_tokens" => 12}
          }
        },
        raw: "{\"method\":\"turn/completed\"}"
      }
    }

    assert StatusDashboard.humanize_codex_message(wrapped) =~ "turn completed"
    assert StatusDashboard.humanize_codex_message(wrapped) =~ "in 10"
  end

  test "status dashboard uses shell command line as exec command status text" do
    message = %{
      event: :notification,
      message: %{
        "method" => "codex/event/exec_command_begin",
        "params" => %{"msg" => %{"command" => "git status --short"}}
      }
    }

    assert StatusDashboard.humanize_codex_message(message) == "git status --short"
  end

  test "status dashboard formats auto-approval updates from codex" do
    message = %{
      event: :approval_auto_approved,
      message: %{
        payload: %{
          "method" => "item/commandExecution/requestApproval",
          "params" => %{"parsedCmd" => "mix test"}
        },
        decision: "acceptForSession"
      }
    }

    humanized = StatusDashboard.humanize_codex_message(message)
    assert humanized =~ "command approval requested"
    assert humanized =~ "auto-approved"
  end

  test "status dashboard formats auto-answered tool input updates from codex" do
    message = %{
      event: :tool_input_auto_answered,
      message: %{
        payload: %{
          "method" => "item/tool/requestUserInput",
          "params" => %{"question" => "Continue?"}
        },
        answer: "This is a non-interactive session. Operator input is unavailable."
      }
    }

    humanized = StatusDashboard.humanize_codex_message(message)
    assert humanized =~ "tool requires user input"
    assert humanized =~ "auto-answered"
  end

  test "status dashboard enriches wrapper reasoning and message streaming events with payload context" do
    reasoning_message = %{
      event: :notification,
      message: %{
        "method" => "codex/event/agent_reasoning",
        "params" => %{
          "msg" => %{
            "payload" => %{"summaryText" => "compare retry paths for Linear polling"}
          }
        }
      }
    }

    message_delta = %{
      event: :notification,
      message: %{
        "method" => "codex/event/agent_message_delta",
        "params" => %{
          "msg" => %{
            "payload" => %{"delta" => "writing workpad reconciliation update"}
          }
        }
      }
    }

    fallback_reasoning = %{
      event: :notification,
      message: %{
        "method" => "codex/event/agent_reasoning",
        "params" => %{"msg" => %{"payload" => %{}}}
      }
    }

    assert StatusDashboard.humanize_codex_message(reasoning_message) =~
             "reasoning update: compare retry paths for Linear polling"

    assert StatusDashboard.humanize_codex_message(message_delta) =~
             "agent message streaming: writing workpad reconciliation update"

    assert StatusDashboard.humanize_codex_message(fallback_reasoning) == "reasoning update"
  end

  test "application stop renders offline status" do
    rendered =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = SymphonyElixir.Application.stop(:normal)
      end)

    assert rendered =~ "app_status=offline"
    refute rendered =~ "Timestamp:"
  end

  defp wait_for_snapshot(pid, predicate, timeout_ms \\ 200) when is_function(predicate, 1) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_snapshot(pid, predicate, deadline_ms)
  end

  defp do_wait_for_snapshot(pid, predicate, deadline_ms) do
    snapshot = GenServer.call(pid, :snapshot)

    if predicate.(snapshot) do
      snapshot
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        flunk("timed out waiting for orchestrator snapshot state: #{inspect(snapshot)}")
      else
        Process.sleep(5)
        do_wait_for_snapshot(pid, predicate, deadline_ms)
      end
    end
  end

  defp graph_samples_from_rates(rates_per_bucket) do
    bucket_ms = 25_000

    {timestamp, tokens, samples} =
      Enum.reduce(rates_per_bucket, {0, 0, []}, fn rate, {timestamp, tokens, acc} ->
        next_timestamp = timestamp + bucket_ms
        next_tokens = tokens + trunc(rate * bucket_ms / 1000)
        {next_timestamp, next_tokens, [{timestamp, tokens} | acc]}
      end)

    {tokens, [{timestamp, tokens} | samples]}
  end

  defp graph_samples_for_stability_test(now_ms) do
    rates_per_bucket = Enum.map(1..24, &(&1 * 5))
    bucket_ms = 25_000

    rate_for_timestamp = fn timestamp ->
      bucket_idx = min(div(max(timestamp, 0), bucket_ms), 23)
      Enum.at(rates_per_bucket, bucket_idx, 0)
    end

    0..(now_ms - 1_000)//1_000
    |> Enum.reduce({0, []}, fn timestamp, {tokens, acc} ->
      next_tokens = tokens + rate_for_timestamp.(timestamp)
      {next_tokens, [{timestamp, next_tokens} | acc]}
    end)
    |> elem(1)
  end
end
