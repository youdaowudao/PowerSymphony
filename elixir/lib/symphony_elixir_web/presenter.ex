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
      runtime_state: project_runtime_payload(runtime_state)
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
    |> Map.get(:status, :not_started)
    |> to_string()
  end

  defp runtime_state_status(_runtime_state), do: "not_started"

  defp runtime_state_value(%{} = runtime_state, key), do: Map.get(runtime_state, key)
  defp runtime_state_value(_runtime_state, _key), do: nil

  defp normalized_config_value(entry, key) do
    entry
    |> Map.get(:normalized_config)
    |> runtime_state_value(key)
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
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
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
            normalized_reasons =
              reasons
              |> m3_list_value()
              |> Enum.filter(&is_binary/1)

            if normalized_reasons == [] do
              acc
            else
              Map.put(acc, issue_identifier, normalized_reasons)
            end

          _entry, acc ->
            acc
        end)

      _other ->
        %{}
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
