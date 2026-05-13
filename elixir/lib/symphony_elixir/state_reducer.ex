defmodule SymphonyElixir.StateReducer do
  @moduledoc """
  Reduces normalized run events into a stable state summary for runtime observers.
  """

  alias SymphonyElixir.StatusDashboard

  @type summary :: %{
          current_phase: String.t(),
          current_action: String.t(),
          health: String.t(),
          linear_state: String.t() | nil,
          last_event_at: DateTime.t() | nil,
          last_event_type: String.t() | nil,
          thread_id: String.t() | nil,
          turn_id: String.t() | nil,
          session_id: String.t() | nil,
          turn_count: non_neg_integer(),
          last_error: String.t() | nil,
          fallback_reason: String.t() | nil,
          retry_delay_type: String.t() | nil,
          approval_pending: boolean(),
          tool_failure: boolean(),
          run_status: String.t() | nil
        }

  @fallback_phase "unknown"
  @fallback_action "unknown event"
  @fallback_health "unknown"

  @spec initial_summary(map()) :: summary()
  def initial_summary(attrs \\ %{}) when is_map(attrs) do
    %{
      current_phase: string_or_default(Map.get(attrs, :current_phase) || Map.get(attrs, "current_phase"), @fallback_phase),
      current_action: string_or_default(Map.get(attrs, :current_action) || Map.get(attrs, "current_action"), @fallback_action),
      health: string_or_default(Map.get(attrs, :health) || Map.get(attrs, "health"), @fallback_health),
      linear_state: Map.get(attrs, :linear_state) || Map.get(attrs, "linear_state"),
      last_event_at: datetime_value(Map.get(attrs, :last_event_at) || Map.get(attrs, "last_event_at")),
      last_event_type: Map.get(attrs, :last_event_type) || Map.get(attrs, "last_event_type"),
      thread_id: Map.get(attrs, :thread_id) || Map.get(attrs, "thread_id"),
      turn_id: Map.get(attrs, :turn_id) || Map.get(attrs, "turn_id"),
      session_id: Map.get(attrs, :session_id) || Map.get(attrs, "session_id"),
      turn_count: integer_or_zero(Map.get(attrs, :turn_count) || Map.get(attrs, "turn_count")),
      last_error: Map.get(attrs, :last_error) || Map.get(attrs, "last_error"),
      fallback_reason: Map.get(attrs, :fallback_reason) || Map.get(attrs, "fallback_reason"),
      retry_delay_type: Map.get(attrs, :retry_delay_type) || Map.get(attrs, "retry_delay_type"),
      approval_pending: boolean_value(Map.get(attrs, :approval_pending) || Map.get(attrs, "approval_pending")),
      tool_failure: boolean_value(Map.get(attrs, :tool_failure) || Map.get(attrs, "tool_failure")),
      run_status: Map.get(attrs, :run_status) || Map.get(attrs, "run_status")
    }
  end

  @spec reduce_event(summary(), map()) :: summary()
  def reduce_event(summary, event) when is_map(summary) and is_map(event) do
    summary = Map.merge(initial_summary(), summary)

    with source when is_binary(source) <- string_present(event["source"]),
         event_type when is_binary(event_type) <- string_present(event["event_type"]) do
      timestamp = datetime_value(event["timestamp"]) || summary.last_event_at
      payload = event_payload(event)
      phase = phase_for_event(source, event_type, payload)

      summary
      |> Map.put(:current_phase, phase)
      |> Map.put(:current_action, current_action_for_event(source, event_type, payload, phase))
      |> Map.put(:health, if(phase == @fallback_phase, do: @fallback_health, else: "normal"))
      |> Map.put(:fallback_reason, if(phase == @fallback_phase, do: "unknown_event", else: nil))
      |> Map.put(:last_event_at, timestamp)
      |> Map.put(:last_event_type, event_type)
      |> maybe_put(:thread_id, string_present(event["thread_id"]))
      |> maybe_put(:turn_id, string_present(event["turn_id"]))
      |> maybe_put(:session_id, string_present(event["session_id"]))
      |> Map.put(:turn_count, turn_count_for_event(summary.turn_count, event_type, string_present(event["session_id"])))
      |> merge_context(source, event_type, payload)
    else
      _ ->
        unknown_summary(summary)
    end
  rescue
    _error ->
      unknown_summary(summary)
  end

  @spec health_for_summary(summary(), keyword()) :: String.t()
  def health_for_summary(summary, opts \\ []) when is_map(summary) and is_list(opts) do
    stall_timeout_ms = positive_integer(Keyword.get(opts, :stall_timeout_ms), 300_000)
    now = Keyword.get(opts, :now, DateTime.utc_now()) |> datetime_value() || DateTime.utc_now()
    checking_interval_ms = positive_integer(Keyword.get(opts, :checking_interval_ms), 600_000)

    cond do
      summary.current_phase == @fallback_phase and summary.fallback_reason == "unknown_event" ->
        @fallback_health

      summary.current_phase == @fallback_phase and is_nil(summary.last_event_at) ->
        @fallback_health

      summary.tool_failure ->
        "tool_blocked"

      summary.approval_pending ->
        "needs_attention"

      summary.run_status == "failed" ->
        "codex_error"

      checking_cooldown?(summary, now, checking_interval_ms) ->
        "normal"

      true ->
        elapsed_ms = elapsed_ms(summary.last_event_at, now)
        compute_elapsed_health(elapsed_ms, stall_timeout_ms)
    end
  end

  @spec fallback_action() :: String.t()
  def fallback_action, do: @fallback_action

  defp merge_context(summary, "orchestrator", "retry_scheduled", payload) do
    delay_type = nested_string(payload, ["delay_type"])
    phase = if delay_type == "checking_recheck", do: "checking_tracker_state", else: "retry_scheduled"

    summary
    |> Map.put(:current_phase, phase)
    |> Map.put(:retry_delay_type, delay_type)
    |> Map.put(:approval_pending, false)
    |> Map.put(:tool_failure, false)
  end

  defp merge_context(summary, "agent_runner", "run_result", payload) do
    status = nested_string(payload, ["status"])
    reason = nested_string(payload, ["reason"])

    summary
    |> Map.put(:run_status, status)
    |> Map.put(:approval_pending, false)
    |> Map.put(:tool_failure, false)
    |> maybe_put(:last_error, if(status == "failed", do: reason, else: nil))
  end

  defp merge_context(summary, "codex", event_type, _payload)
       when event_type in ["approval_auto_approved", "turn_input_required"] do
    Map.put(summary, :approval_pending, event_type == "turn_input_required")
  end

  defp merge_context(summary, "codex", event_type, _payload)
       when event_type in ["tool_call_failed", "unsupported_tool_call"] do
    summary
    |> Map.put(:tool_failure, true)
    |> Map.put(:last_error, event_type)
  end

  defp merge_context(summary, "codex", event_type, _payload)
       when event_type in ["tool_call_completed", "turn_completed", "session_started"] do
    summary
    |> Map.put(:approval_pending, false)
    |> Map.put(:tool_failure, false)
  end

  defp merge_context(summary, "codex", "notification", payload) do
    case notification_phase(payload) do
      phase when phase in ["codex_reasoning", "codex_editing_files", "codex_running_shell", "starting_codex_turn"] ->
        summary
        |> Map.put(:approval_pending, false)
        |> Map.put(:tool_failure, false)

      _other ->
        summary
    end
  end

  defp merge_context(summary, _source, _event_type, _payload), do: summary

  defp phase_for_event("agent_runner", "workspace_prepared", _payload), do: "preparing_workspace"
  defp phase_for_event("agent_runner", "worker_attempt_started", _payload), do: "starting_codex_turn"
  defp phase_for_event("agent_runner", "worker_runtime_info", _payload), do: "starting_codex_turn"
  defp phase_for_event("agent_runner", "run_result", payload), do: run_result_phase(payload)
  defp phase_for_event("orchestrator", "retry_scheduled", payload), do: retry_phase(payload)
  defp phase_for_event("codex", "session_started", _payload), do: "starting_codex_thread"
  defp phase_for_event("codex", "turn_completed", _payload), do: "turn_completed"
  defp phase_for_event("codex", "tool_call_completed", payload), do: tool_phase(payload, "codex_waiting_tool")
  defp phase_for_event("codex", "tool_call_failed", payload), do: tool_phase(payload, "codex_waiting_tool")
  defp phase_for_event("codex", "unsupported_tool_call", payload), do: tool_phase(payload, "codex_waiting_tool")
  defp phase_for_event("codex", "turn_input_required", _payload), do: "codex_waiting_user_input_policy"
  defp phase_for_event("codex", "approval_auto_approved", _payload), do: "codex_waiting_approval_resolution"
  defp phase_for_event("codex", "notification", payload), do: notification_phase(payload)
  defp phase_for_event("codex", event_type, payload) when is_binary(event_type), do: notification_phase(payload)
  defp phase_for_event(_source, _event_type, _payload), do: @fallback_phase

  defp run_result_phase(payload) do
    case nested_string(payload, ["status"]) do
      "completed" ->
        if nested_string(payload, ["reason"]) == "issue_entered_checking", do: "checking_tracker_state", else: "turn_completed"

      "failed" ->
        "failed"

      _ ->
        @fallback_phase
    end
  end

  defp retry_phase(payload) do
    if nested_string(payload, ["delay_type"]) == "checking_recheck", do: "checking_tracker_state", else: "retry_scheduled"
  end

  defp notification_phase(payload) do
    case nested_string(payload, ["method"]) do
      "item/reasoning/summaryTextDelta" -> "codex_reasoning"
      "item/reasoning/textDelta" -> "codex_reasoning"
      "item/reasoning/summaryPartAdded" -> "codex_reasoning"
      "item/fileChange/outputDelta" -> "codex_editing_files"
      "item/completed" -> item_completed_phase(payload)
      "item/commandExecution/outputDelta" -> "codex_running_shell"
      "item/commandExecution/requestApproval" -> "codex_waiting_approval_resolution"
      "item/fileChange/requestApproval" -> "codex_waiting_approval_resolution"
      "item/tool/call" -> tool_phase(payload, "codex_waiting_tool")
      "item/tool/requestUserInput" -> "codex_waiting_user_input_policy"
      "turn/completed" -> "turn_completed"
      "turn/started" -> "starting_codex_turn"
      nil -> @fallback_phase
      _other -> @fallback_phase
    end
  end

  defp item_completed_phase(payload) do
    item_type =
      nested_string(payload, ["params", "item", "type"]) ||
        nested_string(payload, ["params", "type"])

    cond do
      item_type in ["file_change", "apply_patch"] -> "codex_editing_files"
      item_type in ["command_execution", "exec_command"] -> "codex_running_shell"
      item_type in ["reasoning"] -> "codex_reasoning"
      true -> "codex_waiting_next_event"
    end
  end

  defp tool_phase(payload, default) do
    case nested_string(payload, ["params", "tool"]) || nested_string(payload, ["params", "name"]) do
      "shell" -> "codex_running_shell"
      _ -> default
    end
  end

  defp current_action_for_event(_source, _event_type, _payload, @fallback_phase), do: @fallback_action

  defp current_action_for_event("orchestrator", "retry_scheduled", payload, _phase) do
    case nested_string(payload, ["delay_type"]) do
      "checking_recheck" -> "checking retry scheduled"
      _ -> "retry scheduled"
    end
  end

  defp current_action_for_event(source, event_type, payload, _phase) do
    wrapped_message =
      case build_message_payload(source, event_type, payload) do
        nil -> nil
        message -> %{event: event_atom(event_type), message: message}
      end

    case wrapped_message do
      %{message: _message} = wrapped ->
        StatusDashboard.humanize_codex_message(wrapped)

      _ ->
        fallback_action_for_event(source, event_type)
    end
  rescue
    _error ->
      fallback_action_for_event(source, event_type)
  end

  defp fallback_action_for_event("agent_runner", "workspace_prepared"), do: "agent_runner:workspace_prepared"
  defp fallback_action_for_event(_source, _event_type), do: @fallback_action

  defp build_message_payload("codex", _event_type, payload) when is_map(payload), do: payload
  defp build_message_payload("agent_runner", "run_result", payload) when is_map(payload), do: payload
  defp build_message_payload("orchestrator", "retry_scheduled", payload) when is_map(payload), do: payload
  defp build_message_payload(_source, _event_type, _payload), do: nil

  defp turn_count_for_event(count, "session_started", session_id) when is_integer(count) and is_binary(session_id), do: count + 1
  defp turn_count_for_event(count, _event_type, _session_id) when is_integer(count), do: count
  defp turn_count_for_event(_count, _event_type, _session_id), do: 0

  defp unknown_summary(summary) do
    summary
    |> Map.put(:current_phase, @fallback_phase)
    |> Map.put(:current_action, @fallback_action)
    |> Map.put(:health, @fallback_health)
    |> Map.put(:fallback_reason, "unknown_event")
  end

  defp checking_cooldown?(summary, now, checking_interval_ms) do
    summary.linear_state == "Checking" and
      summary.current_phase == "checking_tracker_state" and
      is_integer(checking_interval_ms) and
      checking_interval_ms > 0 and
      elapsed_ms(summary.last_event_at, now) < checking_interval_ms
  end

  defp compute_elapsed_health(elapsed_ms, stall_timeout_ms) when is_integer(elapsed_ms) and is_integer(stall_timeout_ms) do
    slow_after_ms = min(60_000, div(stall_timeout_ms, 4))
    quiet_after_ms = min(180_000, div(stall_timeout_ms * 60, 100))
    possibly_stalled_after_ms = max(quiet_after_ms + 1, div(stall_timeout_ms * 90, 100))
    stalled_after_ms = stall_timeout_ms

    cond do
      elapsed_ms >= stalled_after_ms -> "stalled"
      elapsed_ms >= possibly_stalled_after_ms -> "possibly_stalled"
      elapsed_ms >= quiet_after_ms -> "quiet"
      elapsed_ms >= slow_after_ms -> "slow"
      true -> "normal"
    end
  end

  defp elapsed_ms(nil, _now), do: 0
  defp elapsed_ms(%DateTime{} = at, %DateTime{} = now), do: max(DateTime.diff(now, at, :millisecond), 0)
  defp elapsed_ms(_at, _now), do: 0

  defp event_payload(event) do
    case event["payload_ref"] do
      ref when is_binary(ref) ->
        event
        |> Map.get("__payload__", %{})
        |> payload_root()

      _ ->
        payload_root(Map.get(event, "payload"))
    end
  end

  defp payload_root(%{"payload" => payload}), do: payload
  defp payload_root(%{payload: payload}), do: payload
  defp payload_root(payload) when is_map(payload), do: payload
  defp payload_root(_payload), do: %{}

  defp nested_string(data, path) do
    data
    |> nested_value(path)
    |> string_present()
  end

  defp nested_value(data, path) when is_map(data) and is_list(path) do
    Enum.reduce_while(path, data, fn key, acc ->
      case fetch_key(acc, key) do
        {:ok, value} -> {:cont, value}
        :error -> {:halt, nil}
      end
    end)
  end

  defp nested_value(_data, _path), do: nil

  defp fetch_key(data, key) when is_map(data) do
    cond do
      Map.has_key?(data, key) -> {:ok, Map.get(data, key)}
      is_binary(key) and Map.has_key?(data, String.to_atom(key)) -> {:ok, Map.get(data, String.to_atom(key))}
      is_atom(key) and Map.has_key?(data, Atom.to_string(key)) -> {:ok, Map.get(data, Atom.to_string(key))}
      true -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp fetch_key(_data, _key), do: :error

  defp string_present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_present(value) when is_atom(value), do: value |> Atom.to_string() |> string_present()
  defp string_present(_value), do: nil

  defp datetime_value(%DateTime{} = value), do: value

  defp datetime_value(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp datetime_value(_value), do: nil

  defp integer_or_zero(value) when is_integer(value) and value >= 0, do: value
  defp integer_or_zero(_value), do: 0

  defp boolean_value(true), do: true
  defp boolean_value(_value), do: false

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp maybe_put(summary, _key, nil), do: summary
  defp maybe_put(summary, key, value), do: Map.put(summary, key, value)

  defp string_or_default(nil, default), do: default
  defp string_or_default(value, _default), do: value

  defp event_atom(event_type) do
    case event_type do
      "turn_completed" -> :turn_completed
      "tool_call_completed" -> :tool_call_completed
      "tool_call_failed" -> :tool_call_failed
      "unsupported_tool_call" -> :unsupported_tool_call
      "approval_auto_approved" -> :approval_auto_approved
      "turn_input_required" -> :turn_input_required
      "session_started" -> :session_started
      _ -> :notification
    end
  end
end
