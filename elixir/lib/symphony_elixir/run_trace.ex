defmodule SymphonyElixir.RunTrace do
  @moduledoc """
  Per-run trace context and read handle for worker observability.
  """

  require Logger

  alias SymphonyElixir.{EventNormalizer, LogFile, RawEventStore, RunTimeline}

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

  @spec timeline(t(), keyword()) :: {:ok, RunTimeline.page()} | {:error, term()}
  def timeline(%__MODULE__{} = trace, opts \\ []) when is_list(opts) do
    RunTimeline.page(trace, opts)
  end

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
