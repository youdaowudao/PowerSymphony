defmodule SymphonyElixir.RunTrace do
  @moduledoc """
  Per-run trace context and read handle for worker observability.
  """

  require Logger

  alias SymphonyElixir.{EventNormalizer, LogFile, RawEventStore, StatusDashboard}
  @surface_names ~w(raw payload prompt shell)
  @preview_limit_bytes 512
  @surface_limit_bytes 4096
  @redacted_keys MapSet.new([
                   "authorization",
                   "api_key",
                   "apikey",
                   "token",
                   "access_token",
                   "refresh_token",
                   "password",
                   "secret",
                   "cookie",
                   "set-cookie"
                 ])

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
      case previous do
        nil -> Process.delete(@context_key)
        value -> Process.put(@context_key, value)
      end
    end
  end

  @spec update(t() | nil, map()) :: t() | nil
  def update(%__MODULE__{} = trace, attrs) when is_map(attrs) do
    updated = struct(trace, attrs)
    run_id = trace.run_id

    case write_meta(updated) do
      :ok ->
        case current() do
          %__MODULE__{run_id: ^run_id} -> Process.put(@context_key, updated)
          _ -> :ok
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

    with {:ok, cursor_line} <- decode_timeline_cursor(cursor) do
      read_timeline_page(trace.trace_file, cursor_line, limit)
    end
  end

  defp read_timeline_page(trace_file, cursor_line, limit) when is_binary(trace_file) do
    case File.exists?(trace_file) do
      false ->
        {:ok, %{items: [], next_cursor: nil}}

      true ->
        stream =
          trace_file
          |> File.stream!(:line, [])
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

  @spec event_detail(t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, :event_not_found | :event_detail_unavailable}
  def event_detail(%__MODULE__{} = trace, event_id, opts \\ [])
      when is_binary(event_id) and is_list(opts) do
    case read_event_bundle(trace, event_id, opts) do
      {:ok, event, payload_bundle} ->
        {:ok,
         %{
           event: %{
             event_id: Map.get(event, "event_id"),
             timestamp: Map.get(event, "timestamp"),
             source: Map.get(event, "source"),
             event_type: Map.get(event, "event_type"),
             event_group: Map.get(event, "event_group"),
             summary: Map.get(event, "summary")
           },
           run: %{
             issue_identifier: trace.issue_identifier,
             run_id: trace.run_id
           },
           context: %{
             session_id: Map.get(event, "session_id"),
             thread_id: Map.get(event, "thread_id"),
             turn_id: Map.get(event, "turn_id")
           },
           summaries: detail_summaries(payload_bundle),
           surfaces: detail_surfaces(payload_bundle)
         }}

      {:error, :event_not_found} ->
        {:error, :event_not_found}

      {:error, _reason} ->
        {:error, :event_detail_unavailable}
    end
  end

  @spec event_surface(t(), String.t(), String.t(), keyword()) ::
          {:ok, map()}
          | {:error, :invalid_surface | :event_not_found | :surface_not_available | :event_surface_unavailable}
  def event_surface(%__MODULE__{} = trace, event_id, surface, opts \\ [])
      when is_binary(event_id) and is_binary(surface) and is_list(opts) do
    with :ok <- validate_surface(surface),
         {:ok, _event, payload_bundle} <- read_event_bundle(trace, event_id, opts),
         {:ok, extracted} <- extract_surface(payload_bundle, surface),
         rendered <- render_surface(extracted, @surface_limit_bytes) do
      {:ok,
       %{
         surface: surface,
         available: true,
         content: rendered.content,
         byte_size: rendered.byte_size,
         truncated: rendered.truncated
       }}
    else
      {:error, :invalid_surface} -> {:error, :invalid_surface}
      {:error, :event_not_found} -> {:error, :event_not_found}
      {:error, :surface_not_available} -> {:error, :surface_not_available}
      {:error, _reason} -> {:error, :event_surface_unavailable}
    end
  end

  @spec context_summary(t(), keyword()) :: {:ok, map()} | {:error, :context_unavailable}
  def context_summary(%__MODULE__{} = trace, opts \\ []) when is_list(opts) do
    run_instance_id = Keyword.get(opts, :run_instance_id)
    session_id = Keyword.get(opts, :session_id)
    thread_id = Keyword.get(opts, :thread_id)
    turn_id = Keyword.get(opts, :turn_id)
    turn_count = Keyword.get(opts, :turn_count)

    events =
      trace.trace_file
      |> read_context_events()
      |> filter_context_generation(run_instance_id)

    {:ok,
     build_context_summary(events, %{
       session_id: session_id,
       thread_id: thread_id,
       turn_id: turn_id,
       turn_count: turn_count
     })}
  rescue
    _error ->
      {:error, :context_unavailable}
  end

  defp maybe_take_timeline_prefix(stream, nil), do: stream
  defp maybe_take_timeline_prefix(stream, cursor_line) when is_integer(cursor_line), do: Stream.take(stream, cursor_line)

  defp read_context_events(trace_file) when is_binary(trace_file) do
    if File.exists?(trace_file) do
      trace_file
      |> File.stream!(:line, [])
      |> Enum.map(fn line ->
        line
        |> String.trim_trailing("\n")
        |> Jason.decode!()
        |> Map.put("__trace_run_dir__", Path.dirname(trace_file))
      end)
    else
      []
    end
  end

  defp filter_context_generation(events, run_instance_id) when is_binary(run_instance_id) do
    Enum.filter(events, &(Map.get(&1, "run_instance_id") == run_instance_id))
  end

  defp filter_context_generation(events, _run_instance_id), do: events

  defp build_context_summary(events, anchor) do
    %{
      anchor: build_context_anchor(events, anchor),
      conversation: build_conversation_summary(events),
      continuation: build_continuation_summary(events),
      tools: %{items: build_tool_items(events)},
      shell: %{items: build_shell_items(events)},
      subagents: build_subagent_summary(events)
    }
  end

  defp build_context_anchor(_events, anchor) when is_map(anchor) do
    %{
      session_id: Map.get(anchor, :session_id),
      thread_id: Map.get(anchor, :thread_id),
      turn_id: Map.get(anchor, :turn_id),
      turn_count: normalize_turn_count(Map.get(anchor, :turn_count))
    }
  end

  defp normalize_turn_count(value) when is_integer(value), do: value
  defp normalize_turn_count(_value), do: nil

  defp build_conversation_summary(events) do
    items =
      events
      |> Enum.flat_map(&conversation_item/1)
      |> Enum.take(-3)
      |> Enum.reverse()

    %{
      items: items,
      truncated: false
    }
  end

  defp conversation_item(event) do
    payload = event_payload(event)
    method = map_path(payload, ["method"])
    event_id = Map.get(event, "event_id")

    case method do
      "item/reasoning/summaryTextDelta" ->
        with text when is_binary(text) <- map_path(payload, ["params", "summaryText"]),
             trimmed when trimmed != "" <- String.trim(text) do
          [
            %{
              event_id: event_id,
              kind: "reasoning_summary",
              label: "reasoning",
              text: render_surface(trimmed, 160).content
            }
          ]
        else
          _ -> []
        end

      "item/reasoning/textDelta" ->
        with text when is_binary(text) <- map_path(payload, ["params", "textDelta"]),
             trimmed when trimmed != "" <- String.trim(text) do
          [
            %{
              event_id: event_id,
              kind: "reasoning_text",
              label: "reasoning",
              text: render_surface(trimmed, 160).content
            }
          ]
        else
          _ -> []
        end

      method when method in ["item/tool/requestUserInput", "tool/requestUserInput"] ->
        case stable_user_input_text(payload) do
          text when is_binary(text) ->
            [
              %{
                event_id: event_id,
                kind: "user_input_request",
                label: "tool input request",
                text: render_surface(text, 160).content
              }
            ]

          _ ->
            []
        end

      _ ->
        []
    end
  end

  defp stable_user_input_text(payload) do
    map_path(payload, ["params", "question"]) ||
      map_path(payload, ["params", "prompt"]) ||
      first_question_text(map_path(payload, ["params", "questions"]))
  end

  defp first_question_text(questions) when is_list(questions) do
    Enum.find_value(questions, fn question ->
      case map_path(question, ["question"]) do
        text when is_binary(text) and text != "" -> text
        _ -> nil
      end
    end)
  end

  defp first_question_text(_questions), do: nil

  defp build_continuation_summary(events) do
    continuation_required =
      Enum.find(events, fn event ->
        Map.get(event, "event_type") == "run_result" and
          map_path(event_payload(event), ["status"]) == "continuation_required"
      end)

    checking_recheck =
      Enum.find(events, fn event ->
        Map.get(event, "event_type") == "retry_scheduled" and
          map_path(event_payload(event), ["delay_type"]) == "checking_recheck"
      end)

    retry_scheduled =
      Enum.find(events, &(Map.get(&1, "event_type") == "retry_scheduled"))

    cond do
      is_map(continuation_required) ->
        %{
          status: "continuation_required",
          label: "continuation required",
          event_id: Map.get(continuation_required, "event_id")
        }

      is_map(checking_recheck) ->
        %{
          status: "checking_recheck",
          label: "checking recheck",
          event_id: Map.get(checking_recheck, "event_id")
        }

      is_map(retry_scheduled) ->
        %{
          status: "retry_scheduled",
          label: "retry scheduled",
          event_id: Map.get(retry_scheduled, "event_id")
        }

      true ->
        %{
          status: "none_observed",
          label: "none observed",
          event_id: nil
        }
    end
  end

  defp build_tool_items(events) do
    events
    |> Enum.flat_map(&tool_item/1)
    |> Enum.take(-3)
    |> Enum.reverse()
  end

  defp tool_item(event) do
    event_type = Map.get(event, "event_type")
    payload = event_payload(event)
    method = map_path(payload, ["method"])
    tool = dynamic_tool_name(payload)

    cond do
      event_type in ["tool_call_completed", "tool_call_failed", "unsupported_tool_call"] ->
        [
          %{
            event_id: Map.get(event, "event_id"),
            tool: tool,
            status: tool_event_status(event_type),
            summary: tool_event_summary(event_type, tool)
          }
        ]

      method == "item/tool/call" ->
        [
          %{
            event_id: Map.get(event, "event_id"),
            tool: tool,
            status: "completed",
            summary: StatusDashboard.humanize_codex_message(%{payload: payload})
          }
        ]

      true ->
        []
    end
  end

  defp tool_event_status("tool_call_completed"), do: "completed"
  defp tool_event_status("tool_call_failed"), do: "failed"
  defp tool_event_status("unsupported_tool_call"), do: "failed"
  defp tool_event_status(_event_type), do: "completed"

  defp tool_event_summary("tool_call_completed", tool), do: dynamic_tool_summary("dynamic tool call completed", tool)
  defp tool_event_summary("tool_call_failed", tool), do: dynamic_tool_summary("dynamic tool call failed", tool)

  defp tool_event_summary("unsupported_tool_call", tool),
    do: dynamic_tool_summary("unsupported dynamic tool call rejected", tool)

  defp tool_event_summary(_event_type, tool), do: dynamic_tool_summary("dynamic tool call", tool)

  defp dynamic_tool_summary(base, tool) when is_binary(tool) do
    trimmed = String.trim(tool)
    if trimmed == "", do: base, else: "#{base} (#{trimmed})"
  end

  defp dynamic_tool_summary(base, _tool), do: base

  defp build_shell_items(events) do
    events
    |> Enum.flat_map(&shell_item/1)
    |> Enum.take(-3)
    |> Enum.reverse()
  end

  defp shell_item(event) do
    payload = event_payload(event)
    method = map_path(payload, ["method"])
    event_id = Map.get(event, "event_id")

    case method do
      "item/commandExecution/outputDelta" ->
        with text when is_binary(text) <- map_path(payload, ["params", "outputDelta"]),
             trimmed when trimmed != "" <- String.trim(text) do
          [%{event_id: event_id, kind: "command_output", text: render_surface(trimmed, 160).content}]
        else
          _ -> []
        end

      "codex/event/exec_command_begin" ->
        [
          %{
            event_id: event_id,
            kind: "exec_command",
            text: StatusDashboard.humanize_codex_message(%{payload: payload})
          }
        ]

      "codex/event/exec_command_end" ->
        [
          %{
            event_id: event_id,
            kind: "exec_command",
            text: StatusDashboard.humanize_codex_message(%{payload: payload})
          }
        ]

      _ ->
        case map_path(payload, ["params", "tool"]) do
          "shell" ->
            [
              %{
                event_id: event_id,
                kind: "command",
                text: StatusDashboard.humanize_codex_message(%{payload: payload})
              }
            ]

          _ ->
            []
        end
    end
  end

  defp build_subagent_summary([]), do: %{items: [], status: "unavailable"}

  defp build_subagent_summary(_events), do: %{items: [], status: "none_observed"}

  defp event_payload(event) do
    case Map.get(event, "payload_ref") do
      ref when is_binary(ref) ->
        event
        |> Map.get("__trace_run_dir__")
        |> Path.join(ref)
        |> File.read!()
        |> Jason.decode!()
        |> payload_from_bundle()

      _ ->
        payload_from_bundle(event)
    end
  rescue
    _error ->
      %{}
  end

  defp payload_from_bundle(%{"payload" => payload}), do: payload
  defp payload_from_bundle(%{payload: payload}), do: payload
  defp payload_from_bundle(%{} = payload), do: payload
  defp payload_from_bundle(_payload), do: %{}

  defp dynamic_tool_name(payload) do
    map_path(payload, ["params", "tool"]) ||
      map_path(payload, ["params", "name"])
  end

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
      run_instance_id: Map.get(event, "run_instance_id"),
      status_markers: timeline_status_markers(event)
    }
  end

  defp fallback_timeline_summary(event) do
    [Map.get(event, "source"), Map.get(event, "event_type")]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(":")
  end

  defp timeline_status_markers(event) do
    source = Map.get(event, "source")
    event_type = Map.get(event, "event_type")

    []
    |> maybe_add_timeline_marker(source == "codex" and event_type == "turn_completed", "pending_finalization")
    |> maybe_add_timeline_marker(event_type == "run_result", "completed")
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

  defp validate_surface(surface) when surface in @surface_names, do: :ok
  defp validate_surface(_surface), do: {:error, :invalid_surface}

  defp read_event_bundle(%__MODULE__{} = trace, event_id, opts) do
    run_instance_id = Keyword.get(opts, :run_instance_id)

    with {:ok, event} <- read_trace_event(trace.trace_file, event_id, run_instance_id),
         {:ok, payload_bundle} <- hydrate_payload_bundle(trace, event) do
      {:ok, event, payload_bundle}
    end
  end

  defp read_trace_event(trace_file, event_id, run_instance_id)
       when is_binary(trace_file) and is_binary(event_id) do
    case File.exists?(trace_file) do
      true ->
        trace_file
        |> File.stream!(:line, [])
        |> Enum.reduce_while(
          {:error, :event_not_found},
          &reduce_trace_event_match(&1, &2, event_id, run_instance_id)
        )

      false ->
        {:error, :trace_unavailable}
    end
  rescue
    _error ->
      {:error, :trace_unavailable}
  end

  defp hydrate_payload_bundle(%__MODULE__{} = trace, event) do
    case Map.get(event, "payload_ref") do
      ref when is_binary(ref) ->
        trace.run_dir
        |> Path.join(ref)
        |> File.read!()
        |> Jason.decode!()
        |> build_payload_bundle()

      _ ->
        {:ok, %{payload: nil, raw_payload: nil}}
    end
  rescue
    _error ->
      {:error, :payload_unavailable}
  end

  defp build_payload_bundle(%{"payload" => payload, "raw_payload" => raw_payload}) do
    {:ok, %{payload: payload, raw_payload: raw_payload}}
  end

  defp build_payload_bundle(%{"payload" => payload} = bundle) do
    {:ok, %{payload: payload, raw_payload: Map.get(bundle, "raw_payload")}}
  end

  defp build_payload_bundle(%{} = payload) do
    {:ok, %{payload: payload, raw_payload: nil}}
  end

  defp build_payload_bundle(payload), do: {:ok, %{payload: nil, raw_payload: payload}}

  defp event_matches_run_instance?(_event, nil), do: true

  defp event_matches_run_instance?(event, run_instance_id) when is_binary(run_instance_id) do
    Map.get(event, "run_instance_id") == run_instance_id
  end

  defp trace_event_match?(event, event_id, run_instance_id) do
    Map.get(event, "event_id") == event_id and
      event_matches_run_instance?(event, run_instance_id)
  end

  defp reduce_trace_event_match(line, _acc, event_id, run_instance_id) do
    event = line |> String.trim_trailing("\n") |> Jason.decode!()

    if trace_event_match?(event, event_id, run_instance_id) do
      {:halt, {:ok, event}}
    else
      {:cont, {:error, :event_not_found}}
    end
  end

  defp detail_summaries(payload_bundle) do
    payload = Map.get(payload_bundle, :payload)

    %{
      tool_call: tool_call_summary(payload),
      payload: payload_summary(payload),
      prompt: prompt_summary(payload),
      shell: shell_summary(payload)
    }
  end

  defp detail_surfaces(payload_bundle) do
    Enum.into(@surface_names, %{}, fn surface ->
      key = String.to_atom(surface)

      preview =
        case extract_surface(payload_bundle, surface) do
          {:ok, extracted} ->
            rendered = render_surface(extracted, @preview_limit_bytes)

            {key,
             %{
               available: true,
               byte_size: rendered.byte_size,
               preview: rendered.content,
               truncated: rendered.truncated
             }}

          {:error, :surface_not_available} ->
            {key,
             %{
               available: false,
               byte_size: 0,
               preview: nil,
               truncated: false
             }}
        end

      preview
    end)
  end

  defp prompt_summary(payload) do
    [
      map_path(payload, ["params", "question"]),
      map_path(payload, ["params", "prompt"]),
      List.first(input_texts(payload)),
      map_path(payload, ["params", "summaryText"])
    ]
    |> Enum.find_value(fn
      value when is_binary(value) and value != "" -> render_surface(value, 160).content
      _ -> nil
    end)
  end

  defp shell_summary(payload) do
    [
      map_path(payload, ["params", "parsedCmd"]),
      map_path(payload, ["params", "command"]),
      map_path(payload, ["params", "outputDelta"]),
      if(map_path(payload, ["params", "tool"]) == "shell", do: "shell", else: nil)
    ]
    |> Enum.find_value(fn
      value when is_binary(value) and value != "" -> render_surface(value, 160).content
      _ -> nil
    end)
  end

  defp tool_call_summary(payload) do
    payload
    |> map_path(["params", "tool"])
    |> case do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp payload_summary(nil), do: nil

  defp payload_summary(%{} = payload) do
    "JSON object with #{map_size(payload)} top-level keys"
  end

  defp payload_summary(payload) when is_list(payload) do
    "JSON array with #{length(payload)} items"
  end

  defp payload_summary(payload) when is_binary(payload) do
    rendered = render_surface(payload, 160)
    rendered.content
  end

  defp payload_summary(_payload), do: nil

  defp extract_surface(payload_bundle, "payload") do
    case Map.get(payload_bundle, :payload) do
      nil -> {:error, :surface_not_available}
      payload -> {:ok, payload}
    end
  end

  defp extract_surface(payload_bundle, "raw") do
    case Map.get(payload_bundle, :raw_payload) do
      nil -> {:error, :surface_not_available}
      payload -> {:ok, payload}
    end
  end

  defp extract_surface(payload_bundle, "prompt") do
    payload_bundle
    |> Map.get(:payload)
    |> prompt_candidates()
    |> join_surface_lines()
  end

  defp extract_surface(payload_bundle, "shell") do
    payload_bundle
    |> Map.get(:payload)
    |> shell_candidates()
    |> join_surface_lines()
  end

  defp prompt_candidates(payload) do
    [
      map_path(payload, ["params", "prompt"]),
      map_path(payload, ["params", "question"]),
      input_texts(payload),
      map_path(payload, ["params", "summaryText"])
    ]
    |> List.flatten()
    |> Enum.filter(&present_binary?/1)
  end

  defp shell_candidates(payload) do
    tool = map_path(payload, ["params", "tool"])

    [
      if(tool == "shell", do: tool, else: nil),
      map_path(payload, ["params", "parsedCmd"]),
      map_path(payload, ["params", "command"]),
      map_path(payload, ["params", "outputDelta"])
    ]
    |> Enum.filter(&present_binary?/1)
  end

  defp input_texts(payload) do
    case map_path(payload, ["params", "input"]) do
      values when is_list(values) ->
        Enum.map(values, &map_path(&1, ["text"]))

      _ ->
        []
    end
  end

  defp join_surface_lines([]), do: {:error, :surface_not_available}

  defp join_surface_lines(values) when is_list(values) do
    values
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> case do
      "" -> {:error, :surface_not_available}
      text -> {:ok, text}
    end
  end

  defp render_surface(value, limit) when is_integer(limit) and limit > 0 do
    redacted = redact_value(value)
    serialized = stringify_surface(redacted)
    byte_size = byte_size(serialized)
    content = utf8_truncate(serialized, limit)

    %{
      content: content,
      byte_size: byte_size,
      truncated: byte_size > byte_size(content)
    }
  end

  defp redact_value(%{} = value) do
    value
    |> Enum.into(%{}, fn {key, nested_value} ->
      normalized_key = normalize_redaction_key(key)

      if MapSet.member?(@redacted_keys, normalized_key) do
        {key, "[REDACTED]"}
      else
        {key, redact_value(nested_value)}
      end
    end)
  end

  defp redact_value(value) when is_list(value), do: Enum.map(value, &redact_value/1)
  defp redact_value(value) when is_binary(value), do: redact_text(value)
  defp redact_value(value), do: value

  defp redact_text(value) when is_binary(value) do
    value
    |> then(&Regex.replace(~r/Bearer\s+\S+/iu, &1, "Bearer [REDACTED]"))
    |> then(&Regex.replace(~r/(authorization\s*:\s*)(\S+)/iu, &1, "\\1[REDACTED]"))
    |> then(&Regex.replace(~r/((?:api_key|token|password)\s*=\s*)(\S+)/iu, &1, "\\1[REDACTED]"))
  end

  defp stringify_surface(%{} = value), do: Jason.encode!(value)
  defp stringify_surface(value) when is_list(value), do: Jason.encode!(value)
  defp stringify_surface(value) when is_binary(value), do: value
  defp stringify_surface(value), do: to_string(value)

  defp utf8_truncate(value, limit) when byte_size(value) <= limit, do: value

  defp utf8_truncate(value, limit) do
    candidate = binary_part(value, 0, limit)

    if String.valid?(candidate) do
      candidate
    else
      utf8_truncate(value, limit - 1)
    end
  end

  defp present_binary?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_binary?(_value), do: false

  defp normalize_redaction_key(key) when is_atom(key), do: key |> Atom.to_string() |> String.downcase()
  defp normalize_redaction_key(key) when is_binary(key), do: String.downcase(key)
  defp normalize_redaction_key(key), do: key |> to_string() |> String.downcase()

  defp map_path(data, [key | rest]) when is_map(data) do
    case fetch_path_value(data, key) do
      {:ok, value} -> map_path(value, rest)
      :error -> nil
    end
  end

  defp map_path(data, []) do
    data
  end

  defp map_path(_data, _path), do: nil

  defp fetch_path_value(data, key) when is_map(data) and is_binary(key) do
    case Map.fetch(data, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        Enum.find_value(data, :error, &match_atom_key(&1, key))
    end
  end

  defp fetch_path_value(_data, _key), do: :error

  defp match_atom_key({map_key, value}, key) when is_atom(map_key) do
    if Atom.to_string(map_key) == key, do: {:ok, value}
  end

  defp match_atom_key(_entry, _key), do: nil

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
