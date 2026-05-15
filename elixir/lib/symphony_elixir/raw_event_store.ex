defmodule SymphonyElixir.RawEventStore do
  @moduledoc """
  Append-only raw trace writer and reader for normalized run events.
  """

  alias SymphonyElixir.RunTimeline

  @spec append(map(), map()) :: :ok
  def append(%{} = trace, %{} = event) do
    event = maybe_write_payload(trace, event)
    persisted = Map.drop(event, ["payload", "raw_payload"])
    File.write!(trace.trace_file, Jason.encode!(persisted) <> "\n", [:append])
    :ok
  end

  @spec list_events(map()) :: [map()]
  def list_events(%{trace_file: trace_file}) do
    if File.exists?(trace_file) do
      trace_file
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
    else
      []
    end
  end

  @spec stream_events(map()) :: Enumerable.t()
  def stream_events(%{} = trace) do
    list_events(trace)
  end

  @spec recent_timeline(map(), keyword()) :: {:ok, RunTimeline.page()} | {:error, term()}
  def recent_timeline(%{} = trace, opts \\ []) when is_list(opts) do
    RunTimeline.page(trace, opts)
  end

  defp maybe_write_payload(%{} = trace, event) do
    payload = payload_body(event)

    if is_nil(payload) do
      event
    else
      payload_file = Path.join(trace.payload_dir, Map.fetch!(event, "event_id") <> ".json")
      payload_binary = Jason.encode!(payload)

      case File.write(payload_file, payload_binary) do
        :ok ->
          event
          |> Map.put("payload_ref", Path.relative_to(payload_file, trace.run_dir))
          |> Map.put("payload_size_bytes", byte_size(payload_binary))

        {:error, _reason} ->
          event
          |> Map.put("payload_ref", nil)
          |> Map.put("payload_size_bytes", nil)
      end
    end
  end

  defp payload_body(event) do
    payload = Map.get(event, "payload")
    raw_payload = Map.get(event, "raw_payload")

    cond do
      not is_nil(payload) and not is_nil(raw_payload) ->
        %{"payload" => payload, "raw_payload" => raw_payload}

      not is_nil(payload) ->
        payload

      not is_nil(raw_payload) ->
        raw_payload

      true ->
        nil
    end
  end
end
