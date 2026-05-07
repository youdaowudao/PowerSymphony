defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{HttpServer, ProjectProcessManager}
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    runtime_mode = runtime_mode()

    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:projects_payload, load_projects_payload())
      |> assign(:runtime_mode, runtime_mode)
      |> assign(:project_action_feedback, nil)
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      if runtime_mode != :control_plane do
        :ok = ObservabilityPubSub.subscribe()
      end

      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()

    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:projects_payload, load_projects_payload())
     |> assign(:project_action_feedback, nil)
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("project_action", %{"project_id" => project_id, "action" => action}, socket) do
    result = run_project_action(socket, action, project_id)

    feedback =
      case result do
        {:ok, _runtime_state} ->
          nil

        {:error, reason} ->
          "Project action failed: #{format_project_action_error(reason)}"
      end

    {:noreply,
     socket
     |> assign(:projects_payload, load_projects_payload())
     |> assign(:project_action_feedback, feedback)
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @runtime_mode == :control_plane do %>
        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Projects</h2>
              <p class="section-copy">Static config validation with lightweight runtime summary.</p>
            </div>
          </div>

          <%= if is_binary(@project_action_feedback) do %>
            <p class="empty-state"><%= @project_action_feedback %></p>
          <% end %>

          <%= if @projects_payload.projects == [] do %>
            <p class="empty-state">No projects registered.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Project</th>
                    <th>Enabled</th>
                    <th>Worker status</th>
                    <th>Worker port</th>
                    <th>Last seen</th>
                    <th>Last error</th>
                    <th>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={project <- @projects_payload.projects}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= project.project_name || project.project_id || "n/a" %></span>
                        <span class="mono">
                          <%= "project_id: #{blank_to_na(project.project_id)}" %>
                          ·
                          <%= "validation: #{blank_to_na(project.validation_result)}" %>
                        </span>
                        <%= if is_binary(project.project_id) and project.project_id != "" do %>
                          <a class="issue-link" href={"/api/v1/projects/#{project.project_id}/summary"}>JSON summary</a>
                        <% end %>
                      </div>
                    </td>
                    <td>
                      <%= format_enabled(project.enabled) %>
                    </td>
                    <td>
                      <span class={state_badge_class(project.worker_status)}>
                        <%= project.worker_status %>
                      </span>
                    </td>
                    <td>
                      <%= project.worker_port || "n/a" %>
                    </td>
                    <td class="mono">
                      <%= blank_to_na(project.last_seen_at) %>
                    </td>
                    <td>
                      <%= project_runtime_or_validation_error(project) |> blank_to_na() %>
                    </td>
                    <td>
                      <div class="session-stack">
                        <button
                          type="button"
                          class="subtle-button"
                          phx-click="project_action"
                          phx-value-project_id={project.project_id}
                          phx-value-action="start"
                          disabled={project_action_disabled?(project, "start")}
                        >
                          Start
                        </button>
                        <button
                          type="button"
                          class="subtle-button"
                          phx-click="project_action"
                          phx-value-project_id={project.project_id}
                          phx-value-action="stop"
                          disabled={project_action_disabled?(project, "stop")}
                        >
                          Stop
                        </button>
                        <button
                          type="button"
                          class="subtle-button"
                          phx-click="project_action"
                          phx-value-project_id={project.project_id}
                          phx-value-action="restart"
                          disabled={project_action_disabled?(project, "restart")}
                        >
                          Restart
                        </button>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% else %>
      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Projects</h2>
              <p class="section-copy">Static config validation overview for the active workflow runtime.</p>
            </div>
          </div>

          <%= if @projects_payload.projects == [] do %>
            <p class="empty-state">No projects registered.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Project</th>
                    <th>Validation</th>
                    <th>Runtime</th>
                    <th>Errors</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={project <- @projects_payload.projects}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= project.project_name || project.project_id || "n/a" %></span>
                        <%= if is_binary(project.project_id) and project.project_id != "" do %>
                          <a class="issue-link" href={"/api/v1/projects/#{project.project_id}/summary"}>JSON summary</a>
                        <% end %>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(project.validation_result)}>
                        <%= project.validation_result %>
                      </span>
                    </td>
                    <td>
                      <span class={state_badge_class(project.runtime_state.status)}>
                        <%= project.runtime_state.status %>
                      </span>
                    </td>
                    <td>
                      <%= project.validation_errors |> Enum.map(&project_validation_error_label/1) |> Enum.join(", ") |> blank_to_na() %>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    if runtime_mode() == :control_plane do
      Presenter.empty_state_payload()
    else
      Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
    end
  end

  defp load_projects_payload do
    Presenter.projects_payload(project_registry())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp project_registry do
    HttpServer.project_registry()
  end

  defp runtime_mode do
    Endpoint.config(:runtime_mode) || :workflow
  end

  defp project_process_manager_name do
    Application.get_env(
      :symphony_elixir,
      :project_process_manager_name,
      SymphonyElixir.ProjectProcessManager
    )
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp run_project_action(socket, _action, _project_id)
       when socket.assigns.runtime_mode != :control_plane,
       do: {:error, :project_actions_unavailable}

  defp run_project_action(_socket, action, project_id) do
    manager_name = project_process_manager_name()

    with true <- process_manager_available?(manager_name),
         {:ok, result} <- safe_project_action_call(manager_name, action, project_id) do
      result
    else
      false ->
        {:error, :project_manager_unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_manager_available?(manager_name), do: is_pid(GenServer.whereis(manager_name))

  defp safe_project_action_call(manager_name, "start", project_id),
    do: safe_project_action(fun: fn -> ProjectProcessManager.start_project(manager_name, project_id) end)

  defp safe_project_action_call(manager_name, "stop", project_id),
    do: safe_project_action(fun: fn -> ProjectProcessManager.stop_project(manager_name, project_id) end)

  defp safe_project_action_call(manager_name, "restart", project_id),
    do: safe_project_action(fun: fn -> ProjectProcessManager.restart_project(manager_name, project_id) end)

  defp safe_project_action_call(_manager_name, _action, _project_id), do: {:error, :unsupported_action}

  defp safe_project_action(fun: fun) do
    {:ok, fun.()}
  catch
    :exit, {:noproc, _details} -> {:error, :project_manager_unavailable}
    :exit, {:timeout, _details} -> {:error, :project_action_timeout}
    :exit, {:normal, _details} -> {:error, :project_manager_unavailable}
    :exit, _other -> {:error, :project_action_failed}
  end

  defp format_project_action_error(reason) when is_atom(reason) do
    reason
    |> Atom.to_string()
    |> String.replace("_", " ")
  end

  defp format_project_action_error(reason), do: to_string(reason)

  defp project_runtime_or_validation_error(project) do
    project.last_error || project_validation_error_summary(project.validation_errors)
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

  defp project_action_disabled?(project, action) do
    cond do
      project.validation_result == "invalid" -> true
      project.worker_status == "disabled" -> true
      project.worker_status == "config_invalid" -> true
      project.worker_status in ["not_started", "stopped"] and action == "stop" -> true
      project.worker_status == "running" and action == "start" -> true
      project.worker_status == "unreachable" and action == "start" -> true
      true -> false
    end
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)

  defp project_validation_error_label(%{"field" => field, "message" => message}), do: "#{field}: #{message}"
  defp project_validation_error_label(%{field: field, message: message}), do: "#{field}: #{message}"
  defp project_validation_error_label(_error), do: "invalid"

  defp format_enabled(true), do: "true"
  defp format_enabled(false), do: "false"
  defp format_enabled(value), do: blank_to_na(value)

  defp blank_to_na(""), do: "n/a"
  defp blank_to_na(nil), do: "n/a"
  defp blank_to_na(value), do: value
end
