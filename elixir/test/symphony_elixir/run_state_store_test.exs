defmodule SymphonyElixir.RunStateStoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{LogFile, RawEventStore, RunStateStore, RunTrace}

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
end
