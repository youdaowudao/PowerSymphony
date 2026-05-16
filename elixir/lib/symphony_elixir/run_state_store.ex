defmodule SymphonyElixir.RunStateStore do
  @moduledoc """
  Builds stable run summaries from raw run trace events and orchestrator metadata.
  """

  alias SymphonyElixir.{Config, RawEventStore, RunTrace, StateReducer}

  @spec summary_for_trace(RunTrace.t(), keyword()) :: StateReducer.summary()
  def summary_for_trace(%RunTrace{} = trace, opts \\ []) do
    events = RawEventStore.list_events(trace)
    base_attrs = base_summary_attrs(trace, Keyword.get(opts, :running_entry))

    events =
      events
      |> events_for_generation(Keyword.get(opts, :running_entry))

    summary_from_events(events, Keyword.merge(opts, base_summary: base_attrs, trace: trace))
  rescue
    _error ->
      fallback_summary(base_summary_attrs(trace, Keyword.get(opts, :running_entry)))
  end

  @spec summary_from_events([map()], keyword()) :: StateReducer.summary()
  def summary_from_events(events, opts \\ []) when is_list(events) do
    base_summary =
      opts
      |> Keyword.get(:base_summary, %{})
      |> StateReducer.initial_summary()

    reduced =
      Enum.reduce(events, base_summary, fn event, summary ->
        StateReducer.reduce_event(summary, hydrate_payload(event, Keyword.get(opts, :trace)))
      end)

    finalize_summary(reduced, events, opts)
  rescue
    _error ->
      fallback_summary(Keyword.get(opts, :base_summary, %{}))
  end

  @spec summary_for_running_entry(map(), keyword()) :: StateReducer.summary()
  def summary_for_running_entry(entry, opts \\ []) when is_map(entry) do
    case Map.get(entry, :run_trace) do
      %RunTrace{} = trace ->
        summary_for_trace(trace, Keyword.put(opts, :running_entry, entry))

      _ ->
        summary =
          base_summary_attrs(nil, entry)
          |> fallback_summary()
          |> finalize_from_entry(entry, opts)

        config = Config.settings!()
        now = Keyword.get(opts, :now, DateTime.utc_now())

        Map.put(
          summary,
          :health,
          StateReducer.health_for_summary(
            summary,
            stall_timeout_ms: config.codex.stall_timeout_ms,
            checking_interval_ms: config.polling.checking_interval_ms,
            now: now
          )
        )
    end
  end

  @spec timeline_for_running_entries([map()], String.t(), keyword()) ::
          {:ok, %{items: [map()], next_cursor: String.t() | nil}}
          | {:error, :run_not_found | :duplicate_run | :invalid_cursor | :timeline_unavailable}
  def timeline_for_running_entries(entries, issue_identifier, opts \\ [])
      when is_list(entries) and is_binary(issue_identifier) do
    case matching_timeline_entries(entries, issue_identifier) do
      [] ->
        {:error, :run_not_found}

      [_entry, _other | _rest] ->
        {:error, :duplicate_run}

      [entry] ->
        case Map.get(entry, :run_trace) do
          %RunTrace{} = trace ->
            read_timeline(trace, opts)

          _ ->
            {:error, :run_not_found}
        end
    end
  end

  defp finalize_summary(summary, events, opts) do
    config = Config.settings!()
    now = Keyword.get(opts, :now, DateTime.utc_now())

    finalized =
      summary
      |> ensure_last_event_at(events)
      |> finalize_from_entry(Keyword.get(opts, :running_entry), opts)

    Map.put(
      finalized,
      :health,
      StateReducer.health_for_summary(
        finalized,
        stall_timeout_ms: config.codex.stall_timeout_ms,
        checking_interval_ms: config.polling.checking_interval_ms,
        now: now
      )
    )
  end

  defp finalize_from_entry(summary, nil, _opts), do: summary

  defp finalize_from_entry(summary, entry, _opts) when is_map(entry) do
    issue = Map.get(entry, :issue, %{})
    run_result = Map.get(entry, :run_result, %{})

    summary
    |> maybe_put(:linear_state, Map.get(issue, :state))
    |> maybe_put(:turn_count, Map.get(entry, :turn_count))
    |> maybe_put(:session_id, Map.get(entry, :session_id))
    |> maybe_put(:last_error, Map.get(entry, :last_error) || run_result_error(run_result))
    |> maybe_put_fallback(:last_event_at, Map.get(entry, :last_codex_timestamp))
    |> maybe_put_fallback(:last_event_type, stringify(Map.get(entry, :last_codex_event)))
    |> maybe_put_fallback(:current_action, action_from_entry(entry, summary.current_action))
    |> maybe_override_unknown_phase(entry)
  end

  defp maybe_override_unknown_phase(summary, entry) do
    issue = Map.get(entry, :issue, %{})

    if summary.current_phase == "unknown" and Map.get(issue, :state) == "Checking" do
      %{summary | current_phase: "checking_tracker_state"}
    else
      summary
    end
  end

  defp action_from_entry(entry, current_action) do
    cond do
      current_action == StateReducer.fallback_action() ->
        current_action

      Map.get(entry, :last_codex_message) == nil ->
        current_action

      true ->
        SymphonyElixir.StatusDashboard.humanize_codex_message(Map.get(entry, :last_codex_message))
    end
  end

  defp base_summary_attrs(trace, running_entry) do
    fallback_linear_state =
      cond do
        is_map(running_entry) ->
          running_entry |> entry_issue() |> Map.get(:state)

        is_struct(trace, RunTrace) ->
          "In Progress"
      end

    %{
      linear_state: fallback_linear_state,
      current_phase: "unknown",
      current_action: StateReducer.fallback_action(),
      health: "unknown",
      turn_count: if(is_map(running_entry), do: Map.get(running_entry, :turn_count, 0), else: 0),
      last_error: if(is_map(running_entry), do: Map.get(running_entry, :last_error), else: nil),
      session_id: if(is_map(running_entry), do: Map.get(running_entry, :session_id), else: nil),
      last_event_at: if(is_map(running_entry), do: Map.get(running_entry, :last_codex_timestamp), else: nil)
    }
  end

  defp fallback_summary(attrs) do
    attrs
    |> StateReducer.initial_summary()
    |> Map.put(:current_phase, "unknown")
    |> Map.put(:current_action, StateReducer.fallback_action())
    |> Map.put(:health, "unknown")
  end

  defp ensure_last_event_at(summary, []), do: summary

  defp ensure_last_event_at(summary, events) do
    case summary.last_event_at do
      %DateTime{} -> summary
      _ -> maybe_put(summary, :last_event_at, events |> List.last() |> Map.get("timestamp") |> parse_datetime())
    end
  end

  defp events_for_generation(events, %{run_instance_id: run_instance_id})
       when is_binary(run_instance_id) do
    Enum.filter(events, &(Map.get(&1, "run_instance_id") == run_instance_id))
  end

  defp events_for_generation(events, _running_entry), do: events

  defp hydrate_payload(event, nil), do: event

  defp hydrate_payload(event, %RunTrace{} = trace) do
    case Map.get(event, "payload_ref") do
      ref when is_binary(ref) ->
        payload =
          trace.run_dir
          |> Path.join(ref)
          |> File.read!()
          |> Jason.decode!()

        Map.put(event, "__payload__", payload)

      _ ->
        event
    end
  rescue
    _error ->
      event
  end

  defp entry_issue(entry) when is_map(entry), do: Map.get(entry, :issue, %{})

  defp maybe_put(summary, _key, nil), do: summary
  defp maybe_put(summary, key, value), do: Map.put(summary, key, value)

  defp maybe_put_fallback(summary, key, value) do
    current = Map.get(summary, key)

    if fallback_value?(current) and not is_nil(value) do
      Map.put(summary, key, value)
    else
      summary
    end
  end

  defp parse_datetime(%DateTime{} = value), do: value

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(_value), do: nil

  defp run_result_error(%{status: :failed, reason: reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp run_result_error(_run_result), do: nil

  defp fallback_value?(nil), do: true
  defp fallback_value?("unknown"), do: true
  defp fallback_value?(value), do: value == StateReducer.fallback_action()

  defp matching_timeline_entries(entries, issue_identifier) do
    Enum.filter(entries, fn entry ->
      running_entry_issue_identifier(entry) == issue_identifier
    end)
  end

  defp running_entry_issue_identifier(entry) when is_map(entry) do
    Map.get(entry, :identifier) ||
      entry |> Map.get(:issue, %{}) |> Map.get(:identifier) ||
      Map.get(entry, "identifier") ||
      entry |> Map.get("issue", %{}) |> Map.get("identifier")
  end

  defp read_timeline(%RunTrace{} = trace, opts) do
    case RunTrace.timeline(trace, opts) do
      {:ok, timeline} ->
        {:ok, timeline}

      {:error, :invalid_cursor} ->
        {:error, :invalid_cursor}

      {:error, _reason} ->
        {:error, :timeline_unavailable}
    end
  rescue
    _error ->
      {:error, :timeline_unavailable}
  end
end
