defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{HttpServer, ProjectProcessManager}
  alias SymphonyElixirWeb.{Endpoint, ObservabilityApiController, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    runtime_mode = runtime_mode()

    socket =
      socket
      |> assign(:payload, initial_payload(runtime_mode))
      |> assign(:projects_payload, load_projects_payload())
      |> assign(:runtime_mode, runtime_mode)
      |> assign(:project_action_feedback, nil)
      |> assign(:m3_precheck_results, %{})
      |> assign(:m3_precheck_open, %{})
      |> assign(:workflow_snapshot_status, workflow_snapshot_status(runtime_mode))
      |> assign(:workflow_snapshot_requested_version, 0)
      |> assign(:workflow_snapshot_task, nil)
      |> assign(:workflow_snapshot_refresh_pending, false)
      |> assign(:selected_project_id, nil)
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      if runtime_mode != :control_plane do
        :ok = ObservabilityPubSub.subscribe()
        send(self(), :refresh_workflow_snapshot)
      end

      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    selected_project_id =
      case socket.assigns.live_action do
        :project -> Map.get(params, "project_id")
        _ -> nil
      end

    {:noreply,
     socket
     |> assign(:selected_project_id, selected_project_id)
     |> assign(:projects_payload, load_projects_payload())}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()

    {:noreply, refresh_runtime_tick(socket)}
  end

  @impl true
  def handle_info(:refresh_workflow_snapshot, %{assigns: %{runtime_mode: :control_plane}} = socket) do
    {:noreply, socket}
  end

  def handle_info(:refresh_workflow_snapshot, socket) do
    {:noreply, refresh_workflow_snapshot(socket)}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    socket =
      socket
      |> assign(:projects_payload, load_projects_payload())
      |> assign(:project_action_feedback, nil)
      |> assign(:now, DateTime.utc_now())

    {:noreply, refresh_workflow_snapshot(socket)}
  end

  @impl true
  def handle_info({ref, {version, payload}}, %{assigns: %{workflow_snapshot_task: %{ref: ref}}} = socket)
      when is_reference(ref) do
    {:noreply, apply_workflow_snapshot(socket, ref, version, payload)}
  end

  def handle_info({ref, _payload}, %{assigns: %{workflow_snapshot_task: %{ref: ref}}} = socket)
      when is_reference(ref) do
    {:noreply, clear_workflow_snapshot_task(socket, ref)}
  end

  def handle_info({ref, _payload}, socket) when is_reference(ref) do
    {:noreply, socket}
  end

  def handle_info({:DOWN, ref, :process, _pid, :normal}, %{assigns: %{workflow_snapshot_task: %{ref: ref}}} = socket) do
    {:noreply, socket}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{assigns: %{workflow_snapshot_task: %{ref: ref}}} = socket) do
    {:noreply, handle_failed_workflow_snapshot_task(socket, ref)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    _ = cancel_workflow_snapshot_task(socket)
    :ok
  end

  @impl true
  def handle_event("project_action", %{"project_id" => project_id, "action" => action}, socket) do
    result = run_project_action(socket, action, project_id)

    feedback =
      case result do
        {:ok, _runtime_state} ->
          nil

        {:error, reason} ->
          "项目操作失败：#{format_project_action_error(reason)}"
      end

    {:noreply,
     socket
     |> assign(:projects_payload, load_projects_payload())
     |> assign(:project_action_feedback, feedback)
     |> assign(:now, DateTime.utc_now())}
  end

  def handle_event("run_m3_precheck", %{"project_id" => project_id}, socket) do
    result =
      if socket.assigns.runtime_mode == :control_plane do
        case ObservabilityApiController.project_m3_precheck_payload(project_id) do
          {:ok, body} -> body
          _ -> %{text: "m3 precheck request failed"}
        end
      else
        case SymphonyElixir.Orchestrator.m3_precheck(orchestrator()) do
          {:ok, payload} -> Presenter.m3_precheck_payload(payload)
          _ -> %{text: "m3 precheck request failed"}
        end
      end

    {:noreply,
     socket
     |> assign(:m3_precheck_results, Map.put(socket.assigns.m3_precheck_results, project_id, result))
     |> assign(:m3_precheck_open, Map.put(socket.assigns.m3_precheck_open, project_id, true))}
  end

  def handle_event("toggle_m3_precheck", %{"project_id" => project_id}, socket) do
    currently_open = Map.get(socket.assigns.m3_precheck_open, project_id, false)

    {:noreply,
     assign(
       socket,
       :m3_precheck_open,
       Map.put(socket.assigns.m3_precheck_open, project_id, not currently_open)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <%= if @runtime_mode == :control_plane do %>
              <p class="eyebrow">
                Symphony 控制台
              </p>
              <h1 class="hero-title">
                <%= if @selected_project_id, do: "项目现场", else: "运行总览" %>
              </h1>
              <p class="hero-copy">
                <%= if @selected_project_id do %>
                  聚焦单个项目的运行状态、当前工作、预检结果与直达入口，但仍然留在同一个总控台里。
                <% else %>
                  集中查看项目运行状态、当前工作、预检结果与直达入口，不再依赖分散的副页面来判断现场情况。
                <% end %>
              </p>
            <% else %>
              <p class="eyebrow">
                Symphony dashboard
              </p>
              <h1 class="hero-title">
                Operations Dashboard
              </h1>
              <p class="hero-copy">
                Inspect workflow runtime activity, retry pressure, and todo pool readiness from one place.
              </p>
            <% end %>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              <%= if @runtime_mode == :control_plane, do: "控制面已连接", else: "Runtime connected" %>
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              <%= if @runtime_mode == :control_plane, do: "等待连接", else: "Waiting for connection" %>
            </span>
          </div>
        </div>
      </header>

      <%= if @runtime_mode == :control_plane do %>
        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title"><%= if @selected_project_id, do: "项目现场", else: "项目总览" %></h2>
              <p class="section-copy">
                <%= if @selected_project_id do %>
                  保留总控台布局，只聚焦当前项目，避免再切到另一套项目页。
                <% else %>
                  把项目基础状态、当前运行信息和常用入口收在同一页，优先服务现场判断。
                <% end %>
              </p>
            </div>
          </div>

          <%= if is_binary(@project_action_feedback) do %>
            <p class="empty-state"><%= @project_action_feedback %></p>
          <% end %>

          <%= if control_plane_projects(@projects_payload, @selected_project_id) == [] do %>
            <p class="empty-state">
              <%= if @selected_project_id do %>
                未找到项目 <span class="mono"><%= @selected_project_id %></span>。
              <% else %>
                尚未登记项目。
              <% end %>
            </p>
          <% else %>
            <section class="metric-grid">
              <article class="metric-card">
                <p class="metric-label">项目数</p>
                <p class="metric-value numeric"><%= length(control_plane_projects(@projects_payload, @selected_project_id)) %></p>
                <p class="metric-detail">当前视图中可操作的项目数量。</p>
              </article>
              <article class="metric-card">
                <p class="metric-label">运行中</p>
                <p class="metric-value numeric"><%= count_projects_with_status(control_plane_projects(@projects_payload, @selected_project_id), "running") %></p>
                <p class="metric-detail">worker 正常在线并可响应的项目。</p>
              </article>
              <article class="metric-card">
                <p class="metric-label">启动失败</p>
                <p class="metric-value numeric"><%= count_projects_with_status(control_plane_projects(@projects_payload, @selected_project_id), "start_failed") %></p>
                <p class="metric-detail">需要先看日志定位启动问题的项目。</p>
              </article>
              <article class="metric-card">
                <p class="metric-label">活跃运行</p>
                <p class="metric-value numeric"><%= total_active_runs(control_plane_projects(@projects_payload, @selected_project_id)) %></p>
                <p class="metric-detail">当前页面里可直达的活跃 run 总数。</p>
              </article>
            </section>

            <section :if={@selected_project_id} class="section-card" style="margin-bottom: 1.25rem;">
              <% project = List.first(control_plane_projects(@projects_payload, @selected_project_id)) %>
              <div class="section-header">
                <div>
                  <h3 class="section-title"><%= project.project_name || project.project_id || @selected_project_id %></h3>
                  <p class="section-copy">首页内聚焦视图，保留项目摘要与当前运行信息，不再依赖独立项目页。</p>
                </div>
                <a class="issue-link" href="/">返回总览</a>
              </div>

              <div class="detail-stack">
                <p class="mono"><%= "project_id: #{blank_to_na(project.project_id)}" %></p>
                <p class="mono"><%= "启用: #{format_enabled(project.enabled)}" %></p>
                <p class="mono"><%= "校验: #{humanize_validation_result(project.validation_result)}" %></p>
                <p class="mono"><%= "Worker 状态: #{humanize_worker_status(project.worker_status)}" %></p>
                <p class="mono"><%= "Worker 端口: #{blank_to_na(project.worker_port)}" %></p>
                <p class="mono"><%= "当前活跃运行: #{project_run_count(project)}" %></p>
                <p class="mono"><%= "最近存活: #{blank_to_na(project.last_seen_at)}" %></p>
                <p class="mono"><%= "最近错误: #{blank_to_na(project_runtime_or_validation_error(project))}" %></p>
                <%= if is_binary(project.project_id) and project.project_id != "" do %>
                  <a class="issue-link" href={"/api/v1/projects/#{project.project_id}/summary"}>JSON 摘要</a>
                  <a :if={is_integer(project.worker_port)} class="issue-link" href={"http://127.0.0.1:#{project.worker_port}/"}>Worker 页面</a>
                <% end %>
                <%= if failure_help = project_runtime_failure_help(project) do %>
                  <p :if={is_binary(failure_help.stderr_path) and failure_help.stderr_path != ""} class="mono">
                    <%= failure_help.stderr_path %>
                  </p>
                  <p class="muted event-meta"><%= failure_help.next_step %></p>
                  <p class="muted event-meta"><%= failure_help.retry_hint %></p>
                <% end %>
              </div>
            </section>

            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>项目概览</th>
                    <th>当前运行</th>
                    <th>启用</th>
                    <th>Worker 状态</th>
                    <th>Worker 端口</th>
                    <th>最近存活</th>
                    <th>最近错误</th>
                    <th>操作</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={project <- control_plane_projects(@projects_payload, @selected_project_id)}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= project.project_name || project.project_id || "n/a" %></span>
                        <span class="mono">
                          <%= "project_id: #{blank_to_na(project.project_id)}" %>
                          ·
                          <%= "校验: #{humanize_validation_result(project.validation_result)}" %>
                        </span>
                        <%= if is_binary(project.project_id) and project.project_id != "" do %>
                          <a class="issue-link" href={"/projects/#{project.project_id}"}>项目现场</a>
                          <a class="issue-link" href={"/api/v1/projects/#{project.project_id}/summary"}>JSON 摘要</a>
                          <a :if={is_integer(project.worker_port)} class="issue-link" href={"http://127.0.0.1:#{project.worker_port}/"}>Worker 页面</a>
                        <% end %>
                      </div>
                    </td>
                    <td>
                      <div class="detail-stack">
                        <span class="muted event-meta"><%= project_run_preview_caption(project) %></span>
                        <div :for={summary <- project_run_preview_summaries(project)} class="detail-stack">
                          <span class="mono">
                            <%= summary.issue_identifier || "n/a" %> · <%= Presenter.project_run_summary_title(summary) %>
                          </span>
                          <span class={state_badge_class(summary.current_phase || summary.linear_state || summary.health)}>
                            <%= humanize_run_state(summary.current_phase || summary.linear_state || summary.health || "running") %>
                          </span>
                          <span
                            :if={project_run_preview_health_meta(summary)}
                            class="muted event-meta"
                          >
                            <%= humanize_run_health_meta(project_run_preview_health_meta(summary)) %>
                          </span>
                          <span
                            :if={is_binary(summary.current_action) and summary.current_action != ""}
                            class="mono"
                          >
                            <%= summary.current_action %>
                          </span>
                          <span class="muted event-meta"><%= Presenter.project_run_summary_runtime(summary) %></span>
                          <a
                            :if={is_binary(project.project_id) and is_binary(summary.issue_identifier)}
                            class="issue-link"
                            href={run_path(project.project_id, summary.issue_identifier)}
                          >
                            打开运行
                          </a>
                        </div>
                        <span :if={project_run_preview_overflow?(project)} class="muted event-meta">
                          仅展示前 3 条运行。
                        </span>
                      </div>
                    </td>
                    <td>
                      <%= format_enabled(project.enabled) %>
                    </td>
                    <td>
                      <span class={state_badge_class(project.worker_status)}>
                        <%= humanize_worker_status(project.worker_status) %>
                      </span>
                    </td>
                    <td>
                      <%= project.worker_port || "n/a" %>
                    </td>
                    <td class="mono">
                      <%= blank_to_na(project.last_seen_at) %>
                    </td>
                    <td>
                      <div class="detail-stack">
                        <span><%= project_runtime_or_validation_error(project) |> blank_to_na() %></span>
                        <%= if failure_help = project_runtime_failure_help(project) do %>
                          <span :if={is_binary(failure_help.stderr_path) and failure_help.stderr_path != ""} class="mono">
                            <%= failure_help.stderr_path %>
                          </span>
                          <span class="muted event-meta"><%= failure_help.next_step %></span>
                          <span class="muted event-meta"><%= failure_help.retry_hint %></span>
                        <% end %>
                      </div>
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
                          启动
                        </button>
                        <button
                          type="button"
                          class="subtle-button"
                          phx-click="project_action"
                          phx-value-project_id={project.project_id}
                          phx-value-action="stop"
                          disabled={project_action_disabled?(project, "stop")}
                        >
                          停止
                        </button>
                        <button
                          type="button"
                          class="subtle-button"
                          phx-click="project_action"
                          phx-value-project_id={project.project_id}
                          phx-value-action="restart"
                          disabled={project_action_disabled?(project, "restart")}
                        >
                          重启
                        </button>
                        <button
                          type="button"
                          class="subtle-button"
                          phx-click="run_m3_precheck"
                          phx-value-project_id={project.project_id}
                          disabled={project.worker_status != "running"}
                        >
                          运行预检
                        </button>
                      </div>
                      <details class="session-stack" open={Map.get(@m3_precheck_open, project.project_id, false)}>
                        <summary phx-click="toggle_m3_precheck" phx-value-project_id={project.project_id}>M3-0 预检</summary>
                        <.m3_precheck_result result={Map.get(@m3_precheck_results, project.project_id, %{})} />
                      </details>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% else %>
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
              <h2 class="section-title">Todo 池检验</h2>
              <p class="section-copy">
                <%= if workflow_snapshot_loading?(@workflow_snapshot_status) do %>
                  Run the workflow M3-0 precheck while the runtime snapshot is still loading.
                <% else %>
                  Run the workflow M3-0 precheck directly from the main runtime dashboard.
                <% end %>
              </p>
            </div>

            <button
              type="button"
              class="subtle-button"
              phx-click="run_m3_precheck"
              phx-value-project_id={workflow_m3_project_id()}
            >
              运行预检
            </button>
          </div>

          <% workflow_result = Map.get(@m3_precheck_results, workflow_m3_project_id(), %{}) %>
          <details class="session-stack" open={Map.get(@m3_precheck_open, workflow_m3_project_id(), false)}>
            <summary phx-click="toggle_m3_precheck" phx-value-project_id={workflow_m3_project_id()}>M3-0 预检</summary>
            <.m3_precheck_result :if={not m3_result_unavailable?(workflow_result)} result={workflow_result} />
            <p :if={m3_result_unavailable?(workflow_result)} class="empty-state">
              尚未运行。点击“运行预检”查看当前 Todo 池放行、容量排队、阻塞与异常判断。
            </p>
          </details>
        </section>

        <%= if workflow_snapshot_loading?(@workflow_snapshot_status) do %>
          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Loading workflow snapshot</h2>
                <p class="section-copy">Runtime metrics, running sessions, retry queue, and rate limits will appear here once the snapshot arrives.</p>
              </div>
            </div>

            <div class="detail-stack">
              <p class="mono">Metrics pending</p>
              <p class="mono">Running sessions pending</p>
              <p class="mono">Retry queue pending</p>
              <p class="mono">Rate limits pending</p>
            </div>
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
                          <span class={state_badge_class(entry.health || entry.current_phase || entry.state)}>
                            <%= entry.current_phase || entry.state %>
                          </span>
                          <div class="muted event-meta"><%= entry.linear_state || entry.state %> · <%= entry.health || "unknown" %></div>
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
                            <span class="event-text"><%= running_activity_summary(entry) %></span>
                            <span class="muted event-meta"><%= running_activity_meta(entry) %></span>
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
      <% end %>
    </section>
    """
  end

  attr(:result, :map, default: %{})

  defp m3_precheck_result(assigns) do
    ~H"""
    <div class="session-stack">
      <p :if={m3_result_has_payload?(@result)} class="mono">
        <%= "可放行 #{length(m3_issue_entries(@result, :eligible_todos))}" %>
        ·
        <%= "容量排队 #{length(m3_issue_entries(@result, :capacity_queued_todos))}" %>
        ·
        <%= "本轮已派发 #{length(m3_issue_entries(@result, :dispatched_todos))}" %>
        ·
        <%= "阻塞 #{length(m3_blocked_entries(@result))}" %>
        ·
        <%= "执行中 #{length(m3_current_work_entries(@result))}" %>
        ·
        <%= "异常 #{length(m3_anomalies(@result))}" %>
      </p>

      <section :if={m3_result_has_payload?(@result) and m3_issue_entries(@result, :eligible_todos) != []} class="session-stack">
        <p class="issue-id">可放行 Todo</p>
        <p :for={entry <- m3_issue_entries(@result, :eligible_todos)} class="mono">
          <%= m3_issue_label(entry) %>
        </p>
      </section>

      <section :if={m3_result_has_payload?(@result) and m3_blocked_entries(@result) != []} class="session-stack">
        <p class="issue-id">依赖阻塞</p>
        <p :for={{issue_identifier, reasons} <- m3_blocked_entries(@result)} class="mono">
          <%= issue_identifier %>: <%= Enum.join(reasons, "; ") %>
        </p>
      </section>

      <section :if={m3_result_has_payload?(@result) and m3_issue_entries(@result, :capacity_queued_todos) != []} class="session-stack">
        <p class="issue-id">容量排队</p>
        <p :for={entry <- m3_issue_entries(@result, :capacity_queued_todos)} class="mono">
          <%= m3_issue_label(entry) %>
        </p>
      </section>

      <section :if={m3_result_has_payload?(@result) and m3_issue_entries(@result, :dispatched_todos) != []} class="session-stack">
        <p class="issue-id">本轮已派发</p>
        <p :for={entry <- m3_issue_entries(@result, :dispatched_todos)} class="mono">
          <%= m3_issue_label(entry) %>
        </p>
      </section>

      <section :if={m3_result_has_payload?(@result) and m3_current_work_entries(@result) != []} class="session-stack">
        <p class="issue-id">当前执行中</p>
        <p :for={entry <- m3_current_work_entries(@result)} class="mono">
          <%= m3_issue_label(entry) %><%= m3_worker_host_suffix(entry) %>
        </p>
      </section>

      <section :if={m3_result_has_payload?(@result) and m3_anomalies(@result) != []} class="session-stack">
        <p class="issue-id">异常执行态</p>
        <p :for={anomaly <- m3_anomalies(@result)} class="mono">
          <%= m3_issue_label(anomaly) %><%= m3_anomaly_blockers_suffix(anomaly) %>
        </p>
      </section>

      <p :if={not m3_result_has_payload?(@result) and is_binary(m3_result_text(@result)) and m3_result_text(@result) != ""} class="mono">
        <%= m3_result_text(@result) %>
      </p>

      <p :if={m3_result_has_payload?(@result) and m3_result_empty?(@result) and m3_result_text(@result) in [nil, ""]} class="mono">(none)</p>
    </div>
    """
  end

  defp load_projects_payload do
    Presenter.dashboard_projects_payload(project_registry())
  end

  defp initial_payload(:control_plane), do: Presenter.empty_state_payload()
  defp initial_payload(:workflow), do: Presenter.empty_state_payload()

  defp workflow_snapshot_status(:control_plane), do: :ready
  defp workflow_snapshot_status(:workflow), do: :loading

  defp workflow_snapshot_loading?(:loading), do: true
  defp workflow_snapshot_loading?(_status), do: false

  defp refresh_workflow_snapshot(%{assigns: %{runtime_mode: :workflow}} = socket) do
    case socket.assigns.workflow_snapshot_task do
      %Task{} ->
        assign(socket, :workflow_snapshot_refresh_pending, true)

      _ ->
        start_workflow_snapshot_refresh(socket)
    end
  end

  defp refresh_workflow_snapshot(socket), do: socket

  defp start_workflow_snapshot_refresh(%{assigns: %{runtime_mode: :control_plane}} = socket), do: socket

  defp start_workflow_snapshot_refresh(socket) do
    version = socket.assigns.workflow_snapshot_requested_version + 1

    task =
      Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
        {version, Presenter.state_payload(orchestrator(), snapshot_timeout_ms())}
      end)

    status =
      if socket.assigns.workflow_snapshot_requested_version == 0 do
        :loading
      else
        socket.assigns.workflow_snapshot_status
      end

    socket
    |> assign(:workflow_snapshot_status, status)
    |> assign(:workflow_snapshot_requested_version, version)
    |> assign(:workflow_snapshot_task, task)
    |> assign(:workflow_snapshot_refresh_pending, false)
  end

  defp apply_workflow_snapshot(socket, task_ref, version, payload) when is_integer(version) do
    payload_status = snapshot_status_from_payload(payload)

    cond do
      loading_ready_snapshot?(socket, task_ref, version, payload_status) ->
        socket
        |> assign(:payload, payload)
        |> assign(:workflow_snapshot_status, payload_status)
        |> clear_workflow_snapshot_task(task_ref)
        |> maybe_start_pending_workflow_snapshot_refresh()

      socket.assigns.workflow_snapshot_refresh_pending ->
        socket
        |> clear_workflow_snapshot_task(task_ref)
        |> maybe_start_pending_workflow_snapshot_refresh()

      version == socket.assigns.workflow_snapshot_requested_version ->
        socket
        |> assign(:payload, payload)
        |> assign(:workflow_snapshot_status, payload_status)
        |> clear_workflow_snapshot_task(task_ref)
        |> maybe_start_pending_workflow_snapshot_refresh()

      true ->
        socket
        |> clear_workflow_snapshot_task(task_ref)
        |> maybe_start_pending_workflow_snapshot_refresh()
    end
  end

  defp apply_workflow_snapshot(socket, task_ref, _version, _payload) do
    socket
    |> clear_workflow_snapshot_task(task_ref)
    |> maybe_start_pending_workflow_snapshot_refresh()
  end

  defp snapshot_status_from_payload(%{error: %{code: "snapshot_timeout"}}), do: :error
  defp snapshot_status_from_payload(%{error: %{code: "snapshot_unavailable"}}), do: :error
  defp snapshot_status_from_payload(_payload), do: :ready

  defp loading_ready_snapshot?(socket, task_ref, version, :ready) do
    socket.assigns.workflow_snapshot_status == :loading and
      socket.assigns.workflow_snapshot_requested_version == version and
      match?(%Task{ref: ^task_ref}, socket.assigns.workflow_snapshot_task)
  end

  defp loading_ready_snapshot?(_socket, _task_ref, _version, _payload_status), do: false

  defp handle_failed_workflow_snapshot_task(socket, task_ref) do
    socket
    |> clear_workflow_snapshot_task(task_ref)
    |> maybe_mark_initial_workflow_snapshot_failed()
    |> maybe_start_pending_workflow_snapshot_refresh()
  end

  defp maybe_mark_initial_workflow_snapshot_failed(%{assigns: %{workflow_snapshot_status: :loading}} = socket) do
    socket
    |> assign(:payload, workflow_snapshot_failure_payload())
    |> assign(:workflow_snapshot_status, :error)
  end

  defp maybe_mark_initial_workflow_snapshot_failed(socket), do: socket

  defp workflow_snapshot_failure_payload do
    Presenter.empty_state_payload()
    |> Map.put(:error, %{code: "snapshot_unavailable", message: "Snapshot unavailable"})
  end

  defp cancel_workflow_snapshot_task(%{assigns: %{workflow_snapshot_task: %Task{} = task}} = socket) do
    _ = Task.shutdown(task, :brutal_kill)
    clear_workflow_snapshot_task(socket, task.ref)
  end

  defp cancel_workflow_snapshot_task(socket), do: socket

  defp clear_workflow_snapshot_task(%{assigns: %{workflow_snapshot_task: %Task{} = task}} = socket, task_ref)
       when task.ref == task_ref do
    _ = Process.demonitor(task.ref, [:flush])
    assign(socket, :workflow_snapshot_task, nil)
  end

  defp clear_workflow_snapshot_task(%{assigns: %{workflow_snapshot_task: %Task{} = task}} = socket, nil) do
    _ = Process.demonitor(task.ref, [:flush])
    assign(socket, :workflow_snapshot_task, nil)
  end

  defp clear_workflow_snapshot_task(socket, _task_ref) do
    socket
  end

  defp maybe_start_pending_workflow_snapshot_refresh(%{assigns: %{workflow_snapshot_refresh_pending: true}} = socket) do
    start_workflow_snapshot_refresh(socket)
  end

  defp maybe_start_pending_workflow_snapshot_refresh(socket), do: socket

  defp refresh_runtime_tick(socket) do
    socket
    |> assign(:now, DateTime.utc_now())
    |> maybe_refresh_project_summaries()
  end

  defp maybe_refresh_project_summaries(%{assigns: %{runtime_mode: :control_plane}} = socket) do
    assign(socket, :projects_payload, load_projects_payload())
  end

  defp maybe_refresh_project_summaries(socket), do: socket

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
    case reason do
      :project_actions_unavailable -> "当前模式不支持项目操作"
      :project_manager_unavailable -> "项目进程管理器当前不可用"
      :unsupported_action -> "不支持这个操作"
      :disabled -> "项目已禁用，当前不能操作"
      :config_invalid -> "项目配置无效，当前不能操作"
      :already_running -> "项目已经在运行中"
      :not_running -> "项目当前没有在运行"
      other -> other |> Atom.to_string() |> String.replace("_", " ")
    end
  end

  defp format_project_action_error({:workflow_generation_failed, reason}) do
    "生成 workflow 失败：#{format_project_action_error_detail(reason)}"
  end

  defp format_project_action_error(reason), do: inspect(reason)

  defp format_project_action_error_detail(reason) when is_atom(reason) do
    reason
    |> Atom.to_string()
    |> String.replace("_", " ")
  end

  defp format_project_action_error_detail({:missing_workflow_file, path, raw_reason}) do
    "缺少 workflow 文件 #{path}: #{inspect(raw_reason)}"
  end

  defp format_project_action_error_detail({:workflow_parse_error, raw_reason}) do
    "workflow 解析失败: #{inspect(raw_reason)}"
  end

  defp format_project_action_error_detail(reason), do: inspect(reason)

  defp project_runtime_or_validation_error(project) do
    Presenter.project_runtime_or_validation_error(project)
  end

  defp project_runtime_failure_help(project) do
    Presenter.project_runtime_failure_help(project)
  end

  defp control_plane_projects(%{projects: projects}, nil) when is_list(projects), do: projects

  defp control_plane_projects(%{projects: projects}, selected_project_id)
       when is_list(projects) and is_binary(selected_project_id) do
    Enum.filter(projects, fn project -> project.project_id == selected_project_id end)
  end

  defp control_plane_projects(_payload, _selected_project_id), do: []

  defp project_action_disabled?(project, action) do
    project.validation_result == "invalid" or
      project.worker_status in ["disabled", "config_invalid"] or
      project_action_disallowed_for_status?(project.worker_status, action)
  end

  defp project_action_disallowed_for_status?(status, action) do
    (status in ["not_started", "stopped"] and action == "stop") or
      (status in ["running", "unreachable"] and action == "start")
  end

  defp workflow_m3_project_id, do: "workflow"

  defp m3_issue_entries(nil, _key), do: []

  defp m3_issue_entries(result, key) when is_map(result) do
    Map.get(result, key, Map.get(result, Atom.to_string(key), []))
  end

  defp m3_issue_entries(_result, _key), do: []

  defp project_run_preview_summaries(project) when is_map(project) do
    project
    |> Map.get(:run_summaries, Map.get(project, "run_summaries", []))
    |> List.wrap()
    |> Enum.take(3)
  end

  defp project_run_preview_summaries(_project), do: []

  defp project_run_preview_caption(project) when is_map(project) do
    count =
      project
      |> Map.get(:run_summaries, Map.get(project, "run_summaries", []))
      |> List.wrap()
      |> length()

    case count do
      0 -> "当前无活跃运行。"
      1 -> "1 条活跃运行。"
      value -> "#{value} 条活跃运行。"
    end
  end

  defp project_run_preview_caption(_project), do: "当前无活跃运行。"

  defp project_run_preview_overflow?(project) when is_map(project) do
    project
    |> Map.get(:run_summaries, Map.get(project, "run_summaries", []))
    |> List.wrap()
    |> length() > 3
  end

  defp project_run_preview_overflow?(_project), do: false

  defp project_run_preview_health_meta(summary) when is_map(summary) do
    value = Presenter.project_run_summary_health_meta(summary)

    if value == "n/a" do
      nil
    else
      value
    end
  end

  defp project_run_preview_health_meta(_summary), do: nil

  defp humanize_validation_result("valid"), do: "通过"
  defp humanize_validation_result("invalid"), do: "未通过"
  defp humanize_validation_result(value) when is_binary(value), do: value
  defp humanize_validation_result(value), do: to_string(value)

  defp humanize_worker_status("running"), do: "运行中"
  defp humanize_worker_status("not_started"), do: "未启动"
  defp humanize_worker_status("stopped"), do: "已停止"
  defp humanize_worker_status("start_failed"), do: "启动失败"
  defp humanize_worker_status("disabled"), do: "已禁用"
  defp humanize_worker_status("config_invalid"), do: "配置无效"
  defp humanize_worker_status("unreachable"), do: "失去连接"
  defp humanize_worker_status(value) when is_binary(value), do: value
  defp humanize_worker_status(value), do: to_string(value)

  defp humanize_run_state("codex_waiting_next_event"), do: "等待新事件"
  defp humanize_run_state("codex_reasoning"), do: "推理中"
  defp humanize_run_state("codex_running_shell"), do: "执行命令中"
  defp humanize_run_state("codex_editing_files"), do: "改文件中"
  defp humanize_run_state("starting_codex_turn"), do: "启动回合中"
  defp humanize_run_state("possibly_stalled"), do: "可能卡住"
  defp humanize_run_state("running"), do: "运行中"
  defp humanize_run_state("In Progress"), do: "进行中"
  defp humanize_run_state(value) when is_binary(value), do: value
  defp humanize_run_state(value), do: to_string(value)

  defp humanize_run_health_meta(nil), do: nil

  defp humanize_run_health_meta(value) when is_binary(value) do
    value
    |> String.replace("In Progress", "进行中")
    |> String.replace("possibly_stalled", "可能卡住")
    |> String.replace("normal", "正常")
  end

  defp humanize_run_health_meta(value), do: value

  defp count_projects_with_status(projects, status) when is_list(projects) do
    Enum.count(projects, &(&1.worker_status == status))
  end

  defp count_projects_with_status(_projects, _status), do: 0

  defp total_active_runs(projects) when is_list(projects) do
    Enum.reduce(projects, 0, fn project, total ->
      total + project_run_count(project)
    end)
  end

  defp total_active_runs(_projects), do: 0

  defp project_run_count(project) when is_map(project) do
    project
    |> Map.get(:run_summaries, Map.get(project, "run_summaries", []))
    |> List.wrap()
    |> length()
  end

  defp project_run_count(_project), do: 0

  defp m3_blocked_entries(result) when is_map(result) do
    result
    |> Map.get(:blocked_todos, Map.get(result, "blocked_todos", %{}))
    |> Enum.sort_by(fn {issue_identifier, _reasons} -> issue_identifier end)
  end

  defp m3_blocked_entries(_result), do: []

  defp m3_current_work_entries(result) when is_map(result) do
    current_work = Map.get(result, :current_work, Map.get(result, "current_work", %{}))
    Map.get(current_work, :entries, Map.get(current_work, "entries", []))
  end

  defp m3_current_work_entries(_result), do: []

  defp m3_anomalies(result) when is_map(result) do
    Map.get(result, :anomalies, Map.get(result, "anomalies", []))
  end

  defp m3_anomalies(_result), do: []

  defp m3_result_empty?(result) do
    m3_issue_entries(result, :eligible_todos) == [] and
      m3_issue_entries(result, :capacity_queued_todos) == [] and
      m3_issue_entries(result, :dispatched_todos) == [] and
      m3_blocked_entries(result) == [] and
      m3_current_work_entries(result) == [] and
      m3_anomalies(result) == []
  end

  defp m3_result_has_payload?(result) when is_map(result) do
    Map.has_key?(result, :generated_at) or
      Map.has_key?(result, "generated_at") or
      Map.has_key?(result, :m3_enabled) or
      Map.has_key?(result, "m3_enabled")
  end

  defp m3_result_has_payload?(_result), do: false

  defp m3_result_unavailable?(result) do
    m3_result_empty?(result) and
      not is_binary(m3_result_text(result))
  end

  defp m3_result_text(result) when is_map(result) do
    Map.get(result, :text, Map.get(result, "text"))
  end

  defp m3_result_text(_result), do: nil

  defp m3_issue_label(%{"issue_identifier" => identifier, "state" => state})
       when is_binary(identifier) and is_binary(state),
       do: "#{identifier} (#{state})"

  defp m3_issue_label(%{issue_identifier: identifier, state: state})
       when is_binary(identifier) and is_binary(state),
       do: "#{identifier} (#{state})"

  defp m3_issue_label(%{"issue_identifier" => identifier}) when is_binary(identifier), do: identifier
  defp m3_issue_label(%{issue_identifier: identifier}) when is_binary(identifier), do: identifier
  defp m3_issue_label(_entry), do: "unknown"

  defp m3_worker_host_suffix(entry) when is_map(entry) do
    worker_host = Map.get(entry, "worker_host", Map.get(entry, :worker_host))
    if is_binary(worker_host) and worker_host != "", do: " @#{worker_host}", else: ""
  end

  defp m3_worker_host_suffix(_entry), do: ""

  defp run_path(project_id, issue_identifier) do
    encoded_project_id = URI.encode(to_string(project_id), &URI.char_unreserved?/1)
    encoded_issue_identifier = URI.encode(to_string(issue_identifier), &URI.char_unreserved?/1)

    "/projects/#{encoded_project_id}/runs/#{encoded_issue_identifier}"
  end

  defp m3_anomaly_blockers_suffix(anomaly) when is_map(anomaly) do
    blockers = Map.get(anomaly, "blocking_identifiers", Map.get(anomaly, :blocking_identifiers, []))

    case blockers do
      [_ | _] = identifiers -> " blocked by #{Enum.join(identifiers, ", ")}"
      _ -> ""
    end
  end

  defp m3_anomaly_blockers_suffix(_anomaly), do: ""

  defp running_activity_summary(entry) do
    current_action(entry) || turns_or_session_summary(entry)
  end

  defp current_action(entry) do
    if is_binary(entry.current_action) and entry.current_action != "", do: entry.current_action
  end

  defp turns_or_session_summary(entry) do
    cond do
      is_integer(entry.turn_count) and entry.turn_count > 0 and entry.session_id ->
        "#{entry.turn_count} turns · session id available"

      is_integer(entry.turn_count) and entry.turn_count > 0 ->
        "#{entry.turn_count} turns"

      entry.session_id ->
        "session id available"

      true ->
        "status tracked"
    end
  end

  defp running_activity_meta(entry) do
    cond do
      is_binary(entry.current_phase) and is_binary(entry.health) ->
        "#{entry.current_phase} · #{entry.health}"

      not is_nil(entry.session_id) and activity_summary_present?(entry) ->
        "session id available · summary withheld"

      not is_nil(entry.session_id) ->
        "session id available"

      activity_summary_present?(entry) ->
        "summary withheld"

      true ->
        "no recent summary"
    end
  end

  defp activity_summary_present?(entry) do
    not is_nil(entry.last_message) or not is_nil(entry.last_event) or not is_nil(entry.last_event_at)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)

  defp project_validation_error_label(error), do: Presenter.project_validation_error_label(error)

  defp format_enabled(true), do: "是"
  defp format_enabled(false), do: "否"
  defp format_enabled(value), do: blank_to_na(value)

  defp blank_to_na(""), do: "n/a"
  defp blank_to_na(nil), do: "n/a"
  defp blank_to_na(value), do: value
end
