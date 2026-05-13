defmodule SymphonyElixir.EventNormalizer do
  @moduledoc """
  Normalizes per-source runtime events into a stable shape for raw trace storage.
  """

  alias SymphonyElixir.RunTrace

  @spec normalize!(RunTrace.t(), atom(), map()) :: map()
  def normalize!(%RunTrace{} = trace, source, attrs) when is_atom(source) and is_map(attrs) do
    event_id = "evt-" <> Integer.to_string(System.unique_integer([:positive]))
    timestamp = Map.get(attrs, :timestamp, DateTime.utc_now()) |> normalize_timestamp()
    payload = Map.get(attrs, :payload)
    raw = Map.get(attrs, :raw)
    details = Map.get(attrs, :details)
    session_id = normalize_session_id(attrs, payload, details)
    thread_id = normalize_thread_id(attrs, payload, details)
    turn_id = normalize_turn_id(attrs, payload, details)

    %{
      "event_id" => event_id,
      "run_id" => trace.run_id,
      "project_id" => trace.project_id,
      "project_slug" => trace.project_slug,
      "issue_id" => trace.issue_id,
      "issue_identifier" => trace.issue_identifier,
      "session_id" => session_id,
      "thread_id" => thread_id,
      "turn_id" => turn_id,
      "source" => Atom.to_string(source),
      "event_type" => normalize_event_type(source, attrs),
      "event_group" => normalize_event_group(source),
      "timestamp" => DateTime.to_iso8601(timestamp),
      "summary" => normalize_summary(source, attrs),
      "payload" => payload,
      "raw_payload" => raw,
      "payload_ref" => nil,
      "payload_size_bytes" => nil,
      "redacted" => false
    }
  end

  defp normalize_timestamp(%DateTime{} = timestamp), do: DateTime.truncate(timestamp, :millisecond)
  defp normalize_timestamp(_value), do: DateTime.utc_now() |> DateTime.truncate(:millisecond)

  defp normalize_event_type(:codex, %{event: event} = attrs)
       when event in [:notification, :other_message] do
    case codex_method(attrs) do
      method when is_binary(method) -> codex_method_event_type(method)
      _ -> normalize_event_type_default(attrs)
    end
  end

  defp normalize_event_type(:codex, attrs), do: normalize_event_type_default(attrs)
  defp normalize_event_type(_source, attrs), do: normalize_event_type_default(attrs)

  defp normalize_event_type_default(%{event: event}) when is_atom(event), do: Atom.to_string(event)
  defp normalize_event_type_default(%{event_type: event_type}) when is_binary(event_type), do: event_type
  defp normalize_event_type_default(_attrs), do: "event"

  defp normalize_event_group(:codex), do: "codex_activity"
  defp normalize_event_group(:workspace_hook), do: "hook"
  defp normalize_event_group(:linear_tool), do: "tracker"
  defp normalize_event_group(:orchestrator), do: "control"
  defp normalize_event_group(:agent_runner), do: "lifecycle"
  defp normalize_event_group(_source), do: "event"

  defp normalize_summary(source, attrs) do
    case Map.get(attrs, :summary) do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        [Atom.to_string(source), normalize_event_type(source, attrs)]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join(":")
    end
  end

  defp normalize_session_id(attrs, payload, details) do
    Map.get(attrs, :session_id) || build_session_id(normalize_thread_id(attrs, payload, details), normalize_turn_id(attrs, payload, details))
  end

  defp normalize_thread_id(attrs, payload, details) do
    Map.get(attrs, :thread_id) ||
      nested_value(payload, [
        ["params", "thread", "id"],
        [:params, :thread, :id],
        ["params", "threadId"],
        [:params, :threadId]
      ]) ||
      nested_value(details, [
        ["params", "thread", "id"],
        [:params, :thread, :id],
        ["params", "threadId"],
        [:params, :threadId],
        ["thread", "id"],
        [:thread, :id]
      ])
  end

  defp normalize_turn_id(attrs, payload, details) do
    Map.get(attrs, :turn_id) ||
      nested_value(payload, [
        ["params", "turn", "id"],
        [:params, :turn, :id],
        ["params", "turnId"],
        [:params, :turnId]
      ]) ||
      nested_value(details, [
        ["params", "turn", "id"],
        [:params, :turn, :id],
        ["params", "turnId"],
        [:params, :turnId],
        ["turn", "id"],
        [:turn, :id]
      ])
  end

  defp build_session_id(thread_id, turn_id) when is_binary(thread_id) and is_binary(turn_id),
    do: "#{thread_id}-#{turn_id}"

  defp build_session_id(_thread_id, _turn_id), do: nil

  defp codex_method(attrs) do
    payload = Map.get(attrs, :payload)
    details = Map.get(attrs, :details)

    nested_value(details, [["method"], [:method]]) ||
      nested_value(payload, [["method"], [:method]])
  end

  defp codex_method_event_type(method) do
    method
    |> String.replace("/", "_")
    |> String.replace(~r/[^a-zA-Z0-9_]/u, "_")
  end

  defp nested_value(data, paths) when is_list(paths) do
    Enum.find_value(paths, &get_in_path(data, &1))
  end

  defp nested_value(_data, _paths), do: nil

  defp get_in_path(data, path) when is_map(data) and is_list(path) do
    Enum.reduce_while(path, data, fn key, acc ->
      case fetch_path_value(acc, key) do
        {:ok, value} -> {:cont, value}
        :error -> {:halt, nil}
      end
    end)
  end

  defp get_in_path(_data, _path), do: nil

  defp fetch_path_value(data, key) when is_map(data) do
    cond do
      Map.has_key?(data, key) -> {:ok, Map.get(data, key)}
      is_atom(key) and Map.has_key?(data, Atom.to_string(key)) -> {:ok, Map.get(data, Atom.to_string(key))}
      true -> :error
    end
  end

  defp fetch_path_value(_data, _key), do: :error
end
