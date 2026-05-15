defmodule SymphonyElixir.RunTrace do
  @moduledoc """
  Per-run trace context and read handle for worker observability.
  """

  require Logger

  alias SymphonyElixir.{EventNormalizer, LogFile, RawEventStore}

  @context_key {__MODULE__, :current}

  @enforce_keys [
    :run_id,
    :issue_id,
    :issue_identifier,
    :logs_root,
    :run_dir,
    :trace_file,
    :payload_dir,
    :started_at
  ]
  defstruct [
    :run_id,
    :project_id,
    :project_slug,
    :issue_id,
    :issue_identifier,
    :worker_host,
    :workspace_path,
    :logs_root,
    :run_dir,
    :trace_file,
    :payload_dir,
    :started_at
  ]

  @type t :: %__MODULE__{
          run_id: String.t(),
          project_id: String.t() | nil,
          project_slug: String.t() | nil,
          issue_id: String.t() | nil,
          issue_identifier: String.t() | nil,
          worker_host: String.t() | nil,
          workspace_path: String.t() | nil,
          logs_root: String.t(),
          run_dir: String.t(),
          trace_file: String.t(),
          payload_dir: String.t(),
          started_at: DateTime.t()
        }

  @spec start(map(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(issue, opts \\ []) when is_map(issue) do
    logs_root = Keyword.get(opts, :logs_root, default_logs_root())
    run_id = build_run_id()
    run_dir = Path.join([logs_root, "runs", run_id])
    payload_dir = Path.join(run_dir, "payloads")
    trace_file = Path.join(run_dir, "trace.jsonl")
    started_at = DateTime.utc_now() |> DateTime.truncate(:millisecond)

    with :ok <- File.mkdir_p(payload_dir) do
      trace = %__MODULE__{
        run_id: run_id,
        project_id: Map.get(issue, :project_id),
        project_slug: Map.get(issue, :project_slug),
        issue_id: Map.get(issue, :id),
        issue_identifier: Map.get(issue, :identifier),
        worker_host: Keyword.get(opts, :worker_host),
        workspace_path: Keyword.get(opts, :workspace_path),
        logs_root: logs_root,
        run_dir: run_dir,
        trace_file: trace_file,
        payload_dir: payload_dir,
        started_at: started_at
      }

      with :ok <- write_meta(trace) do
        {:ok, trace}
      end
    end
  end

  @spec start!(map(), keyword()) :: t()
  def start!(issue, opts \\ []) when is_map(issue) do
    case start(issue, opts) do
      {:ok, trace} -> trace
      {:error, reason} -> raise File.Error, reason: reason, action: "create run trace", path: inspect(opts[:logs_root])
    end
  end

  @spec current() :: t() | nil
  def current, do: Process.get(@context_key)

  @spec with_context(t() | nil, (-> result)) :: result when result: var
  def with_context(trace, fun) when is_function(fun, 0) do
    previous = current()

    if is_struct(trace, __MODULE__) do
      Process.put(@context_key, trace)
    end

    try do
      fun.()
    after
      if previous do
        Process.put(@context_key, previous)
      else
        Process.delete(@context_key)
      end
    end
  end

  @spec update(t() | nil, map()) :: t() | nil
  def update(%__MODULE__{} = trace, attrs) when is_map(attrs) do
    updated = struct(trace, attrs)

    case write_meta(updated) do
      :ok ->
        if current() && current().run_id == trace.run_id do
          Process.put(@context_key, updated)
        end

        updated

      {:error, reason} ->
        Logger.warning("Run trace meta update failed run_id=#{trace.run_id} error=#{inspect(reason)}")
        trace
    end
  end

  def update(nil, _attrs), do: nil

  @spec record(atom(), map()) :: :ok
  def record(source, attrs) when is_atom(source) and is_map(attrs) do
    case current() do
      %__MODULE__{} = trace -> record(trace, source, attrs)
      _ -> :ok
    end
  end

  @spec record(t() | nil, atom(), map()) :: :ok
  def record(%__MODULE__{} = trace, source, attrs) when is_atom(source) and is_map(attrs) do
    normalized_event = EventNormalizer.normalize!(trace, source, attrs)
    RawEventStore.append(trace, normalized_event)
  rescue
    error ->
      Logger.warning("Run trace write failed run_id=#{trace.run_id} source=#{source} error=#{Exception.message(error)}")
      :ok
  end

  def record(nil, _source, _attrs), do: :ok

  @spec read_meta(t()) :: map()
  def read_meta(%__MODULE__{run_dir: run_dir}) do
    run_dir
    |> Path.join("meta.json")
    |> File.read!()
    |> Jason.decode!()
  end

  @spec timeline(t(), keyword()) :: {:ok, %{items: [map()], next_cursor: String.t() | nil}} | {:error, term()}
  def timeline(%__MODULE__{} = trace, opts \\ []) when is_list(opts) do
    limit = normalize_timeline_limit(Keyword.get(opts, :limit, 50))
    cursor = Keyword.get(opts, :cursor)

    with {:ok, cursor_line} <- decode_timeline_cursor(cursor),
         {:ok, page} <- read_timeline_page(trace.trace_file, cursor_line, limit) do
      {:ok, page}
    end
  end

  defp read_timeline_page(trace_file, cursor_line, limit) when is_binary(trace_file) do
    case File.exists?(trace_file) do
      false ->
        {:ok, %{items: [], next_cursor: nil}}

      true ->
        stream =
          trace_file
          |> File.stream!([], :line)
          |> maybe_take_timeline_prefix(cursor_line)

        {line_count, recent_lines} =
          Enum.reduce(stream, {0, []}, fn line, {count, window} ->
            {count + 1, push_recent_timeline_line(window, line, limit)}
          end)

        page_end = cursor_line || line_count

        if not is_nil(cursor_line) and line_count < cursor_line do
          {:error, :invalid_cursor}
        else
          {:ok,
           %{
             items: recent_lines |> Enum.reverse() |> Enum.map(&project_timeline_event/1),
             next_cursor: timeline_next_cursor(page_end, limit)
           }}
        end
    end
  end

  defp maybe_take_timeline_prefix(stream, nil), do: stream
  defp maybe_take_timeline_prefix(stream, cursor_line) when is_integer(cursor_line), do: Stream.take(stream, cursor_line)

  defp push_recent_timeline_line(window, line, limit) do
    [line | window]
    |> Enum.take(limit)
  end

  defp timeline_next_cursor(page_end, limit) when is_integer(page_end) and page_end > limit do
    encode_timeline_cursor(page_end - limit)
  end

  defp timeline_next_cursor(_page_end, _limit), do: nil

  defp encode_timeline_cursor(index) when is_integer(index) and index >= 0 do
    %{"before" => index, "v" => 1}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp project_timeline_event(line) when is_binary(line) do
    event = Jason.decode!(String.trim_trailing(line, "\n"))

    %{
      timestamp: Map.get(event, "timestamp"),
      source: Map.get(event, "source"),
      event_group: Map.get(event, "event_group"),
      summary: Map.get(event, "summary") || fallback_timeline_summary(event),
      event_type: Map.get(event, "event_type"),
      event_id: Map.get(event, "event_id"),
      status_markers: timeline_status_markers(event)
    }
  end

  defp fallback_timeline_summary(event) do
    [Map.get(event, "source"), Map.get(event, "event_type")]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(":")
  end

  defp timeline_status_markers(event) do
    event_type = Map.get(event, "event_type")

    []
    |> maybe_add_timeline_marker(event_type in ["turn_completed", "run_result"], "completed")
    |> maybe_add_timeline_marker(event_type in ["tool_call_failed", "unsupported_tool_call", "turn_input_required"], "attention")
    |> maybe_add_timeline_marker(event_type == "session_started", "session_started")
  end

  defp maybe_add_timeline_marker(markers, true, marker), do: [marker | markers]
  defp maybe_add_timeline_marker(markers, false, _marker), do: markers

  defp normalize_timeline_limit(value) when is_integer(value) and value > 0, do: min(value, 50)
  defp normalize_timeline_limit(_value), do: 50

  defp decode_timeline_cursor(nil), do: {:ok, nil}
  defp decode_timeline_cursor(""), do: {:ok, nil}

  defp decode_timeline_cursor("cursor:" <> index), do: decode_legacy_timeline_cursor(index)

  defp decode_timeline_cursor(cursor) when is_binary(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"before" => before}} <- Jason.decode(decoded),
         {:ok, parsed} <- normalize_timeline_cursor_before(before) do
      {:ok, parsed}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp decode_timeline_cursor(_), do: {:error, :invalid_cursor}

  defp decode_legacy_timeline_cursor(index) do
    case Integer.parse(index) do
      {parsed, ""} when parsed >= 0 -> {:ok, parsed}
      _ -> {:error, :invalid_cursor}
    end
  end

  defp normalize_timeline_cursor_before(before) when is_integer(before) and before >= 0, do: {:ok, before}
  defp normalize_timeline_cursor_before(before) when is_binary(before), do: decode_legacy_timeline_cursor(before)
  defp normalize_timeline_cursor_before(_before), do: {:error, :invalid_cursor}

  defp meta_payload(trace) do
    %{
      run_id: trace.run_id,
      project_id: trace.project_id,
      project_slug: trace.project_slug,
      issue_id: trace.issue_id,
      issue_identifier: trace.issue_identifier,
      worker_host: trace.worker_host,
      workspace_path: trace.workspace_path,
      started_at: DateTime.to_iso8601(trace.started_at)
    }
  end

  defp write_meta(trace) do
    trace.run_dir
    |> Path.join("meta.json")
    |> then(&File.write(&1, Jason.encode!(meta_payload(trace), pretty: true)))
  end

  defp build_run_id do
    "run-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp default_logs_root do
    Application.get_env(:symphony_elixir, :log_file, LogFile.default_log_file())
    |> Path.dirname()
    |> Path.dirname()
  end
end
