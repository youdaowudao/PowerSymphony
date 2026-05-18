defmodule SymphonyElixir.RunStateStoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{LogFile, RawEventStore, RunStateStore, RunTrace}

  defp with_logs_root(label, fun) when is_binary(label) and is_function(fun, 1) do
    previous_log_file = Application.get_env(:symphony_elixir, :log_file)

    on_exit(fn ->
      if is_nil(previous_log_file) do
        Application.delete_env(:symphony_elixir, :log_file)
      else
        Application.put_env(:symphony_elixir, :log_file, previous_log_file)
      end
    end)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-run-state-store-#{label}-#{System.unique_integer([:positive])}"
      )

    try do
      logs_root = Path.join(test_root, "logs")
      File.mkdir_p!(logs_root)
      Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
      fun.(logs_root)
    after
      File.rm_rf(test_root)
    end
  end

  defp issue(identifier) do
    %Issue{
      id: "issue-#{identifier}",
      identifier: identifier,
      title: "Issue #{identifier}",
      state: "In Progress"
    }
  end

  defp timeline_entry(identifier, trace, extra \\ %{}) do
    Map.merge(
      %{
        issue: issue(identifier),
        identifier: identifier,
        run_trace: trace,
        run_instance_id: "run-#{identifier}"
      },
      extra
    )
  end

  test "summary_for_running_entry ignores events from older run_instance_id" do
    previous_log_file = Application.get_env(:symphony_elixir, :log_file)

    on_exit(fn ->
      if is_nil(previous_log_file) do
        Application.delete_env(:symphony_elixir, :log_file)
      else
        Application.put_env(:symphony_elixir, :log_file, previous_log_file)
      end
    end)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-run-state-store-#{System.unique_integer([:positive])}"
      )

    try do
      logs_root = Path.join(test_root, "logs")
      File.mkdir_p!(logs_root)
      Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))

      issue = %Issue{
        id: "issue-sum-1",
        identifier: "MT-SUM-1",
        title: "Summary",
        state: "In Progress"
      }

      trace = RunTrace.start!(issue, logs_root: logs_root)

      current_generation_started_at = DateTime.utc_now()

      RawEventStore.append(trace, %{
        "source" => "codex",
        "event_type" => "session_started",
        "timestamp" => DateTime.to_iso8601(current_generation_started_at),
        "run_instance_id" => "run-new",
        "thread_id" => "thread-new",
        "turn_id" => "turn-new",
        "session_id" => "thread-new-turn-new"
      })

      old_generation_late_event_at = DateTime.add(current_generation_started_at, 1, :second)

      RawEventStore.append(trace, %{
        "source" => "codex",
        "event_type" => "turn_completed",
        "timestamp" => DateTime.to_iso8601(old_generation_late_event_at),
        "run_instance_id" => "run-old",
        "thread_id" => "thread-old",
        "turn_id" => "turn-old",
        "session_id" => "thread-old-turn-old"
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
      assert summary.current_phase == "starting_codex_thread"
      assert summary.current_action == "session started"
      assert summary.last_event_at == current_generation_started_at
    after
      File.rm_rf(test_root)
    end
  end

  test "timeline_for_running_entries returns the recent window for the unique running entry" do
    with_logs_root("timeline-success", fn logs_root ->
      trace = RunTrace.start!(issue("MT-TL-STATE-1"), logs_root: logs_root)

      RunTrace.record(trace, :orchestrator, %{
        event: :retry_scheduled,
        summary: "retry later",
        timestamp: ~U[2026-05-16 03:00:00Z]
      })

      assert {:ok, %{items: [item], next_cursor: nil}} =
               RunStateStore.timeline_for_running_entries(
                 [timeline_entry("MT-TL-STATE-1", trace)],
                 "MT-TL-STATE-1"
               )

      assert item.summary == "retry later"
      assert item.event_type == "retry_scheduled"
      assert item.source == "orchestrator"
    end)
  end

  test "timeline_for_running_entries keeps items when running entry lacks binary run_instance_id" do
    with_logs_root("timeline-run-instance-fallback", fn logs_root ->
      trace = RunTrace.start!(issue("MT-TL-FALLBACK"), logs_root: logs_root)

      RunTrace.record(trace, :orchestrator, %{
        event: :retry_scheduled,
        summary: "kept item",
        run_instance_id: "run-current",
        timestamp: ~U[2026-05-16 03:05:00Z]
      })

      assert {:ok, %{items: [item], next_cursor: nil}} =
               RunStateStore.timeline_for_running_entries(
                 [timeline_entry("MT-TL-FALLBACK", trace, %{run_instance_id: nil})],
                 "MT-TL-FALLBACK"
               )

      assert item.summary == "kept item"
      assert item.event_type == "retry_scheduled"
    end)
  end

  test "timeline_for_running_entries returns run_not_found when the current running entry has no run trace" do
    assert {:error, :run_not_found} =
             RunStateStore.timeline_for_running_entries(
               [
                 %{
                   issue: issue("MT-TL-STATE-2"),
                   identifier: "MT-TL-STATE-2",
                   run_trace: nil
                 }
               ],
               "MT-TL-STATE-2"
             )
  end

  test "timeline_for_running_entries returns run_not_found when issue identifiers do not match" do
    entries = [
      %{
        issue: issue("MT-TL-OTHER-ATOM")
      },
      %{
        "issue" => %{"identifier" => "MT-TL-OTHER-STRING"}
      }
    ]

    assert {:error, :run_not_found} =
             RunStateStore.timeline_for_running_entries(entries, "MT-NOT-FOUND")
  end

  test "timeline_for_running_entries returns duplicate_run when multiple running entries share the same issue identifier" do
    with_logs_root("timeline-duplicate", fn logs_root ->
      first_trace = RunTrace.start!(issue("MT-TL-DUP"), logs_root: logs_root)
      second_trace = RunTrace.start!(issue("MT-TL-DUP"), logs_root: logs_root)

      assert {:error, :duplicate_run} =
               RunStateStore.timeline_for_running_entries(
                 [
                   timeline_entry("MT-TL-DUP", first_trace),
                   timeline_entry("MT-TL-DUP", second_trace, %{run_instance_id: "run-second"})
                 ],
                 "MT-TL-DUP"
               )
    end)
  end

  test "timeline_for_running_entries keeps a missing trace file as an empty timeline" do
    with_logs_root("timeline-empty", fn logs_root ->
      trace = RunTrace.start!(issue("MT-TL-EMPTY"), logs_root: logs_root)
      _ = File.rm(trace.trace_file)

      assert {:ok, %{items: [], next_cursor: nil}} =
               RunStateStore.timeline_for_running_entries(
                 [timeline_entry("MT-TL-EMPTY", trace)],
                 "MT-TL-EMPTY"
               )
    end)
  end

  test "timeline_for_running_entries maps invalid cursors and decode failures separately" do
    with_logs_root("timeline-errors", fn logs_root ->
      invalid_cursor_trace = RunTrace.start!(issue("MT-TL-CURSOR"), logs_root: logs_root)

      RunTrace.record(invalid_cursor_trace, :codex, %{
        event: :turn_completed,
        summary: "completed",
        timestamp: ~U[2026-05-16 03:10:00Z]
      })

      assert {:error, :invalid_cursor} =
               RunStateStore.timeline_for_running_entries(
                 [timeline_entry("MT-TL-CURSOR", invalid_cursor_trace)],
                 "MT-TL-CURSOR",
                 cursor: "cursor:999"
               )

      broken_trace = RunTrace.start!(issue("MT-TL-BROKEN"), logs_root: logs_root)
      File.write!(broken_trace.trace_file, "{bad json}\n")

      assert {:error, :timeline_unavailable} =
               RunStateStore.timeline_for_running_entries(
                 [timeline_entry("MT-TL-BROKEN", broken_trace)],
                 "MT-TL-BROKEN"
               )
    end)
  end

  test "event detail and surface for running entries stay scoped to the current running trace" do
    with_logs_root("event-detail-success", fn logs_root ->
      current_trace = RunTrace.start!(issue("MT-EVT-STATE-1"), logs_root: logs_root)
      older_trace = RunTrace.start!(issue("MT-EVT-STATE-1"), logs_root: logs_root)

      RunTrace.record(current_trace, :codex, %{
        event: :notification,
        run_instance_id: "run-MT-EVT-STATE-1",
        summary: "current event",
        session_id: "thread-current-turn-current",
        thread_id: "thread-current",
        turn_id: "turn-current",
        payload: %{
          "method" => "item/commandExecution/outputDelta",
          "params" => %{"tool" => "shell", "parsedCmd" => "mix test", "outputDelta" => "ok"}
        }
      })

      RunTrace.record(older_trace, :codex, %{
        event: :notification,
        run_instance_id: "run-MT-OTHER",
        summary: "older event",
        payload: %{
          "method" => "item/tool/requestUserInput",
          "params" => %{"question" => "legacy"}
        }
      })

      [current_event] = RawEventStore.list_events(current_trace)
      [older_event] = RawEventStore.list_events(older_trace)

      entries = [
        timeline_entry("MT-EVT-STATE-1", current_trace),
        timeline_entry("MT-OTHER", older_trace)
      ]

      assert {:ok, detail} =
               RunStateStore.event_detail_for_running_entries(
                 entries,
                 "MT-EVT-STATE-1",
                 current_event["event_id"]
               )

      assert detail.event.event_id == current_event["event_id"]
      assert detail.context.thread_id == "thread-current"

      assert {:ok, surface} =
               RunStateStore.event_surface_for_running_entries(
                 entries,
                 "MT-EVT-STATE-1",
                 current_event["event_id"],
                 "shell"
               )

      assert surface.surface == "shell"
      assert surface.content =~ "mix test"

      assert {:error, :event_not_found} =
               RunStateStore.event_detail_for_running_entries(
                 entries,
                 "MT-EVT-STATE-1",
                 older_event["event_id"]
               )
    end)
  end

  test "event detail and surface for running entries preserve duplicate run and unavailable errors" do
    with_logs_root("event-detail-errors", fn logs_root ->
      trace = RunTrace.start!(issue("MT-EVT-STATE-2"), logs_root: logs_root)

      RunTrace.record(trace, :codex, %{
        event: :notification,
        run_instance_id: "run-MT-EVT-STATE-2",
        summary: "question",
        payload: %{"method" => "item/tool/requestUserInput", "params" => %{"question" => "Continue?"}}
      })

      [event] = RawEventStore.list_events(trace)
      payload_path = Path.join(trace.run_dir, event["payload_ref"])

      duplicate_entries = [
        timeline_entry("MT-EVT-DUP", trace),
        timeline_entry("MT-EVT-DUP", trace, %{run_instance_id: "run-second"})
      ]

      assert {:error, :duplicate_run} =
               RunStateStore.event_detail_for_running_entries(
                 duplicate_entries,
                 "MT-EVT-DUP",
                 event["event_id"]
               )

      assert {:error, :run_not_found} =
               RunStateStore.event_detail_for_running_entries([], "MT-EVT-STATE-2", event["event_id"])

      File.write!(payload_path, "{bad json}")

      assert {:error, :event_detail_unavailable} =
               RunStateStore.event_detail_for_running_entries(
                 [timeline_entry("MT-EVT-STATE-2", trace)],
                 "MT-EVT-STATE-2",
                 event["event_id"]
               )

      assert {:error, :event_surface_unavailable} =
               RunStateStore.event_surface_for_running_entries(
                 [timeline_entry("MT-EVT-STATE-2", trace)],
                 "MT-EVT-STATE-2",
                 event["event_id"],
                 "prompt"
               )
    end)
  end

  test "event detail for running entries ignores events from older attempts in the same trace" do
    with_logs_root("event-detail-run-instance", fn logs_root ->
      trace = RunTrace.start!(issue("MT-EVT-STATE-3"), logs_root: logs_root)

      File.write!(
        trace.trace_file,
        Enum.map_join(
          [
            %{
              "event_id" => "evt-shared",
              "run_instance_id" => "run-old",
              "source" => "codex",
              "event_type" => "notification",
              "timestamp" => "2026-05-17T01:00:00Z"
            },
            %{
              "event_id" => "evt-current",
              "run_instance_id" => "run-current",
              "source" => "codex",
              "event_type" => "notification",
              "timestamp" => "2026-05-17T01:01:00Z"
            }
          ],
          "\n",
          &Jason.encode!/1
        ) <> "\n"
      )

      entry = timeline_entry("MT-EVT-STATE-3", trace, %{run_instance_id: "run-current"})

      assert {:error, :event_not_found} =
               RunStateStore.event_detail_for_running_entries([entry], "MT-EVT-STATE-3", "evt-shared")

      assert {:ok, detail} =
               RunStateStore.event_detail_for_running_entries([entry], "MT-EVT-STATE-3", "evt-current")

      assert detail.event.event_id == "evt-current"
    end)
  end

  test "summary and timeline stay aligned with the current run generation after retry" do
    with_logs_root("timeline-generation-filter", fn logs_root ->
      trace = RunTrace.start!(issue("MT-TL-GEN"), logs_root: logs_root)

      File.write!(
        trace.trace_file,
        Enum.map_join(
          [
            %{
              "event_id" => "evt-current-start",
              "run_instance_id" => "run-current",
              "source" => "orchestrator",
              "event_type" => "dispatch_started",
              "summary" => "dispatch current",
              "timestamp" => "2026-05-17T01:00:00Z"
            },
            %{
              "event_id" => "evt-old-late",
              "run_instance_id" => "run-old",
              "source" => "codex",
              "event_type" => "turn_completed",
              "summary" => "old late completion",
              "timestamp" => "2026-05-17T01:01:00Z"
            },
            %{
              "event_id" => "evt-current-retry",
              "run_instance_id" => "run-current",
              "source" => "orchestrator",
              "event_type" => "retry_scheduled",
              "summary" => "retry current",
              "timestamp" => "2026-05-17T01:02:00Z"
            }
          ],
          "\n",
          &Jason.encode!/1
        ) <> "\n"
      )

      entry = timeline_entry("MT-TL-GEN", trace, %{run_instance_id: "run-current"})

      summary = RunStateStore.summary_for_running_entry(entry)
      assert summary.current_phase == "retry_scheduled"
      assert summary.current_action == "retry scheduled"

      assert {:ok, %{items: items, next_cursor: nil}} =
               RunStateStore.timeline_for_running_entries([entry], "MT-TL-GEN")

      assert Enum.map(items, & &1.event_id) == ["evt-current-start", "evt-current-retry"]
      assert Enum.map(items, & &1.summary) == ["dispatch current", "retry current"]
    end)
  end

  test "raw event store streams an empty list when trace file metadata is missing" do
    assert [] = RawEventStore.stream_events(%{}) |> Enum.to_list()
  end
end
