defmodule SymphonyElixir.RunTraceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{
    AgentRunner,
    EventNormalizer,
    LogFile,
    RawEventStore,
    RunStateStore,
    RunTrace,
    StateReducer,
    Tracker,
    Workspace
  }

  alias SymphonyElixir.Linear.Issue

  setup do
    linear_adapter = Application.get_env(:symphony_elixir, :tracker_adapter_override)

    on_exit(fn ->
      if is_nil(linear_adapter) do
        Application.delete_env(:symphony_elixir, :tracker_adapter_override)
      else
        Application.put_env(:symphony_elixir, :tracker_adapter_override, linear_adapter)
      end
    end)

    :ok
  end

  defmodule SuccessTrackerAdapter do
    def create_comment(_issue_id, _body), do: :ok
    def update_issue_state(_issue_id, _state_name), do: :ok
  end

  defp set_logs_root!(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    File.mkdir_p!(logs_root)
    logs_root
  end

  defp run_dirs!(logs_root) do
    Path.join(logs_root, "runs")
    |> File.ls!()
    |> Enum.map(&Path.join(Path.join(logs_root, "runs"), &1))
    |> Enum.sort()
  end

  defp read_trace_events!(run_dir) do
    run_dir
    |> Path.join("trace.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp write_trace_lines!(trace, lines) when is_list(lines) do
    File.write!(trace.trace_file, Enum.map_join(lines, "\n", &Jason.encode!/1) <> "\n")
  end

  test "agent runner creates run trace and records codex plus agent_runner events" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-trace-#{System.unique_integer([:positive])}")
    logs_root = set_logs_root!(Path.join(test_root, "logs"))
    workspace_root = Path.join(test_root, "workspaces")
    template_repo = Path.join(test_root, "source")
    codex_binary = Path.join(test_root, "fake-codex")

    try do
      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# trace")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1) printf '%s\n' '{"id":1,"result":{}}' ;;
          2) printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-trace"}}}' ;;
          3)
            printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-trace"}}}'
            printf '%s\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-trace-1",
        identifier: "MT-TRACE-1",
        title: "Trace it",
        description: "Capture true source",
        state: "In Progress",
        project_id: "project-1",
        project_slug: "project-1"
      }

      assert :ok =
               AgentRunner.run(
                 issue,
                 nil,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )

      [run_dir] = run_dirs!(logs_root)
      assert File.exists?(Path.join(run_dir, "meta.json"))

      events = read_trace_events!(run_dir)
      assert Enum.any?(events, &(&1["source"] == "agent_runner"))
      assert Enum.any?(events, &(&1["source"] == "codex"))
      assert Enum.any?(events, &(&1["event_type"] == "session_started"))
      assert Enum.any?(events, &(&1["event_type"] == "turn_completed"))
      assert Enum.any?(events, &(&1["event_type"] == "worker_runtime_info"))
      assert Enum.any?(events, &(&1["event_type"] == "run_result"))
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace_hook and linear_tool events are normalized into the same trace" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-trace-hooks-#{System.unique_integer([:positive])}")
    logs_root = set_logs_root!(Path.join(test_root, "logs"))
    workspace_root = Path.join(test_root, "workspaces")
    workspace_path = Path.join(workspace_root, "MT-TRACE-2")

    try do
      Application.put_env(:symphony_elixir, :tracker_adapter_override, SuccessTrackerAdapter)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_before_run: "echo before-run",
        hook_after_run: "echo after-run"
      )

      issue = %Issue{
        id: "issue-trace-2",
        identifier: "MT-TRACE-2",
        title: "Trace hooks and tracker",
        description: "Same run trace",
        state: "In Progress"
      }

      trace = RunTrace.start!(issue, logs_root: logs_root, workspace_path: workspace_path)

      RunTrace.with_context(trace, fn ->
        File.mkdir_p!(workspace_path)
        assert :ok = Workspace.run_before_run_hook(workspace_path, issue, nil)
        assert :ok = Tracker.update_issue_state("issue-trace-2", "Done")
        assert :ok = Workspace.run_after_run_hook(workspace_path, issue, nil)
      end)

      events = read_trace_events!(trace.run_dir)
      assert Enum.any?(events, &(&1["source"] == "workspace_hook"))
      assert Enum.any?(events, &(&1["source"] == "linear_tool"))
    after
      File.rm_rf(test_root)
    end
  end

  test "trace write failure does not fail agent runner" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-trace-failure-#{System.unique_integer([:positive])}")
    broken_root = Path.join(test_root, "broken-root")
    workspace_root = Path.join(test_root, "workspaces")
    template_repo = Path.join(test_root, "source")
    codex_binary = Path.join(test_root, "fake-codex")

    try do
      File.mkdir_p!(test_root)
      File.write!(broken_root, "not-a-directory")
      Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(broken_root))

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# trace")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1) printf '%s\n' '{"id":1,"result":{}}' ;;
          2) printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-broken"}}}' ;;
          3)
            printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-broken"}}}'
            printf '%s\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-trace-3",
        identifier: "MT-TRACE-3",
        title: "Trace failure isolation",
        description: "Do not fail",
        state: "In Progress"
      }

      assert :ok =
               AgentRunner.run(
                 issue,
                 nil,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )
    after
      File.rm_rf(test_root)
    end
  end

  test "raw event store lists normalized events for a run trace" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-trace-read-#{System.unique_integer([:positive])}")
    logs_root = set_logs_root!(Path.join(test_root, "logs"))

    try do
      issue = %Issue{id: "issue-trace-4", identifier: "MT-TRACE-4", title: "Read trace", state: "In Progress"}
      trace = RunTrace.start!(issue, logs_root: logs_root)

      RunTrace.with_context(trace, fn ->
        RunTrace.record(:agent_runner, %{event: :worker_attempt_started, summary: "agent_runner:start"})
      end)

      [event] = RawEventStore.list_events(trace)
      assert event["run_id"] == trace.run_id
      assert event["source"] == "agent_runner"
      assert event["event_type"] == "worker_attempt_started"
    after
      File.rm_rf(test_root)
    end
  end

  test "run trace timeline keeps summary_for_trace behavior intact" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-trace-timeline-summary-#{System.unique_integer([:positive])}")
    logs_root = set_logs_root!(Path.join(test_root, "logs"))

    try do
      issue = %Issue{id: "issue-trace-14", identifier: "MT-TRACE-14", title: "Timeline summary", state: "In Progress"}
      trace = RunTrace.start!(issue, logs_root: logs_root)

      RunTrace.with_context(trace, fn ->
        RunTrace.record(:agent_runner, %{
          event: :workspace_prepared,
          summary: "agent_runner:workspace_prepared"
        })
      end)

      summary = RunStateStore.summary_for_trace(trace)
      assert summary.current_phase == "preparing_workspace"
      assert summary.current_action == "agent_runner:workspace_prepared"
      assert summary.health == "normal"
    after
      File.rm_rf(test_root)
    end
  end

  test "run trace timeline defaults to the recent window and returns cursor metadata" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-trace-timeline-#{System.unique_integer([:positive])}")
    logs_root = set_logs_root!(Path.join(test_root, "logs"))

    try do
      issue = %Issue{id: "issue-timeline-1", identifier: "MT-TL-1", title: "Timeline window", state: "In Progress"}
      trace = RunTrace.start!(issue, logs_root: logs_root)

      Enum.each(1..60, fn index ->
        RunTrace.record(trace, :agent_runner, %{
          event: :worker_runtime_info,
          summary: "agent_runner:event-#{index}",
          timestamp: DateTime.add(DateTime.utc_now() |> DateTime.truncate(:millisecond), index, :second),
          payload: %{index: index}
        })
      end)

      {:ok, timeline} = RunTrace.timeline(trace)

      assert length(timeline.items) == 50
      assert List.first(timeline.items).summary == "agent_runner:event-11"
      assert List.last(timeline.items).summary == "agent_runner:event-60"
      assert is_binary(timeline.next_cursor)
      refute timeline.next_cursor == ""

      assert Enum.all?(timeline.items, fn item ->
               is_binary(item.summary) and
                 is_binary(item.event_id) and
                 is_binary(item.timestamp) and
                 is_binary(item.source) and
                 is_list(item.status_markers)
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "run trace timeline cursor loads the previous window and preserves stable item shape" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-trace-timeline-cursor-#{System.unique_integer([:positive])}")
    logs_root = set_logs_root!(Path.join(test_root, "logs"))

    try do
      issue = %Issue{id: "issue-timeline-2", identifier: "MT-TL-2", title: "Timeline cursor", state: "In Progress"}
      trace = RunTrace.start!(issue, logs_root: logs_root)

      Enum.each(1..60, fn index ->
        RunTrace.record(trace, :codex, %{
          event: :turn_completed,
          summary: "codex:event-#{index}",
          timestamp: DateTime.add(DateTime.utc_now() |> DateTime.truncate(:millisecond), index, :second),
          payload: %{index: index}
        })
      end)

      {:ok, first_page} = RunTrace.timeline(trace)
      {:ok, previous_page} = RunTrace.timeline(trace, cursor: first_page.next_cursor)

      assert length(previous_page.items) == 10
      assert List.first(previous_page.items).summary == "codex:event-1"
      assert List.last(previous_page.items).summary == "codex:event-10"
      assert previous_page.next_cursor == nil

      assert Enum.all?(previous_page.items, fn item ->
               is_binary(item.summary) and
                 is_binary(item.event_id) and
                 is_binary(item.timestamp) and
                 is_list(item.status_markers)
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "raw event store payload file preserves payload and raw_payload together" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-trace-payload-#{System.unique_integer([:positive])}")
    logs_root = set_logs_root!(Path.join(test_root, "logs"))

    try do
      issue = %Issue{id: "issue-trace-5", identifier: "MT-TRACE-5", title: "Payload trace", state: "In Progress"}
      trace = RunTrace.start!(issue, logs_root: logs_root)

      RunTrace.with_context(trace, fn ->
        RunTrace.record(:codex, %{
          event: :turn_completed,
          summary: "codex:turn_completed",
          payload: %{"structured" => true},
          raw: %{"jsonrpc" => "2.0", "result" => "ok"}
        })
      end)

      [event] = RawEventStore.list_events(trace)
      payload_path = Path.join(trace.run_dir, event["payload_ref"])
      payload = payload_path |> File.read!() |> Jason.decode!()

      assert payload["payload"] == %{"structured" => true}
      assert payload["raw_payload"] == %{"jsonrpc" => "2.0", "result" => "ok"}
      refute Map.has_key?(event, "payload")
      refute Map.has_key?(event, "raw_payload")
    after
      File.rm_rf(test_root)
    end
  end

  test "codex events normalize identifiers and notification type from nested details payload" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-trace-codex-normalize-#{System.unique_integer([:positive])}")
    logs_root = set_logs_root!(Path.join(test_root, "logs"))

    try do
      issue = %Issue{id: "issue-trace-6", identifier: "MT-TRACE-6", title: "Codex normalize", state: "In Progress"}
      trace = RunTrace.start!(issue, logs_root: logs_root)

      RunTrace.with_context(trace, fn ->
        RunTrace.record(:codex, %{
          event: :notification,
          payload: %{
            "method" => "ignored/top-level",
            "params" => %{"noise" => true}
          },
          details: %{
            "method" => "turn/completed",
            "params" => %{
              "thread" => %{"id" => "thread-nested"},
              "turn" => %{"id" => "turn-nested"}
            }
          },
          raw: "{\"method\":\"turn/completed\"}"
        })
      end)

      [event] = RawEventStore.list_events(trace)
      assert event["event_type"] == "turn_completed"
      assert event["thread_id"] == "thread-nested"
      assert event["turn_id"] == "turn-nested"
      assert event["session_id"] == "thread-nested-turn-nested"
      assert event["summary"] == "codex:turn_completed"
    after
      File.rm_rf(test_root)
    end
  end

  test "codex tool events keep top-level semantic event_type while extracting ids from params.threadId and params.turnId" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-trace-codex-tools-#{System.unique_integer([:positive])}")
    logs_root = set_logs_root!(Path.join(test_root, "logs"))

    try do
      issue = %Issue{id: "issue-trace-8", identifier: "MT-TRACE-8", title: "Codex tools", state: "In Progress"}
      trace = RunTrace.start!(issue, logs_root: logs_root)

      RunTrace.with_context(trace, fn ->
        RunTrace.record(:codex, %{
          event: :tool_call_completed,
          payload: %{
            "method" => "item/tool/call",
            "params" => %{
              "threadId" => "thread-tool",
              "turnId" => "turn-tool",
              "tool" => "linear_graphql"
            }
          },
          details: %{
            "method" => "item/tool/call",
            "params" => %{
              "threadId" => "thread-tool",
              "turnId" => "turn-tool"
            }
          },
          raw: "{\"method\":\"item/tool/call\"}"
        })

        RunTrace.record(:codex, %{
          event: :tool_call_failed,
          payload: %{
            "method" => "item/tool/call",
            "params" => %{
              "threadId" => "thread-tool-failed",
              "turnId" => "turn-tool-failed",
              "tool" => "linear_graphql"
            }
          },
          details: %{
            "method" => "item/tool/call",
            "params" => %{
              "threadId" => "thread-tool-failed",
              "turnId" => "turn-tool-failed"
            }
          }
        })

        RunTrace.record(:codex, %{
          event: :unsupported_tool_call,
          payload: %{
            "method" => "item/tool/call",
            "params" => %{
              "threadId" => "thread-tool-unsupported",
              "turnId" => "turn-tool-unsupported",
              "tool" => "unknown_tool"
            }
          },
          details: %{
            "method" => "item/tool/call",
            "params" => %{
              "threadId" => "thread-tool-unsupported",
              "turnId" => "turn-tool-unsupported"
            }
          }
        })

        RunTrace.record(:codex, %{
          event: :tool_input_auto_answered,
          payload: %{
            "method" => "item/tool/requestUserInput",
            "params" => %{
              "threadId" => "thread-tool-input",
              "turnId" => "turn-tool-input"
            }
          },
          details: %{
            "method" => "item/tool/requestUserInput",
            "params" => %{
              "threadId" => "thread-tool-input",
              "turnId" => "turn-tool-input"
            }
          }
        })
      end)

      events = RawEventStore.list_events(trace)

      assert Enum.any?(events, fn event ->
               event["event_type"] == "tool_call_completed" and
                 event["thread_id"] == "thread-tool" and
                 event["turn_id"] == "turn-tool" and
                 event["session_id"] == "thread-tool-turn-tool"
             end)

      assert Enum.any?(events, fn event ->
               event["event_type"] == "tool_call_failed" and
                 event["thread_id"] == "thread-tool-failed" and
                 event["turn_id"] == "turn-tool-failed" and
                 event["session_id"] == "thread-tool-failed-turn-tool-failed"
             end)

      assert Enum.any?(events, fn event ->
               event["event_type"] == "unsupported_tool_call" and
                 event["thread_id"] == "thread-tool-unsupported" and
                 event["turn_id"] == "turn-tool-unsupported" and
                 event["session_id"] == "thread-tool-unsupported-turn-tool-unsupported"
             end)

      assert Enum.any?(events, fn event ->
               event["event_type"] == "tool_input_auto_answered" and
                 event["thread_id"] == "thread-tool-input" and
                 event["turn_id"] == "turn-tool-input" and
                 event["session_id"] == "thread-tool-input-turn-tool-input"
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "raw event store keeps main event when payload file write fails" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-trace-payload-fallback-#{System.unique_integer([:positive])}")
    logs_root = set_logs_root!(Path.join(test_root, "logs"))

    try do
      issue = %Issue{id: "issue-trace-7", identifier: "MT-TRACE-7", title: "Payload fallback", state: "In Progress"}
      trace = RunTrace.start!(issue, logs_root: logs_root)
      File.rm_rf!(trace.payload_dir)
      File.write!(trace.payload_dir, "blocked")

      RunTrace.with_context(trace, fn ->
        RunTrace.record(:agent_runner, %{
          event: :worker_runtime_info,
          summary: "agent_runner:worker_runtime_info",
          payload: %{worker_host: "worker-a", workspace_path: "/tmp/workspace"}
        })
      end)

      [event] = RawEventStore.list_events(trace)
      assert event["event_type"] == "worker_runtime_info"
      assert event["payload_ref"] == nil
      assert event["payload_size_bytes"] == nil
    after
      File.rm_rf(test_root)
    end
  end

  test "run trace covers default start paths, nested context restore, read_meta and failure isolation" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-trace-branches-#{System.unique_integer([:positive])}")
    logs_root = set_logs_root!(Path.join(test_root, "logs"))

    try do
      issue = %Issue{
        id: "issue-trace-9",
        identifier: "MT-TRACE-9",
        title: "Trace branches",
        state: "In Progress",
        project_id: "project-9",
        project_slug: "project-9"
      }

      assert {:ok, default_trace} = RunTrace.start(issue)
      assert String.starts_with?(default_trace.run_dir, Path.join(logs_root, "runs"))

      started_trace = RunTrace.start!(issue)
      meta = RunTrace.read_meta(started_trace)

      assert meta["run_id"] == started_trace.run_id
      assert meta["project_id"] == "project-9"
      assert meta["project_slug"] == "project-9"
      assert meta["issue_identifier"] == "MT-TRACE-9"

      outer_trace = %{started_trace | worker_host: "outer-worker"}
      inner_trace = %{started_trace | worker_host: "inner-worker"}

      assert RunTrace.current() == nil

      RunTrace.with_context(outer_trace, fn ->
        assert RunTrace.current().worker_host == "outer-worker"

        RunTrace.with_context(inner_trace, fn ->
          assert RunTrace.current().worker_host == "inner-worker"
        end)

        assert RunTrace.current().worker_host == "outer-worker"
      end)

      assert RunTrace.current() == nil

      blocked_run_dir = Path.join(test_root, "blocked-run-dir")
      File.write!(blocked_run_dir, "not-a-directory")
      blocked_trace = %{started_trace | run_dir: blocked_run_dir}

      assert RunTrace.update(blocked_trace, %{worker_host: "blocked-worker"}) == blocked_trace

      blocked_logs_root = Path.join(test_root, "blocked-logs-root")
      File.write!(blocked_logs_root, "not-a-directory")

      assert_raise File.Error, fn ->
        RunTrace.start!(issue, logs_root: blocked_logs_root)
      end
    after
      File.rm_rf(test_root)
    end
  end

  test "event normalizer covers fallback timestamp, event type, event group and nested payload traversal branches" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-trace-normalizer-#{System.unique_integer([:positive])}")
    logs_root = set_logs_root!(Path.join(test_root, "logs"))

    try do
      issue = %Issue{id: "issue-trace-10", identifier: "MT-TRACE-10", title: "Normalize branches", state: "In Progress"}
      trace = RunTrace.start!(issue, logs_root: logs_root)

      payload_method_event =
        EventNormalizer.normalize!(trace, :codex, %{
          event: :notification,
          timestamp: "not-a-datetime",
          payload: %{"method" => "turn/started"}
        })

      assert payload_method_event["event_type"] == "turn_started"
      assert payload_method_event["event_group"] == "codex_activity"
      assert payload_method_event["summary"] == "codex:turn_started"
      assert is_binary(payload_method_event["timestamp"])

      fallback_notification =
        EventNormalizer.normalize!(trace, :codex, %{
          event: :notification,
          payload: %{"params" => "not-a-map"},
          details: "not-a-map"
        })

      assert fallback_notification["event_type"] == "notification"
      assert fallback_notification["thread_id"] == nil
      assert fallback_notification["turn_id"] == nil
      assert fallback_notification["session_id"] == nil

      custom_type_event =
        EventNormalizer.normalize!(trace, :agent_runner, %{
          event_type: "custom_event",
          summary: "agent_runner:custom_event"
        })

      assert custom_type_event["event_type"] == "custom_event"
      assert custom_type_event["event_group"] == "lifecycle"

      default_type_event = EventNormalizer.normalize!(trace, :orchestrator, %{})
      assert default_type_event["event_type"] == "event"
      assert default_type_event["event_group"] == "control"
      assert default_type_event["summary"] == "orchestrator:event"

      unknown_group_event = EventNormalizer.normalize!(trace, :custom_source, %{event_type: "custom_group"})
      assert unknown_group_event["event_type"] == "custom_group"
      assert unknown_group_event["event_group"] == "event"
      assert unknown_group_event["summary"] == "custom_source:custom_group"
    after
      File.rm_rf(test_root)
    end
  end

  test "raw event store streams events, preserves raw-only payloads and run trace record swallows payload encoding failures" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-trace-stream-#{System.unique_integer([:positive])}")
    logs_root = set_logs_root!(Path.join(test_root, "logs"))

    try do
      issue = %Issue{id: "issue-trace-11", identifier: "MT-TRACE-11", title: "Stream trace", state: "In Progress"}
      trace = RunTrace.start!(issue, logs_root: logs_root)

      RunTrace.with_context(trace, fn ->
        RunTrace.record(:codex, %{
          event: :other_message,
          raw: %{"jsonrpc" => "2.0", "method" => "turn/stream"}
        })
      end)

      event = RawEventStore.stream_events(trace) |> Enum.at(0)
      payload_path = Path.join(trace.run_dir, event["payload_ref"])
      payload = payload_path |> File.read!() |> Jason.decode!()

      assert payload == %{"jsonrpc" => "2.0", "method" => "turn/stream"}

      assert :ok =
               RunTrace.record(trace, :agent_runner, %{
                 event: :worker_runtime_info,
                 payload: %{pid: self()}
               })

      persisted_events = RawEventStore.list_events(trace)

      assert Enum.any?(persisted_events, fn persisted_event ->
               persisted_event["event_id"] == event["event_id"]
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "run trace timeline covers empty trace cursor and limit normalization branches" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-trace-timeline-branches-#{System.unique_integer([:positive])}")
    logs_root = set_logs_root!(Path.join(test_root, "logs"))

    try do
      issue = %Issue{id: "issue-timeline-3", identifier: "MT-TL-3", title: "Timeline branches", state: "In Progress"}
      trace = RunTrace.start!(issue, logs_root: logs_root)

      assert {:ok, %{items: [], next_cursor: nil}} = RunTrace.timeline(trace)

      File.write!(trace.trace_file, "")
      assert {:ok, %{items: [], next_cursor: nil}} = RunTrace.timeline(trace)

      for index <- 1..60 do
        RunTrace.record(trace, :agent_runner, %{
          event: :worker_runtime_info,
          summary: "agent_runner:event-#{index}",
          timestamp: DateTime.add(DateTime.utc_now() |> DateTime.truncate(:millisecond), index, :second),
          payload: %{index: index}
        })
      end

      assert {:ok, zero_limit_page} = RunTrace.timeline(trace, limit: 0)
      assert {:ok, negative_limit_page} = RunTrace.timeline(trace, limit: -1)
      assert {:ok, capped_limit_page} = RunTrace.timeline(trace, limit: 100)
      assert {:ok, empty_cursor_page} = RunTrace.timeline(trace, cursor: "")

      assert length(zero_limit_page.items) == 50
      assert length(negative_limit_page.items) == 50
      assert length(capped_limit_page.items) == 50
      assert empty_cursor_page == capped_limit_page
      assert List.first(capped_limit_page.items).summary == "agent_runner:event-11"
      assert List.last(capped_limit_page.items).summary == "agent_runner:event-60"
    after
      File.rm_rf(test_root)
    end
  end

  test "run trace timeline covers legacy cursor base64 cursor invalid cursor and overflow branches" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-trace-timeline-cursor-branches-#{System.unique_integer([:positive])}")
    logs_root = set_logs_root!(Path.join(test_root, "logs"))

    try do
      issue = %Issue{id: "issue-timeline-4", identifier: "MT-TL-4", title: "Timeline cursor branches", state: "In Progress"}
      trace = RunTrace.start!(issue, logs_root: logs_root)

      for index <- 1..6 do
        RunTrace.record(trace, :codex, %{
          event: :turn_completed,
          summary: "codex:event-#{index}",
          timestamp: DateTime.add(DateTime.utc_now() |> DateTime.truncate(:millisecond), index, :second)
        })
      end

      legacy_cursor = "cursor:3"
      encoded_cursor = Jason.encode!(%{"before" => 3, "v" => 1}) |> Base.url_encode64(padding: false)
      string_before_cursor = Jason.encode!(%{"before" => "3", "v" => 1}) |> Base.url_encode64(padding: false)
      invalid_before_cursor = Jason.encode!(%{"before" => %{"bad" => true}, "v" => 1}) |> Base.url_encode64(padding: false)

      assert {:ok, legacy_page} = RunTrace.timeline(trace, cursor: legacy_cursor)
      assert {:ok, encoded_page} = RunTrace.timeline(trace, cursor: encoded_cursor)
      assert {:ok, string_before_page} = RunTrace.timeline(trace, cursor: string_before_cursor)
      assert {:error, :invalid_cursor} = RunTrace.timeline(trace, cursor: "not-a-cursor")
      assert {:error, :invalid_cursor} = RunTrace.timeline(trace, cursor: 123)
      assert {:error, :invalid_cursor} = RunTrace.timeline(trace, cursor: "cursor:abc")
      assert {:error, :invalid_cursor} = RunTrace.timeline(trace, cursor: "cursor:-1")
      assert {:error, :invalid_cursor} = RunTrace.timeline(trace, cursor: "cursor:999")
      assert {:error, :invalid_cursor} = RunTrace.timeline(trace, cursor: invalid_before_cursor)

      assert Enum.map(legacy_page.items, & &1.summary) == ["codex:event-1", "codex:event-2", "codex:event-3"]
      assert encoded_page == legacy_page
      assert string_before_page == legacy_page
      assert legacy_page.next_cursor == nil
    after
      File.rm_rf(test_root)
    end
  end

  test "run trace timeline projects missing summary and status marker branches" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-trace-timeline-project-#{System.unique_integer([:positive])}")
    logs_root = set_logs_root!(Path.join(test_root, "logs"))

    try do
      issue = %Issue{id: "issue-timeline-5", identifier: "MT-TL-5", title: "Timeline projection", state: "In Progress"}
      trace = RunTrace.start!(issue, logs_root: logs_root)

      write_trace_lines!(trace, [
        %{
          "source" => "codex",
          "event_type" => "turn_completed",
          "timestamp" => DateTime.to_iso8601(trace.started_at)
        },
        %{
          "source" => "codex",
          "event_type" => "tool_call_failed",
          "timestamp" => DateTime.to_iso8601(DateTime.add(trace.started_at, 1, :second))
        },
        %{
          "source" => "codex",
          "event_type" => "session_started",
          "timestamp" => DateTime.to_iso8601(DateTime.add(trace.started_at, 2, :second))
        }
      ])

      assert {:ok, page} = RunTrace.timeline(trace)
      assert Enum.map(page.items, & &1.summary) == ["codex:turn_completed", "codex:tool_call_failed", "codex:session_started"]

      [completed, attention, session_started] = page.items
      assert completed.status_markers == ["completed"]
      assert attention.status_markers == ["attention"]
      assert session_started.status_markers == ["session_started"]
    after
      File.rm_rf(test_root)
    end
  end

  test "run state store reduces canonical codex lifecycle into the state triplet" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-state-#{System.unique_integer([:positive])}")
    logs_root = set_logs_root!(Path.join(test_root, "logs"))

    try do
      issue = %Issue{id: "issue-state-1", identifier: "MT-STATE-1", title: "State triplet", state: "In Progress"}
      trace = RunTrace.start!(issue, logs_root: logs_root)
      base_time = DateTime.utc_now() |> DateTime.truncate(:millisecond)

      RunTrace.record(trace, :agent_runner, %{
        event: :workspace_prepared,
        summary: "agent_runner:workspace_prepared",
        timestamp: base_time
      })

      state = RunStateStore.summary_for_trace(trace)
      assert state.current_phase == "preparing_workspace"
      assert state.current_action == "agent_runner:workspace_prepared"
      assert state.health == "normal"
      assert state.linear_state == "In Progress"

      RunTrace.record(trace, :codex, %{
        event: :session_started,
        session_id: "thread-state-1-turn-state-1",
        thread_id: "thread-state-1",
        turn_id: "turn-state-1",
        timestamp: DateTime.add(base_time, 1, :second)
      })

      state = RunStateStore.summary_for_trace(trace)
      assert state.current_phase == "starting_codex_thread"
      assert state.current_action =~ "session started"
      assert state.health == "normal"

      RunTrace.record(trace, :codex, %{
        event: :notification,
        payload: %{
          "method" => "item/reasoning/summaryTextDelta",
          "params" => %{"summaryText" => "comparing retry paths"}
        },
        timestamp: DateTime.add(base_time, 2, :second)
      })

      state = RunStateStore.summary_for_trace(trace)
      assert state.current_phase == "codex_reasoning"
      assert state.current_action =~ "reasoning"

      RunTrace.record(trace, :codex, %{
        event: :notification,
        payload: %{
          "method" => "item/completed",
          "params" => %{
            "item" => %{
              "type" => "file_change",
              "status" => "completed",
              "path" => "lib/example.ex"
            }
          }
        },
        timestamp: DateTime.add(base_time, 3, :second)
      })

      state = RunStateStore.summary_for_trace(trace)
      assert state.current_phase == "codex_editing_files"
      assert state.current_phase != "unknown"

      RunTrace.record(trace, :codex, %{
        event: :tool_call_completed,
        payload: %{
          "method" => "item/tool/call",
          "params" => %{"tool" => "shell"}
        },
        timestamp: DateTime.add(base_time, 4, :second)
      })

      state = RunStateStore.summary_for_trace(trace)
      assert state.current_phase == "codex_running_shell"
      assert state.current_action =~ "dynamic tool call completed"

      RunTrace.record(trace, :codex, %{
        event: :turn_completed,
        payload: %{
          "method" => "turn/completed",
          "params" => %{
            "turn" => %{"status" => "completed"},
            "usage" => %{"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7}
          }
        },
        timestamp: DateTime.add(base_time, 5, :second)
      })

      state = RunStateStore.summary_for_trace(trace)
      assert state.current_phase == "turn_completed"
      assert state.current_action =~ "turn completed"
      assert state.linear_state == "In Progress"
    after
      File.rm_rf(test_root)
    end
  end

  test "state reduction degrades unknown or malformed events to fallback summary" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-state-unknown-#{System.unique_integer([:positive])}")
    logs_root = set_logs_root!(Path.join(test_root, "logs"))

    try do
      issue = %Issue{id: "issue-state-2", identifier: "MT-STATE-2", title: "Unknown event", state: "In Progress"}
      trace = RunTrace.start!(issue, logs_root: logs_root)

      RunTrace.record(trace, :custom_source, %{
        event_type: "mystery_event",
        summary: "custom_source:mystery_event"
      })

      state = RunStateStore.summary_for_trace(trace)
      assert state.current_phase == "unknown"
      assert state.health == "unknown"
      assert state.current_action == "unknown event"

      malformed_state =
        StateReducer.reduce_event(StateReducer.initial_summary(%{linear_state: "In Progress"}), %{
          "source" => "codex",
          "event_type" => nil
        })

      assert malformed_state.current_phase == "unknown"
      assert malformed_state.health == "unknown"
      assert malformed_state.current_action == "unknown event"
    after
      File.rm_rf(test_root)
    end
  end

  test "run state store aligns health thresholds with stall timeout and preserves checking cooldown semantics" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-state-health-#{System.unique_integer([:positive])}")
    logs_root = set_logs_root!(Path.join(test_root, "logs"))

    previous_log_file = Application.get_env(:symphony_elixir, :log_file)

    try do
      write_workflow_file!(Workflow.workflow_file_path(), codex_stall_timeout_ms: 300_000)
      Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
      File.mkdir_p!(logs_root)

      issue = %Issue{id: "issue-state-3", identifier: "MT-STATE-3", title: "Health thresholds", state: "In Progress"}
      trace = RunTrace.start!(issue, logs_root: logs_root)
      now = DateTime.utc_now() |> DateTime.truncate(:millisecond)

      assert health_for_elapsed_ms(trace, 10_000, now) == "normal"
      assert health_for_elapsed_ms(trace, 60_000, now) == "slow"
      assert health_for_elapsed_ms(trace, 180_000, now) == "quiet"
      assert health_for_elapsed_ms(trace, 270_000, now) == "possibly_stalled"
      assert health_for_elapsed_ms(trace, 300_000, now) == "stalled"

      checking_issue = %{issue | state: "Checking", updated_at: DateTime.add(now, -120, :second)}
      checking_trace = RunTrace.start!(checking_issue, logs_root: logs_root)

      RunTrace.record(checking_trace, :orchestrator, %{
        event: :retry_scheduled,
        summary: "orchestrator:retry_scheduled",
        payload: %{issue_id: checking_issue.id, delay_type: "checking_recheck"},
        timestamp: DateTime.add(now, -120, :second)
      })

      checking_state =
        RunStateStore.summary_for_trace(checking_trace,
          running_entry: %{issue: checking_issue},
          now: now
        )

      assert checking_state.linear_state == "Checking"
      assert checking_state.current_phase == "checking_tracker_state"
      assert checking_state.health == "normal"
    after
      if is_nil(previous_log_file) do
        Application.delete_env(:symphony_elixir, :log_file)
      else
        Application.put_env(:symphony_elixir, :log_file, previous_log_file)
      end

      File.rm_rf(test_root)
    end
  end

  test "run state store prefers trace-derived checking state over stale codex metadata" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-state-checking-stale-#{System.unique_integer([:positive])}")
    logs_root = set_logs_root!(Path.join(test_root, "logs"))

    try do
      issue = %Issue{
        id: "issue-state-4",
        identifier: "MT-STATE-4",
        title: "Checking stale metadata",
        state: "Checking",
        updated_at: DateTime.utc_now()
      }

      trace = RunTrace.start!(issue, logs_root: logs_root)

      RunTrace.record(trace, :orchestrator, %{
        event: :retry_scheduled,
        summary: "orchestrator:retry_scheduled",
        payload: %{issue_id: issue.id, delay_type: "checking_recheck"}
      })

      summary =
        RunStateStore.summary_for_trace(trace,
          running_entry: %{
            issue: issue,
            session_id: "thread-stale-turn-stale",
            turn_count: 3,
            last_codex_message: %{event: :notification, message: %{method: "item/reasoning/summaryTextDelta"}},
            last_codex_timestamp: DateTime.add(DateTime.utc_now(), -60, :second),
            last_codex_event: :notification
          }
        )

      assert summary.current_phase == "checking_tracker_state"
      assert summary.current_action =~ "retry"
      assert summary.last_event_type == "retry_scheduled"
    after
      File.rm_rf(test_root)
    end
  end

  test "approval and tool failure flags clear after later normal events" do
    issue = %Issue{id: "issue-state-5", identifier: "MT-STATE-5", title: "Health clears", state: "In Progress"}
    now = DateTime.utc_now() |> DateTime.truncate(:millisecond)

    approval_summary =
      StateReducer.initial_summary(%{linear_state: issue.state})
      |> StateReducer.reduce_event(%{
        "source" => "codex",
        "event_type" => "turn_input_required",
        "timestamp" => DateTime.to_iso8601(now),
        "payload" => %{"method" => "item/tool/requestUserInput"}
      })

    assert StateReducer.health_for_summary(approval_summary,
             now: now,
             stall_timeout_ms: 300_000,
             checking_interval_ms: 600_000
           ) == "needs_attention"

    cleared_approval =
      StateReducer.reduce_event(approval_summary, %{
        "source" => "codex",
        "event_type" => "turn_completed",
        "timestamp" => DateTime.to_iso8601(DateTime.add(now, 1, :second)),
        "payload" => %{"method" => "turn/completed"}
      })

    assert StateReducer.health_for_summary(cleared_approval,
             now: DateTime.add(now, 1, :second),
             stall_timeout_ms: 300_000,
             checking_interval_ms: 600_000
           ) == "normal"

    tool_failure_summary =
      StateReducer.initial_summary(%{linear_state: issue.state})
      |> StateReducer.reduce_event(%{
        "source" => "codex",
        "event_type" => "tool_call_failed",
        "timestamp" => DateTime.to_iso8601(now),
        "payload" => %{"method" => "item/tool/call", "params" => %{"tool" => "shell"}}
      })

    assert StateReducer.health_for_summary(tool_failure_summary,
             now: now,
             stall_timeout_ms: 300_000,
             checking_interval_ms: 600_000
           ) == "tool_blocked"

    cleared_tool_failure =
      StateReducer.reduce_event(tool_failure_summary, %{
        "source" => "codex",
        "event_type" => "tool_call_completed",
        "timestamp" => DateTime.to_iso8601(DateTime.add(now, 1, :second)),
        "payload" => %{"method" => "item/tool/call", "params" => %{"tool" => "shell"}}
      })

    assert StateReducer.health_for_summary(cleared_tool_failure,
             now: DateTime.add(now, 1, :second),
             stall_timeout_ms: 300_000,
             checking_interval_ms: 600_000
           ) == "normal"
  end

  test "run state store computes health from the finalized summary" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-state-final-health-#{System.unique_integer([:positive])}")
    logs_root = set_logs_root!(Path.join(test_root, "logs"))

    try do
      issue = %Issue{id: "issue-state-6", identifier: "MT-STATE-6", title: "Final health", state: "In Progress"}
      trace = RunTrace.start!(issue, logs_root: logs_root)
      now = DateTime.utc_now() |> DateTime.truncate(:millisecond)
      stale_at = DateTime.add(now, -400, :second)

      RunTrace.record(trace, :orchestrator, %{
        event: :retry_scheduled,
        summary: "orchestrator:retry_scheduled",
        payload: %{issue_id: issue.id, delay_type: "checking_recheck"},
        timestamp: now
      })

      summary =
        RunStateStore.summary_for_trace(trace,
          running_entry: %{
            issue: %{issue | state: "Checking", updated_at: DateTime.add(now, -60, :second)},
            last_codex_timestamp: stale_at,
            last_codex_event: :notification,
            last_codex_message: %{event: :notification, message: %{method: "item/reasoning/summaryTextDelta"}}
          },
          now: now
        )

      assert summary.current_phase == "checking_tracker_state"
      assert summary.last_event_at == now
      assert summary.health == "normal"
    after
      File.rm_rf(test_root)
    end
  end

  test "state reducer covers event fallback branches and payload helpers" do
    now = DateTime.utc_now() |> DateTime.truncate(:millisecond)

    summary =
      StateReducer.initial_summary(%{
        "current_phase" => "seed",
        "current_action" => "seed action",
        "health" => "seed health",
        "linear_state" => "In Progress",
        "last_event_at" => DateTime.to_iso8601(now),
        "last_event_type" => "seed_event",
        "thread_id" => "thread-seed",
        "turn_id" => "turn-seed",
        "session_id" => "thread-seed-turn-seed",
        "turn_count" => 2,
        "last_error" => "seed error",
        "fallback_reason" => "seed fallback",
        "retry_delay_type" => "seed delay",
        "approval_pending" => true,
        "tool_failure" => true,
        "run_status" => "running"
      })

    assert summary.current_phase == "seed"
    assert summary.current_action == "seed action"
    assert summary.health == "seed health"
    assert summary.last_event_at == now
    assert summary.approval_pending == true
    assert summary.tool_failure == true

    malformed =
      StateReducer.reduce_event(StateReducer.initial_summary(), %{
        "source" => "codex",
        "event_type" => []
      })

    assert malformed.current_phase == "unknown"
    assert malformed.current_action == "unknown event"

    rescued =
      StateReducer.reduce_event(StateReducer.initial_summary(), %{
        "source" => "codex",
        "event_type" => "notification",
        "payload" => :bad_payload
      })

    assert rescued.current_phase == "unknown"
  end

  test "state reducer covers phase and action routing across codex and runner events" do
    now = DateTime.utc_now() |> DateTime.truncate(:millisecond)
    base = StateReducer.initial_summary(%{linear_state: "In Progress"})

    worker_attempt =
      StateReducer.reduce_event(base, %{
        "source" => "agent_runner",
        "event_type" => "worker_attempt_started",
        "timestamp" => DateTime.to_iso8601(now),
        "payload" => %{"status" => "starting"}
      })

    assert worker_attempt.current_phase == "starting_codex_turn"
    assert worker_attempt.current_action == "unknown event"

    worker_runtime =
      StateReducer.reduce_event(base, %{
        "source" => "agent_runner",
        "event_type" => "worker_runtime_info",
        "timestamp" => DateTime.to_iso8601(now),
        "payload" => %{"worker_host" => "worker-a"}
      })

    assert worker_runtime.current_phase == "starting_codex_turn"

    run_result_failed =
      StateReducer.reduce_event(base, %{
        "source" => "agent_runner",
        "event_type" => "run_result",
        "timestamp" => DateTime.to_iso8601(now),
        "payload" => %{"status" => "failed", "reason" => "turn_timeout"}
      })

    assert run_result_failed.current_phase == "failed"
    assert run_result_failed.run_status == "failed"
    assert run_result_failed.last_error == "turn_timeout"

    run_result_unknown =
      StateReducer.reduce_event(base, %{
        "source" => "agent_runner",
        "event_type" => "run_result",
        "timestamp" => DateTime.to_iso8601(now),
        "payload" => %{"status" => "mystery"}
      })

    assert run_result_unknown.current_phase == "unknown"

    approval_auto_approved =
      StateReducer.reduce_event(base, %{
        "source" => "codex",
        "event_type" => "approval_auto_approved",
        "timestamp" => DateTime.to_iso8601(now),
        "payload" => %{
          "method" => "item/commandExecution/requestApproval",
          "params" => %{"parsedCmd" => "mix test"}
        }
      })

    assert approval_auto_approved.current_phase == "codex_waiting_approval_resolution"
    assert approval_auto_approved.approval_pending == false

    unsupported_tool =
      StateReducer.reduce_event(base, %{
        "source" => "codex",
        "event_type" => "unsupported_tool_call",
        "timestamp" => DateTime.to_iso8601(now),
        "payload" => %{"method" => "item/tool/call", "params" => %{"tool" => "unknown_tool"}}
      })

    assert unsupported_tool.current_phase == "codex_waiting_tool"
    assert unsupported_tool.tool_failure == true
    assert unsupported_tool.health == "normal"
  end

  test "state reducer covers notification and item completion method dispatches" do
    now = DateTime.utc_now() |> DateTime.truncate(:millisecond)
    base = StateReducer.initial_summary(%{linear_state: "In Progress"})

    file_change_approval =
      StateReducer.reduce_event(base, %{
        "source" => "codex",
        "event_type" => "notification",
        "timestamp" => DateTime.to_iso8601(now),
        "payload" => %{"method" => "item/fileChange/requestApproval"}
      })

    assert file_change_approval.current_phase == "codex_waiting_approval_resolution"

    command_output =
      StateReducer.reduce_event(base, %{
        "source" => "codex",
        "event_type" => "notification",
        "timestamp" => DateTime.to_iso8601(now),
        "payload" => %{"method" => "item/commandExecution/outputDelta"}
      })

    assert command_output.current_phase == "codex_running_shell"

    turn_started =
      StateReducer.reduce_event(base, %{
        "source" => "codex",
        "event_type" => "notification",
        "timestamp" => DateTime.to_iso8601(now),
        "payload" => %{"method" => "turn/started"}
      })

    assert turn_started.current_phase == "starting_codex_turn"

    command_completed =
      StateReducer.reduce_event(base, %{
        "source" => "codex",
        "event_type" => "notification",
        "timestamp" => DateTime.to_iso8601(now),
        "payload" => %{"method" => "item/completed", "params" => %{"item" => %{"type" => "command_execution"}}}
      })

    assert command_completed.current_phase == "codex_running_shell"

    reasoning_completed =
      StateReducer.reduce_event(base, %{
        "source" => "codex",
        "event_type" => "notification",
        "timestamp" => DateTime.to_iso8601(now),
        "payload" => %{"method" => "item/completed", "params" => %{"item" => %{"type" => "reasoning"}}}
      })

    assert reasoning_completed.current_phase == "codex_reasoning"

    unknown_completed =
      StateReducer.reduce_event(base, %{
        "source" => "codex",
        "event_type" => "notification",
        "timestamp" => DateTime.to_iso8601(now),
        "payload" => %{"method" => "item/completed", "params" => %{"item" => %{"type" => "mystery"}}}
      })

    assert unknown_completed.current_phase == "codex_waiting_next_event"

    request_user_input =
      StateReducer.reduce_event(base, %{
        "source" => "codex",
        "event_type" => "notification",
        "timestamp" => DateTime.to_iso8601(now),
        "payload" => %{"method" => "item/tool/requestUserInput"}
      })

    assert request_user_input.current_phase == "codex_waiting_user_input_policy"
  end

  test "state reducer health branches cover unknown blocked failed checking and elapsed thresholds" do
    now = DateTime.utc_now() |> DateTime.truncate(:millisecond)

    unknown = StateReducer.initial_summary(%{current_phase: "unknown", fallback_reason: "unknown_event"})

    assert StateReducer.health_for_summary(unknown,
             now: now,
             stall_timeout_ms: 300_000,
             checking_interval_ms: 600_000
           ) == "unknown"

    blocked =
      StateReducer.initial_summary(%{
        current_phase: "codex_waiting_tool",
        tool_failure: true,
        last_event_at: now
      })

    assert StateReducer.health_for_summary(blocked,
             now: now,
             stall_timeout_ms: 300_000,
             checking_interval_ms: 600_000
           ) == "tool_blocked"

    failed =
      StateReducer.initial_summary(%{
        current_phase: "failed",
        run_status: "failed",
        last_event_at: now
      })

    assert StateReducer.health_for_summary(failed,
             now: now,
             stall_timeout_ms: 300_000,
             checking_interval_ms: 600_000
           ) == "codex_error"

    checking =
      StateReducer.initial_summary(%{
        current_phase: "checking_tracker_state",
        linear_state: "Checking",
        last_event_at: DateTime.add(now, -30, :second)
      })

    assert StateReducer.health_for_summary(checking,
             now: now,
             stall_timeout_ms: 300_000,
             checking_interval_ms: 600_000
           ) == "normal"

    fallback_without_reason =
      StateReducer.initial_summary(%{
        current_phase: "unknown",
        last_event_at: DateTime.add(now, -60, :second)
      })

    assert StateReducer.health_for_summary(fallback_without_reason,
             now: now,
             stall_timeout_ms: 300_000,
             checking_interval_ms: 600_000
           ) == "slow"
  end

  test "run state store covers no-trace fallback merging payload hydration and helper branches" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-state-helpers-#{System.unique_integer([:positive])}")
    logs_root = set_logs_root!(Path.join(test_root, "logs"))

    try do
      issue = %Issue{id: "issue-state-7", identifier: "MT-STATE-7", title: "Helper coverage", state: "Checking"}
      trace = RunTrace.start!(issue, logs_root: logs_root)
      payload_file = Path.join(trace.payload_dir, "evt-helper.json")

      File.write!(
        payload_file,
        Jason.encode!(%{
          "payload" => %{"method" => "item/tool/call", "params" => %{"tool" => "shell"}}
        })
      )

      event = %{
        "event_id" => "evt-helper",
        "source" => "codex",
        "event_type" => "notification",
        "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
        "payload_ref" => "payloads/evt-helper.json"
      }

      summary =
        RunStateStore.summary_from_events([event],
          trace: trace,
          base_summary: %{linear_state: "In Progress"}
        )

      assert summary.current_phase == "codex_running_shell"

      fallback_running =
        RunStateStore.summary_for_running_entry(%{
          issue: issue,
          last_codex_timestamp: "not-a-datetime",
          last_codex_event: 123,
          last_codex_message: :bad_message
        })

      assert fallback_running.current_phase == "checking_tracker_state"
      assert fallback_running.current_action == "unknown event"
      assert fallback_running.last_event_type == nil

      no_event_summary = RunStateStore.summary_from_events([], base_summary: %{current_phase: "unknown"})
      assert no_event_summary.current_phase == "unknown"

      missing_trace_summary =
        RunStateStore.summary_for_trace(%{trace | trace_file: Path.join(trace.run_dir, "missing.jsonl")})

      assert missing_trace_summary.current_phase == "unknown"
      assert missing_trace_summary.current_action == "unknown event"
      assert missing_trace_summary.linear_state == "In Progress"
      assert missing_trace_summary.health == "unknown"

      unreadable_trace_summary = RunStateStore.summary_for_trace(%{trace | trace_file: trace.payload_dir})

      assert unreadable_trace_summary.current_phase == "unknown"
      assert unreadable_trace_summary.current_action == "unknown event"
      assert unreadable_trace_summary.linear_state == "In Progress"
      assert unreadable_trace_summary.health == "unknown"

      inline_payload_summary =
        RunStateStore.summary_from_events(
          [
            %{
              "source" => "codex",
              "event_type" => "notification",
              "payload" => %{"method" => "item/tool/call", "params" => %{"tool" => "shell"}}
            }
          ],
          base_summary: %{linear_state: "In Progress"}
        )

      assert inline_payload_summary.current_phase == "codex_running_shell"
    after
      File.rm_rf(test_root)
    end
  end

  test "run state store helper branches cover rescues datetime parsing and fallback summary merging" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-state-rescue-#{System.unique_integer([:positive])}")
    logs_root = set_logs_root!(Path.join(test_root, "logs"))

    try do
      issue = %Issue{id: "issue-state-8", identifier: "MT-STATE-8", title: "Rescue coverage", state: "In Progress"}
      trace = RunTrace.start!(issue, logs_root: logs_root)

      File.rm_rf!(trace.payload_dir)
      File.write!(trace.payload_dir, "blocked")

      File.write!(
        trace.trace_file,
        Jason.encode!(%{
          "event_id" => "evt-bad",
          "source" => "codex",
          "event_type" => "notification",
          "timestamp" => "not-a-datetime",
          "payload_ref" => "payloads/evt-bad.json"
        }) <> "\n"
      )

      summary = RunStateStore.summary_for_trace(trace)
      assert summary.current_phase == "unknown"
      assert summary.current_action == "unknown event"
      assert summary.linear_state == "In Progress"
      assert summary.health == "unknown"
    after
      File.rm_rf(test_root)
    end
  end

  test "state reducer covers remaining helper and method dispatch branches" do
    now = DateTime.utc_now() |> DateTime.truncate(:millisecond)
    base = StateReducer.initial_summary(%{linear_state: "In Progress"})

    checking_completed =
      StateReducer.reduce_event(base, %{
        "source" => "agent_runner",
        "event_type" => "run_result",
        "timestamp" => DateTime.to_iso8601(now),
        "payload" => %{"status" => "completed", "reason" => "issue_entered_checking"}
      })

    assert checking_completed.current_phase == "checking_tracker_state"

    file_change_output =
      StateReducer.reduce_event(base, %{
        "source" => "codex",
        "event_type" => "notification",
        "timestamp" => DateTime.to_iso8601(now),
        "payload" => %{"method" => "item/fileChange/outputDelta"}
      })

    assert file_change_output.current_phase == "codex_editing_files"

    turn_completed_notification =
      StateReducer.reduce_event(base, %{
        "source" => "codex",
        "event_type" => "notification",
        "timestamp" => DateTime.to_iso8601(now),
        "payload" => %{"method" => "turn/completed"}
      })

    assert turn_completed_notification.current_phase == "turn_completed"

    params_type_completed =
      StateReducer.reduce_event(base, %{
        "source" => "codex",
        "event_type" => "notification",
        "timestamp" => DateTime.to_iso8601(now),
        "payload" => %{"method" => "item/completed", "params" => %{"type" => "reasoning"}}
      })

    assert params_type_completed.current_phase == "codex_reasoning"

    ordinary_retry =
      StateReducer.reduce_event(base, %{
        "source" => "orchestrator",
        "event_type" => "retry_scheduled",
        "timestamp" => DateTime.to_iso8601(now),
        "payload" => %{"delay_type" => "continuation"}
      })

    assert ordinary_retry.current_phase == "retry_scheduled"
    assert ordinary_retry.current_action == "retry scheduled"

    default_turn_count =
      StateReducer.reduce_event(base, %{
        "source" => "codex",
        "event_type" => "notification",
        "timestamp" => DateTime.to_iso8601(now),
        "session_id" => 123,
        "payload" => %{"method" => "item/reasoning/textDelta"}
      })

    assert default_turn_count.turn_count == 0

    nil_elapsed_health =
      StateReducer.initial_summary(%{
        current_phase: "codex_reasoning",
        fallback_reason: nil,
        last_event_at: nil
      })

    assert StateReducer.health_for_summary(nil_elapsed_health,
             now: now,
             stall_timeout_ms: "bad",
             checking_interval_ms: 600_000
           ) == "normal"
  end

  test "state reducer helper branches cover payload roots and nested lookup" do
    now = DateTime.utc_now() |> DateTime.truncate(:millisecond)
    base = StateReducer.initial_summary(%{current_phase: "", linear_state: "In Progress"})

    atom_payload_event =
      StateReducer.reduce_event(base, %{
        "source" => "codex",
        "event_type" => "notification",
        "timestamp" => DateTime.to_iso8601(now),
        "payload" => %{payload: %{"method" => "item/tool/call", "params" => %{"tool" => "shell"}}}
      })

    assert atom_payload_event.current_phase == "codex_running_shell"

    no_map_nested =
      StateReducer.reduce_event(base, %{
        "source" => "orchestrator",
        "event_type" => "retry_scheduled",
        "timestamp" => DateTime.to_iso8601(now),
        "payload" => "not-a-map"
      })

    assert no_map_nested.current_phase == "retry_scheduled"

    bad_key_payload =
      StateReducer.reduce_event(base, %{
        "source" => "codex",
        "event_type" => "notification",
        "timestamp" => DateTime.to_iso8601(now),
        "payload" => %{"method" => :bad_atom}
      })

    assert bad_key_payload.current_phase == "unknown"
  end

  test "run state store covers remaining helper branches without trace hydration" do
    now = DateTime.utc_now() |> DateTime.truncate(:millisecond)

    no_trace_summary =
      RunStateStore.summary_for_running_entry(%{
        last_codex_message: %{event: :notification, message: %{method: "item/reasoning/textDelta"}},
        last_codex_timestamp: now,
        last_codex_event: "notification",
        run_result: %{status: :failed, reason: :turn_timeout}
      })

    assert no_trace_summary.last_error == "turn_timeout"
    assert no_trace_summary.last_event_at == now
    assert no_trace_summary.last_event_type == "notification"

    binary_timestamp_summary =
      RunStateStore.summary_from_events([],
        base_summary: %{last_event_at: DateTime.to_iso8601(now), current_phase: "codex_reasoning"}
      )

    assert binary_timestamp_summary.last_event_at == now

    parsed_datetime_from_event =
      RunStateStore.summary_from_events([
        %{
          "source" => "codex",
          "event_type" => [],
          "timestamp" => now
        }
      ])

    assert parsed_datetime_from_event.last_event_at == now

    parsed_iso8601_from_event =
      RunStateStore.summary_from_events([
        %{
          "source" => "codex",
          "event_type" => [],
          "timestamp" => DateTime.to_iso8601(now)
        }
      ])

    assert parsed_iso8601_from_event.last_event_at == now

    unsupported_timestamp_summary =
      RunStateStore.summary_from_events([
        %{
          "source" => "codex",
          "event_type" => [],
          "timestamp" => System.system_time(:second)
        }
      ])

    assert unsupported_timestamp_summary.last_event_at == nil

    unknown_fallback_summary =
      RunStateStore.summary_from_events([],
        base_summary: %{current_phase: "unknown", last_event_type: "unknown"}
      )

    assert unknown_fallback_summary.last_event_type == "unknown"

    overridden_unknown_event_type =
      RunStateStore.summary_from_events([],
        base_summary: %{current_phase: "unknown", last_event_type: "unknown"},
        running_entry: %{last_codex_event: :notification}
      )

    assert overridden_unknown_event_type.last_event_type == "notification"

    rescued_from_events =
      RunStateStore.summary_from_events([123],
        base_summary: %{linear_state: "In Progress", current_action: "custom"}
      )

    assert rescued_from_events.current_phase == "unknown"
    assert rescued_from_events.current_action == "unknown event"
    assert rescued_from_events.linear_state == "In Progress"
    assert rescued_from_events.health == "unknown"

    entry_action =
      RunStateStore.summary_from_events([],
        base_summary: %{current_phase: "codex_reasoning", current_action: "still reasoning"},
        running_entry: %{
          last_codex_message: %{
            method: "item/tool/requestUserInput",
            params: %{question: <<255>>}
          }
        }
      )

    assert entry_action.current_action == "still reasoning"
  end

  test "state reducer covers turn count fallback and blank string inputs" do
    turn_count_reset =
      StateReducer.reduce_event(%{turn_count: "bad"}, %{
        "source" => "codex",
        "event_type" => "session_started",
        "session_id" => "thread-reset-turn-reset"
      })

    assert turn_count_reset.turn_count == 0

    blank_source =
      StateReducer.reduce_event(StateReducer.initial_summary(), %{
        "source" => "  ",
        "event_type" => "notification"
      })

    assert blank_source.current_phase == "unknown"
    assert blank_source.current_action == "unknown event"

    blank_event_type =
      StateReducer.reduce_event(StateReducer.initial_summary(), %{
        "source" => "codex",
        "event_type" => "  "
      })

    assert blank_event_type.current_phase == "unknown"
    assert blank_event_type.current_action == "unknown event"

    assert StateReducer.health_for_summary(StateReducer.initial_summary(%{current_phase: "unknown"})) == "unknown"

    rescued_phase =
      StateReducer.reduce_event(StateReducer.initial_summary(), %{
        "source" => "codex",
        "event_type" => "notification",
        "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
        "payload" => %{"method" => <<255>>}
      })

    assert rescued_phase.current_phase == "unknown"
    assert rescued_phase.current_action == "unknown event"

    user_input_action =
      StateReducer.reduce_event(StateReducer.initial_summary(), %{
        "source" => "codex",
        "event_type" => "notification",
        "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
        "payload" => %{
          "method" => "item/tool/requestUserInput",
          "params" => %{"question" => <<255>>}
        }
      })

    assert user_input_action.current_phase == "codex_waiting_user_input_policy"

    assert user_input_action.current_action ==
             <<
               116,
               111,
               111,
               108,
               32,
               114,
               101,
               113,
               117,
               105,
               114,
               101,
               115,
               32,
               117,
               115,
               101,
               114,
               32,
               105,
               110,
               112,
               117,
               116,
               58,
               32,
               255
             >>

    nested_non_map_item =
      StateReducer.reduce_event(StateReducer.initial_summary(), %{
        "source" => "codex",
        "event_type" => "notification",
        "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
        "payload" => %{"method" => "item/completed", "params" => "not-a-map"}
      })

    assert nested_non_map_item.current_phase == "codex_waiting_next_event"

    params_type_item =
      StateReducer.reduce_event(StateReducer.initial_summary(), %{
        "source" => "codex",
        "event_type" => "notification",
        "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
        "payload" => %{"method" => "item/completed", "params" => %{type: "command_execution"}}
      })

    assert params_type_item.current_phase == "codex_running_shell"
  end

  defp health_for_elapsed_ms(trace, elapsed_ms, now) do
    RunTrace.record(trace, :codex, %{
      event: :notification,
      payload: %{"method" => "item/reasoning/summaryTextDelta", "params" => %{"summaryText" => "still thinking"}},
      timestamp: DateTime.add(now, -div(elapsed_ms, 1_000), :second)
    })

    RunStateStore.summary_for_trace(trace, now: now).health
  end
end
