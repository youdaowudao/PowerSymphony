defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, ProjectRegistry, StatusDashboard}

  @empty_state_payload %{
    counts: %{running: 0, retrying: 0},
    running: [],
    retrying: [],
    codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
    rate_limits: nil
  }

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying)
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec empty_state_payload() :: map()
  def empty_state_payload do
    Map.put(@empty_state_payload, :generated_at, generated_at())
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  @spec empty_refresh_payload() :: {:ok, map()}
  def empty_refresh_payload do
    {:ok,
     %{
       queued: false,
       coalesced: false,
       requested_at: generated_at(),
       operations: []
     }}
  end

  @spec m3_precheck_payload(map()) :: map()
  def m3_precheck_payload(payload) when is_map(payload) do
    %{
      generated_at: m3_generated_at(payload),
      m3_enabled: m3_payload_value(payload, :m3_enabled),
      eligible_todos: m3_issue_entries(payload, :eligible_todos),
      dispatched_todos: m3_issue_entries(payload, :dispatched_todos),
      capacity_queued_todos: m3_issue_entries(payload, :capacity_queued_todos),
      blocked_todos: m3_blocked_todos_payload(payload),
      current_work: m3_current_work_payload(payload),
      anomalies: m3_anomalies_payload(payload),
      structural_errors: m3_payload_value(payload, :structural_errors, []),
      warnings: m3_payload_value(payload, :warnings, []),
      convergence_points: m3_payload_value(payload, :convergence_points, []),
      text: m3_payload_value(payload, :text, "")
    }
  end

  @spec projects_payload(ProjectRegistry.t() | %{entries: [map()]}) :: map()
  def projects_payload(registry) do
    %{
      generated_at: generated_at(),
      projects: Enum.map(project_entries(registry), &project_entry_payload/1)
    }
  end

  @spec project_summary_payload(String.t(), ProjectRegistry.t() | %{entries: [map()]}) ::
          {:ok, map()} | {:error, :project_not_found}
  def project_summary_payload(project_id, registry) when is_binary(project_id) do
    case Enum.find(project_entries(registry), &(&1.project_id == project_id)) do
      nil ->
        {:error, :project_not_found}

      entry ->
        {:ok,
         %{
           generated_at: generated_at(),
           project: project_entry_payload(entry)
         }}
    end
  end

  @spec project_run_summary_payload(
          String.t(),
          String.t(),
          ProjectRegistry.t() | %{entries: [map()]}
        ) :: {:ok, map()} | {:error, :project_not_found | :run_not_found}
  def project_run_summary_payload(project_id, issue_identifier, registry)
      when is_binary(project_id) and is_binary(issue_identifier) do
    with {:ok, %{project: project} = payload} <- project_summary_payload(project_id, registry),
         %{} = run_summary <- find_project_run_summary(project, issue_identifier) do
      {:ok, Map.put(payload, :run, run_summary)}
    else
      {:error, :project_not_found} -> {:error, :project_not_found}
      nil -> {:error, :run_not_found}
    end
  end

  @spec run_timeline_payload(map()) :: map()
  def run_timeline_payload(%{} = payload) do
    %{
      items:
        payload
        |> map_value(:items)
        |> List.wrap()
        |> Enum.map(&timeline_item_payload/1),
      next_cursor: map_value(payload, :next_cursor)
    }
  end

  @spec run_event_detail_payload(map()) :: map()
  def run_event_detail_payload(%{} = payload) do
    %{
      event: run_event_detail_section(map_value(payload, :event)),
      run: run_event_run_section(map_value(payload, :run)),
      context: run_event_context_section(map_value(payload, :context)),
      summaries: run_event_summaries_section(map_value(payload, :summaries)),
      surfaces: run_event_surfaces_section(map_value(payload, :surfaces))
    }
  end

  @spec run_event_surface_payload(map()) :: map()
  def run_event_surface_payload(%{} = payload) do
    %{
      surface: map_value(payload, :surface),
      available: map_value(payload, :available) == true,
      content: map_value(payload, :content),
      byte_size: map_integer_value(payload, :byte_size) || 0,
      truncated: map_value(payload, :truncated) == true
    }
  end

  @spec run_context_payload(map()) :: map()
  def run_context_payload(%{} = payload) do
    anchor = map_value(payload, :anchor) || %{}
    conversation = map_value(payload, :conversation) || %{}
    continuation = map_value(payload, :continuation) || %{}
    issue_refresh = map_value(payload, :issue_refresh) || %{}
    tools = map_value(payload, :tools) || %{}
    shell = map_value(payload, :shell) || %{}
    subagents = map_value(payload, :subagents) || %{}

    %{
      anchor: %{
        session_id: map_value(anchor, :session_id),
        thread_id: map_value(anchor, :thread_id),
        turn_id: map_value(anchor, :turn_id),
        turn_count: map_integer_value(anchor, :turn_count)
      },
      conversation: %{
        items:
          conversation
          |> map_value(:items)
          |> List.wrap()
          |> Enum.map(&run_context_conversation_item/1),
        truncated: map_value(conversation, :truncated) == true
      },
      continuation: %{
        status: map_value(continuation, :status),
        label: map_value(continuation, :label),
        event_id: map_value(continuation, :event_id)
      },
      issue_refresh: %{
        status: map_value(issue_refresh, :status),
        status_text: map_value(issue_refresh, :status_text),
        observed_changes: list_value(issue_refresh, :observed_changes),
        updated_at_changed?: map_value(issue_refresh, :updated_at_changed?) == true,
        notes: list_value(issue_refresh, :notes),
        event_id: map_value(issue_refresh, :event_id)
      },
      tools: %{
        items:
          tools
          |> map_value(:items)
          |> List.wrap()
          |> Enum.map(&run_context_tool_item/1)
      },
      shell: %{
        items:
          shell
          |> map_value(:items)
          |> List.wrap()
          |> Enum.map(&run_context_shell_item/1)
      },
      subagents: %{
        items:
          subagents
          |> map_value(:items)
          |> List.wrap()
          |> Enum.map(&run_context_subagent_item/1),
        status: map_value(subagents, :status)
      }
    }
  end

  @spec find_project_run_summary(map(), String.t()) :: map() | nil
  def find_project_run_summary(project, issue_identifier)
      when is_map(project) and is_binary(issue_identifier) do
    project
    |> map_value(:run_summaries)
    |> List.wrap()
    |> Enum.find(fn summary -> map_value(summary, :issue_identifier) == issue_identifier end)
  end

  @spec project_runtime_or_validation_error(map()) :: String.t() | nil
  def project_runtime_or_validation_error(project) when is_map(project) do
    map_value(project, :last_error) || project_validation_error_summary(map_value(project, :validation_errors))
  end

  @spec project_validation_error_label(map()) :: String.t()
  def project_validation_error_label(%{"field" => field, "message" => message}), do: "#{field}: #{message}"
  def project_validation_error_label(%{field: field, message: message}), do: "#{field}: #{message}"
  def project_validation_error_label(_error), do: "invalid"

  @spec project_run_summary_title(map()) :: String.t()
  def project_run_summary_title(summary) when is_map(summary) do
    case map_value(summary, :title) do
      value when is_binary(value) and value != "" -> value
      _ -> "未提供标题"
    end
  end

  @spec project_run_summary_health_meta(map()) :: String.t()
  def project_run_summary_health_meta(summary) when is_map(summary) do
    [map_value(summary, :linear_state), map_value(summary, :health)]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join(" · ")
    |> blank_to_na()
  end

  @spec project_run_summary_ids(map()) :: String.t()
  def project_run_summary_ids(summary) when is_map(summary) do
    [
      summary_text(summary, :thread_id, "thread"),
      summary_text(summary, :turn_id, "turn"),
      summary_text(summary, :session_id, "session")
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
    |> blank_to_na()
  end

  @spec project_run_summary_runtime(map()) :: String.t()
  def project_run_summary_runtime(summary) when is_map(summary) do
    parts =
      [
        run_turn_count_text(summary),
        run_last_event_text(summary),
        run_duration_text(summary)
      ]
      |> Enum.filter(&is_binary/1)

    case parts do
      [] -> "n/a"
      _ -> Enum.join(parts, " · ")
    end
  end

  defp issue_payload_body(issue_identifier, running, retry) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      status: issue_status(running, retry),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry),
        host: workspace_host(running, retry)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        codex_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: %{}
    }
  end

  defp project_entries(%ProjectRegistry{} = registry), do: ProjectRegistry.entries(registry)
  defp project_entries(%{entries: entries}) when is_list(entries), do: entries
  defp project_entries(_registry), do: []

  defp project_entry_payload(entry) do
    runtime_state = Map.get(entry, :runtime_state)

    %{
      project_id: entry.project_id,
      project_name: entry.project_name,
      enabled: project_enabled(entry),
      validation_result: to_string(entry.validation_result),
      validation_errors: Enum.map(entry.validation_errors, &project_validation_error_payload/1),
      worker_status: runtime_state_status(runtime_state),
      worker_port: project_worker_port(entry, runtime_state),
      last_seen_at: project_runtime_timestamp(runtime_state, :last_seen_at),
      last_health_check_at: project_runtime_timestamp(runtime_state, :last_health_check_at),
      last_error: project_last_error(runtime_state),
      runtime_state: project_runtime_payload(runtime_state),
      run_summaries: project_run_summaries_payload(runtime_state)
    }
  end

  defp project_runtime_payload(runtime_state) when is_map(runtime_state) do
    %{
      status: runtime_state_status(runtime_state)
    }
  end

  defp project_runtime_payload(_runtime_state) do
    %{
      status: "not_started"
    }
  end

  defp project_run_summaries_payload(%{} = runtime_state) do
    runtime_state
    |> map_value(:run_summaries)
    |> List.wrap()
    |> Enum.map(&project_run_summary_payload/1)
  end

  defp project_run_summaries_payload(_runtime_state), do: []

  defp project_run_summary_payload(summary) when is_map(summary) do
    %{
      issue_identifier: map_value(summary, :issue_identifier),
      title: map_value(summary, :title),
      linear_state: map_value(summary, :linear_state),
      current_phase: map_value(summary, :current_phase),
      current_action: map_value(summary, :current_action),
      health: map_value(summary, :health),
      issue_url: map_value(summary, :issue_url),
      session_id: map_value(summary, :session_id),
      thread_id: map_value(summary, :thread_id),
      turn_id: map_value(summary, :turn_id),
      turn_count: map_integer_value(summary, :turn_count),
      last_event_at: iso8601(map_value(summary, :last_event_at)),
      run_duration_seconds: map_integer_value(summary, :run_duration_seconds),
      last_error: map_value(summary, :last_error),
      blocked_by: dependency_list_payload(map_value(summary, :blocked_by)),
      blocks: dependency_list_payload(map_value(summary, :blocks)),
      attention_items: attention_items_payload(map_value(summary, :attention_items))
    }
  end

  defp project_run_summary_payload(_summary), do: %{}

  defp project_enabled(%{normalized_config: %{enabled: enabled}}) when is_boolean(enabled), do: enabled
  defp project_enabled(_entry), do: true

  defp project_worker_port(entry, runtime_state) do
    runtime_state_value(runtime_state, :worker_port) ||
      normalized_config_value(entry, :worker_port)
  end

  defp project_last_error(runtime_state) do
    runtime_state_value(runtime_state, :last_error) ||
      runtime_state_value(runtime_state, :error_summary)
  end

  defp project_runtime_timestamp(runtime_state, key) do
    runtime_state
    |> runtime_state_value(key)
    |> iso8601()
  end

  defp runtime_state_status(%{} = runtime_state) do
    runtime_state
    |> runtime_state_value(:status)
    |> Kernel.||(:not_started)
    |> to_string()
  end

  defp runtime_state_status(_runtime_state), do: "not_started"

  defp runtime_state_value(%{} = runtime_state, key), do: map_value(runtime_state, key)
  defp runtime_state_value(_runtime_state, _key), do: nil

  defp normalized_config_value(entry, key) do
    entry
    |> Map.get(:normalized_config)
    |> runtime_state_value(key)
  end

  defp summary_text(summary, key, label) do
    case map_value(summary, key) do
      value when is_binary(value) and value != "" -> "#{label} #{value}"
      _ -> nil
    end
  end

  defp run_turn_count_text(summary) do
    case map_integer_value(summary, :turn_count) do
      value when is_integer(value) -> "#{value} turns"
      _ -> nil
    end
  end

  defp run_last_event_text(summary) do
    case map_value(summary, :last_event_at) do
      value when is_binary(value) and value != "" -> "last event #{value}"
      _ -> nil
    end
  end

  defp run_duration_text(summary) do
    case map_integer_value(summary, :run_duration_seconds) do
      value when is_integer(value) -> "#{value}s"
      _ -> nil
    end
  end

  defp timeline_item_payload(item) when is_map(item) do
    %{
      event_id: map_value(item, :event_id),
      timestamp: map_value(item, :timestamp),
      source: map_value(item, :source),
      event_group: map_value(item, :event_group),
      summary: map_value(item, :summary),
      event_type: map_value(item, :event_type),
      status_markers: map_value(item, :status_markers) |> List.wrap()
    }
  end

  defp timeline_item_payload(_item), do: %{}

  defp run_event_detail_section(section) when is_map(section) do
    %{
      event_id: map_value(section, :event_id),
      timestamp: map_value(section, :timestamp),
      source: map_value(section, :source),
      event_type: map_value(section, :event_type),
      event_group: map_value(section, :event_group),
      summary: map_value(section, :summary)
    }
  end

  defp run_event_detail_section(_section) do
    %{
      event_id: nil,
      timestamp: nil,
      source: nil,
      event_type: nil,
      event_group: nil,
      summary: nil
    }
  end

  defp run_event_run_section(section) when is_map(section) do
    %{
      issue_identifier: map_value(section, :issue_identifier),
      run_id: map_value(section, :run_id)
    }
  end

  defp run_event_run_section(_section), do: %{issue_identifier: nil, run_id: nil}

  defp run_event_context_section(section) when is_map(section) do
    %{
      session_id: map_value(section, :session_id),
      thread_id: map_value(section, :thread_id),
      turn_id: map_value(section, :turn_id)
    }
  end

  defp run_event_context_section(_section), do: %{session_id: nil, thread_id: nil, turn_id: nil}

  defp run_event_summaries_section(section) when is_map(section) do
    %{
      tool_call: map_value(section, :tool_call),
      payload: map_value(section, :payload),
      prompt: map_value(section, :prompt),
      shell: map_value(section, :shell)
    }
  end

  defp run_event_summaries_section(_section) do
    %{tool_call: nil, payload: nil, prompt: nil, shell: nil}
  end

  defp run_event_surfaces_section(section) when is_map(section) do
    %{
      raw: run_event_surface_preview(map_value(section, :raw)),
      payload: run_event_surface_preview(map_value(section, :payload)),
      prompt: run_event_surface_preview(map_value(section, :prompt)),
      shell: run_event_surface_preview(map_value(section, :shell))
    }
  end

  defp run_event_surfaces_section(_section) do
    %{
      raw: run_event_surface_preview(nil),
      payload: run_event_surface_preview(nil),
      prompt: run_event_surface_preview(nil),
      shell: run_event_surface_preview(nil)
    }
  end

  defp run_event_surface_preview(section) when is_map(section) do
    %{
      available: map_value(section, :available) == true,
      byte_size: map_integer_value(section, :byte_size) || 0,
      preview: map_value(section, :preview),
      truncated: map_value(section, :truncated) == true
    }
  end

  defp run_event_surface_preview(_section) do
    %{available: false, byte_size: 0, preview: nil, truncated: false}
  end

  defp map_value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp blank_to_na(""), do: "n/a"
  defp blank_to_na(value), do: value

  defp map_integer_value(map, key) do
    case map_value(map, key) do
      value when is_integer(value) and value >= 0 -> value
      _ -> nil
    end
  end

  defp list_value(map, key) when is_map(map) do
    case map_value(map, key) do
      values when is_list(values) -> Enum.filter(values, &is_binary/1)
      _ -> []
    end
  end

  defp project_validation_error_payload(%{field: field, message: message}) do
    %{field: field, message: message}
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      title: Map.get(entry, :title),
      state: entry.state,
      linear_state: Map.get(entry, :linear_state),
      current_phase: Map.get(entry, :current_phase),
      current_action: Map.get(entry, :current_action),
      health: Map.get(entry, :health),
      thread_id: Map.get(entry, :thread_id),
      turn_id: Map.get(entry, :turn_id),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      issue_url: Map.get(entry, :issue_url),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      run_duration_seconds: Map.get(entry, :runtime_seconds, 0),
      last_error: Map.get(entry, :last_error),
      run_status: Map.get(entry, :run_status),
      approval_pending: Map.get(entry, :approval_pending),
      tool_failure: Map.get(entry, :tool_failure),
      blocked_by: dependency_list_payload(Map.get(entry, :blocked_by)),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      linear_state: Map.get(running, :linear_state),
      current_phase: Map.get(running, :current_phase),
      current_action: Map.get(running, :current_action),
      run_status: Map.get(running, :run_status),
      health: Map.get(running, :health),
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp issue_precheck_entry(%{identifier: identifier, id: issue_id, state: state}) do
    %{"issue_identifier" => identifier, "issue_id" => issue_id, "state" => state}
  end

  defp issue_precheck_entry(%{} = entry) do
    %{}
    |> maybe_put_payload_value("issue_identifier", Map.get(entry, :identifier, Map.get(entry, "issue_identifier")))
    |> maybe_put_payload_value("issue_id", Map.get(entry, :id, Map.get(entry, "issue_id")))
    |> maybe_put_payload_value("state", Map.get(entry, :state, Map.get(entry, "state")))
  end

  defp project_validation_error_summary(errors) when is_list(errors) do
    errors
    |> Enum.map(&project_validation_error_label/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(", ")
    |> case do
      "" -> nil
      summary -> summary
    end
  end

  defp project_validation_error_summary(_errors), do: nil

  defp dependency_list_payload(value) do
    value
    |> List.wrap()
    |> Enum.map(&dependency_payload/1)
    |> Enum.filter(&dependency_present?/1)
  end

  defp dependency_payload(item) when is_map(item) do
    %{}
    |> maybe_put_payload_value(:issue_identifier, map_value(item, :issue_identifier) || map_value(item, :identifier))
    |> maybe_put_payload_value(:title, map_value(item, :title))
    |> maybe_put_payload_value(:linear_state, map_value(item, :linear_state) || map_value(item, :state))
    |> maybe_put_payload_value(:url, map_value(item, :url))
  end

  defp dependency_payload(_item), do: %{}

  defp dependency_present?(dependency) when is_map(dependency) do
    Enum.any?(dependency, fn {_key, value} -> is_binary(value) and value != "" end)
  end

  defp dependency_present?(_dependency), do: false

  defp attention_items_payload(value) do
    value
    |> List.wrap()
    |> Enum.map(&attention_item_payload/1)
    |> Enum.filter(&attention_item_present?/1)
  end

  defp attention_item_payload(item) when is_map(item) do
    %{}
    |> maybe_put_payload_value(:kind, map_value(item, :kind))
    |> maybe_put_payload_value(:message, map_value(item, :message))
  end

  defp attention_item_payload(item) when is_binary(item) do
    %{kind: attention_kind_for_message(item), message: item}
  end

  defp attention_item_payload(_item), do: %{}

  defp attention_item_present?(item) when is_map(item) do
    is_binary(Map.get(item, :message)) and Map.get(item, :message) != ""
  end

  defp attention_item_present?(_item), do: false

  defp attention_kind_for_message(message) when is_binary(message) do
    lower = String.downcase(message)

    cond do
      String.contains?(lower, "attention") -> "needs_attention"
      String.contains?(lower, "stalled") -> "possibly_stalled"
      true -> "attention"
    end
  end

  defp m3_generated_at(payload) do
    case m3_payload_value(payload, :generated_at) do
      value when is_binary(value) and value != "" -> value
      _ -> generated_at()
    end
  end

  defp m3_payload_value(payload, key, default \\ nil),
    do: Map.get(payload, key, Map.get(payload, Atom.to_string(key), default))

  defp m3_issue_entries(payload, key) do
    payload
    |> m3_payload_value(key, [])
    |> m3_list_value()
    |> Enum.map(&issue_precheck_entry/1)
  end

  defp m3_current_work_payload(payload) do
    current_work = m3_payload_value(payload, :current_work, %{})

    entries =
      current_work
      |> m3_nested_value(:entries, [])
      |> m3_list_value()
      |> Enum.map(fn entry ->
        %{}
        |> maybe_put_payload_value("issue_id", m3_nested_value(entry, :issue_id))
        |> maybe_put_payload_value("issue_identifier", m3_nested_value(entry, :issue_identifier))
        |> maybe_put_payload_value("state", m3_nested_value(entry, :state))
        |> maybe_put_payload_value("worker_host", m3_nested_value(entry, :worker_host))
        |> maybe_put_payload_value("workspace_path", m3_nested_value(entry, :workspace_path))
      end)

    %{
      count: m3_current_work_count(current_work, entries),
      entries: entries
    }
  end

  defp m3_anomalies_payload(payload) do
    payload
    |> m3_payload_value(:anomalies, [])
    |> m3_list_value()
    |> Enum.map(fn anomaly ->
      %{
        "type" => anomaly |> m3_nested_value(:type) |> to_string(),
        "issue_identifier" => m3_nested_value(anomaly, :issue_identifier),
        "issue_id" => m3_nested_value(anomaly, :issue_id),
        "state" => m3_nested_value(anomaly, :state),
        "blocking_identifiers" => m3_nested_value(anomaly, :blocking_identifiers, [])
      }
    end)
  end

  defp m3_blocked_todos_payload(payload) do
    payload
    |> m3_payload_value(:blocked_todos, %{})
    |> case do
      blocked when is_map(blocked) ->
        blocked
        |> Enum.reduce(%{}, fn
          {issue_identifier, reasons}, acc when is_binary(issue_identifier) ->
            m3_put_blocked_todo_entry(acc, issue_identifier, reasons)

          _entry, acc ->
            acc
        end)

      _other ->
        %{}
    end
  end

  defp m3_put_blocked_todo_entry(acc, issue_identifier, reasons) do
    normalized_reasons =
      reasons
      |> m3_list_value()
      |> Enum.filter(&is_binary/1)

    case normalized_reasons do
      [] -> acc
      _ -> Map.put(acc, issue_identifier, normalized_reasons)
    end
  end

  defp m3_nested_value(value, key, default \\ nil)

  defp m3_nested_value(value, key, default) when is_map(value),
    do: Map.get(value, key, Map.get(value, Atom.to_string(key), default))

  defp m3_nested_value(_value, _key, default), do: default

  defp m3_list_value(value) when is_list(value), do: value
  defp m3_list_value(_value), do: []

  defp m3_current_work_count(current_work, entries) do
    case m3_nested_value(current_work, :count) do
      count when is_integer(count) and count >= 0 -> count
      _other -> length(entries)
    end
  end

  defp maybe_put_payload_value(payload, _key, nil), do: payload
  defp maybe_put_payload_value(payload, key, value), do: Map.put(payload, key, value)

  defp workspace_path(issue_identifier, running, retry) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_codex_timestamp),
        event: running.last_codex_event,
        message: summarize_message(running.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp run_context_conversation_item(item) do
    %{
      event_id: map_value(item, :event_id),
      kind: map_value(item, :kind),
      label: map_value(item, :label),
      text: map_value(item, :text)
    }
  end

  defp run_context_tool_item(item) do
    %{
      event_id: map_value(item, :event_id),
      tool: map_value(item, :tool),
      status: map_value(item, :status),
      summary: map_value(item, :summary)
    }
  end

  defp run_context_shell_item(item) do
    %{
      event_id: map_value(item, :event_id),
      kind: map_value(item, :kind),
      text: map_value(item, :text)
    }
  end

  defp run_context_subagent_item(item) do
    %{
      event_id: map_value(item, :event_id),
      label: map_value(item, :label),
      text: map_value(item, :text)
    }
  end

  defp generated_at do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
