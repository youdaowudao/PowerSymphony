defmodule SymphonyElixir.RunTimeline do
  @moduledoc """
  Read-only compressed timeline projection for a run trace.
  """

  alias SymphonyElixir.RawEventStore

  @default_limit 50

  @type item :: %{
          timestamp: String.t() | nil,
          source: String.t() | nil,
          event_group: String.t() | nil,
          summary: String.t() | nil,
          event_type: String.t() | nil,
          event_id: String.t() | nil,
          status_markers: [String.t()]
        }

  @type page :: %{
          items: [item()],
          next_cursor: String.t() | nil
        }

  @spec page(map(), keyword()) :: {:ok, page()} | {:error, term()}
  def page(trace, opts \\ []) when is_map(trace) and is_list(opts) do
    limit = normalize_limit(Keyword.get(opts, :limit, @default_limit))
    cursor = Keyword.get(opts, :cursor)

    with {:ok, cursor_index} <- decode_cursor(cursor) do
      events = RawEventStore.list_events(trace)
      total = length(events)

      upper =
        case cursor_index do
          nil -> total
          value when value <= total -> value
          _value -> :invalid_cursor
        end

      case upper do
        :invalid_cursor ->
          {:error, :invalid_cursor}

        upper ->
          lower = max(upper - limit, 0)
          page_events = Enum.slice(events, lower, upper - lower)

          {:ok,
           %{
             items: Enum.map(page_events, &project_event/1),
             next_cursor: if(lower > 0, do: encode_cursor(lower), else: nil)
           }}
      end
    end
  end

  defp project_event(%{} = event) do
    %{
      timestamp: Map.get(event, "timestamp"),
      source: Map.get(event, "source"),
      event_group: Map.get(event, "event_group"),
      summary: Map.get(event, "summary") || fallback_summary(event),
      event_type: Map.get(event, "event_type"),
      event_id: Map.get(event, "event_id"),
      status_markers: status_markers(event)
    }
  end

  defp fallback_summary(event) do
    [Map.get(event, "source"), Map.get(event, "event_type")]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(":")
  end

  defp status_markers(event) do
    event_type = Map.get(event, "event_type")

    []
    |> maybe_add_marker(event_type in ["turn_completed", "run_result"], "completed")
    |> maybe_add_marker(event_type in ["tool_call_failed", "unsupported_tool_call", "turn_input_required"], "attention")
    |> maybe_add_marker(event_type == "session_started", "session_started")
  end

  defp maybe_add_marker(markers, true, marker), do: [marker | markers]
  defp maybe_add_marker(markers, false, _marker), do: markers

  defp normalize_limit(value) when is_integer(value) and value > 0, do: min(value, @default_limit)
  defp normalize_limit(_value), do: @default_limit

  defp encode_cursor(index) when is_integer(index) and index > 0, do: "cursor:" <> Integer.to_string(index)
  defp encode_cursor(_index), do: nil

  defp decode_cursor(nil), do: {:ok, nil}
  defp decode_cursor(""), do: {:ok, nil}

  defp decode_cursor(cursor) when is_binary(cursor) do
    case String.split(cursor, ":", parts: 2) do
      ["cursor", index] ->
        case Integer.parse(index) do
          {parsed, ""} when parsed >= 0 -> {:ok, parsed}
          _ -> {:error, :invalid_cursor}
        end

      _ ->
        {:error, :invalid_cursor}
    end
  end

  defp decode_cursor(_), do: {:error, :invalid_cursor}
end
