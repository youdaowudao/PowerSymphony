defmodule SymphonyElixirWeb.RunLive do
  @moduledoc """
  Run deep-view with lightweight summary plus lazily loaded timeline browsing.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.HttpServer
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixirWeb.{Endpoint, ObservabilityApiController, Presenter}
  @surface_names ~w(raw payload prompt shell)

  @summary_fields [
    {"issue_identifier", :issue_identifier},
    {"title", :title},
    {"linear_state", :linear_state},
    {"current_phase", :current_phase},
    {"current_action", :current_action},
    {"health", :health},
    {"thread_id", :thread_id},
    {"turn_id", :turn_id},
    {"last_event_at", :last_event_at},
    {"run_duration_seconds", :run_duration_seconds}
  ]

  @impl true
  def mount(%{"project_id" => project_id, "issue_identifier" => issue_identifier}, _session, socket) do
    socket =
      socket
      |> assign(:project_id, project_id)
      |> assign(:issue_identifier, issue_identifier)
      |> assign(:page_title, "Run detail")
      |> assign(:surface_names, @surface_names)
      |> assign(:selected_event_id, nil)
      |> assign(:section_state, initial_section_state())
      |> assign(:timeline_filter, "all")
      |> assign(:timeline_state, initial_timeline_state())
      |> assign(:context_state, initial_context_state())
      |> assign(:detail_state, initial_detail_state())
      |> load_run()

    if connected?(socket) and summary_loaded?(socket) do
      send(self(), :load_timeline)
      send(self(), :load_context)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:load_timeline, socket) do
    {:noreply, load_recent_timeline(socket)}
  end

  def handle_info(:load_context, socket) do
    {:noreply, load_context_summary(socket)}
  end

  def handle_info({:load_event_detail, event_id}, socket) do
    {:noreply, start_event_detail_task(socket, event_id)}
  end

  def handle_info({:load_event_surface, event_id, surface}, socket) do
    {:noreply, start_event_surface_task(socket, event_id, surface)}
  end

  def handle_info({:event_detail_loaded, event_id, result}, socket) do
    {:noreply, finish_event_detail_load(socket, event_id, result)}
  end

  def handle_info({:event_surface_loaded, event_id, surface, result}, socket) do
    {:noreply, finish_event_surface_load(socket, event_id, surface, result)}
  end

  @impl true
  def handle_event("load_more_timeline", _params, socket) do
    {:noreply, load_more_timeline(socket)}
  end

  def handle_event("toggle_section", %{"section" => section}, socket) do
    {:noreply, toggle_section(socket, section)}
  end

  def handle_event("set_timeline_filter", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, :timeline_filter, normalize_timeline_filter(filter))}
  end

  def handle_event("show_event_detail", %{"event_id" => event_id}, socket) do
    socket =
      socket
      |> assign(:selected_event_id, event_id)
      |> expand_section(:event_detail)
      |> assign(:detail_state, %{initial_detail_state() | status: :loading, event_id: event_id})

    send(self(), {:load_event_detail, event_id})

    {:noreply, socket}
  end

  def handle_event("load_event_surface", %{"surface" => surface}, socket) do
    socket =
      case socket.assigns.detail_state do
        %{status: :ready, event_id: event_id} when is_binary(event_id) and surface in @surface_names ->
          detail_state =
            put_in(socket.assigns.detail_state, [:surfaces, surface], %{
              status: :loading,
              content: nil,
              error: nil
            })

          send(self(), {:load_event_surface, event_id, surface})
          assign(socket, :detail_state, detail_state)

        _ ->
          socket
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <%= case @run_state do %>
        <% {:ok, %{project: project, run: run}} -> %>
          <header class="hero-card">
            <div class="hero-grid">
              <div>
                <p class="eyebrow">Run deep view</p>
                <h1 class="hero-title"><%= run.issue_identifier || @issue_identifier %></h1>
                <p class="hero-copy">
                  Lightweight deep view for <%= project.project_name || project.project_id || @project_id %>.
                </p>
              </div>

              <div class="status-stack">
                <span class={state_badge_class(run.health || run.current_phase || run.linear_state)}>
                  <%= run.current_phase || "unknown" %>
                </span>
                <span class="muted"><%= Presenter.project_run_summary_title(run) %></span>
              </div>
            </div>
          </header>

          <section class="metric-grid">
            <article class="metric-card">
              <p class="metric-label">Attention</p>
              <p class="metric-value"><%= attention_count(run) %></p>
              <p class="metric-detail">from attention items</p>
            </article>
            <article class="metric-card">
              <p class="metric-label">Blocked by</p>
              <p class="metric-value"><%= blocked_by_count(run) %></p>
              <p class="metric-detail">current blockers</p>
            </article>
            <article class="metric-card">
              <p class="metric-label">Blocks</p>
              <p class="metric-value"><%= blocks_count(run) %></p>
              <p class="metric-detail">downstream items</p>
            </article>
          </section>

          <section class="section-card run-section" data-section="overview">
            <div class="section-header">
              <div>
                <h2 class="section-title">Overview</h2>
                <p class="section-copy">Top-level run status only. Timeline, context, and detail load independently.</p>
              </div>
              <button
                type="button"
                class="subtle-button section-toggle"
                aria-expanded={section_expanded?(@section_state, :overview)}
                phx-click="toggle_section"
                phx-value-section="overview"
              >
                <%= section_toggle_label(@section_state, :overview) %>
              </button>
            </div>

            <div class="session-stack run-section-body" hidden={!section_expanded?(@section_state, :overview)}>
              <p :for={{label, key} <- summary_fields()} class="mono">
                <strong><%= label %></strong>: <%= summary_value(run, key) %>
              </p>
            </div>
          </section>

          <section class="section-card run-section" data-section="action-needed">
            <div class="section-header">
              <div>
                <h2 class="section-title">Action Needed</h2>
                <p class="section-copy">Priority follow-up stays anchored to summary attention and dependencies only.</p>
              </div>
              <button
                type="button"
                class="subtle-button section-toggle"
                aria-expanded={section_expanded?(@section_state, :action_needed)}
                phx-click="toggle_section"
                phx-value-section="action_needed"
              >
                <%= section_toggle_label(@section_state, :action_needed) %>
              </button>
            </div>

            <div class="detail-stack run-section-body" hidden={!section_expanded?(@section_state, :action_needed)}>
              <div class="info-panel info-panel-primary">
                <p class="metric-label">Primary signal</p>
                <p class="info-panel-copy mono" data-role="action-needed-primary"><%= primary_attention_message(run) %></p>
              </div>

              <div class="info-panel">
                <p class="metric-label">Attention items</p>
                <%= if attention_items(run) == [] do %>
                  <p class="mono">No attention items.</p>
                <% else %>
                  <p :for={item <- attention_items(run)} class="mono"><%= item.message %></p>
                <% end %>
              </div>

              <div class="info-panel">
                <p class="metric-label">Blocked by</p>
                <%= if dependency_entries(run, :blocked_by) == [] do %>
                  <p class="mono">No dependencies.</p>
                <% else %>
                  <p :for={dependency <- dependency_entries(run, :blocked_by)} class="mono">
                    <a class="issue-link" href={dependency_href(dependency)}>
                      <%= dependency_label(dependency) %>
                    </a>
                  </p>
                <% end %>
              </div>

              <div class="info-panel">
                <p class="metric-label">Blocks</p>
                <%= if dependency_entries(run, :blocks) == [] do %>
                  <p class="mono">No dependencies.</p>
                <% else %>
                  <p :for={dependency <- dependency_entries(run, :blocks)} class="mono">
                    <a class="issue-link" href={dependency_href(dependency)}>
                      <%= dependency_label(dependency) %>
                    </a>
                  </p>
                <% end %>
              </div>
            </div>
          </section>

          <section class="section-card run-section" data-section="timeline">
            <div class="section-header">
              <div>
                <h2 class="section-title">Timeline</h2>
                <p class="section-copy">Filters only affect the currently loaded items.</p>
              </div>
              <button
                type="button"
                class="subtle-button section-toggle"
                aria-expanded={section_expanded?(@section_state, :timeline)}
                phx-click="toggle_section"
                phx-value-section="timeline"
              >
                <%= section_toggle_label(@section_state, :timeline) %>
              </button>
            </div>

            <div class="detail-stack run-section-body" hidden={!section_expanded?(@section_state, :timeline)}>
              <p :if={quiet_attention?(run)} class="mono">quiet attention</p>

              <div class="filter-chip-row">
                <button
                  :for={{filter, label} <- timeline_filter_options()}
                  type="button"
                  class={timeline_filter_button_class(@timeline_filter, filter)}
                  phx-click="set_timeline_filter"
                  phx-value-filter={filter}
                >
                  <%= label %>
                </button>
              </div>

              <%= case @timeline_state.status do %>
                <% :loading -> %>
                  <p class="empty-state">Loading timeline…</p>
                <% :error -> %>
                  <p class="empty-state"><%= timeline_error_text(@timeline_state.error) %></p>
                <% :ready -> %>
                  <div class="session-stack">
                    <article :for={item <- filtered_timeline_items(@timeline_state.items, @timeline_filter)} class="section-card timeline-item-card">
                      <div class="section-header">
                        <div>
                          <h3 class="section-title"><%= item.summary || item.event_id || "timeline event" %></h3>
                          <p class="section-copy">
                            <%= [item.timestamp, item.source, item.event_type] |> Enum.reject(&is_nil/1) |> Enum.join(" · ") %>
                          </p>
                        </div>

                        <button
                          type="button"
                          class="issue-link"
                          phx-click="show_event_detail"
                          phx-value-event_id={item.event_id}
                        >
                          Open detail
                        </button>
                      </div>

                      <div class="detail-stack">
                        <p :for={marker <- timeline_labels(item)} class="mono"><%= marker %></p>
                      </div>
                    </article>
                  </div>

                  <p :if={filtered_timeline_items(@timeline_state.items, @timeline_filter) == []} class="empty-state">
                    No timeline items match this filter.
                  </p>

                  <p :if={is_binary(@timeline_state.load_more_error)} class="mono">
                    <%= @timeline_state.load_more_error %>
                  </p>

                  <button
                    :if={is_binary(@timeline_state.next_cursor)}
                    type="button"
                    class="issue-link"
                    phx-click="load_more_timeline"
                  >
                    Load more
                  </button>
                <% _ -> %>
                  <p class="empty-state">Timeline unavailable</p>
              <% end %>
            </div>
          </section>

          <section class="section-card run-section" data-section="context">
            <div class="section-header">
              <div>
                <h2 class="section-title">Context</h2>
                <p class="section-copy">Independent, lightweight context summary for the current run generation.</p>
              </div>
              <button
                type="button"
                class="subtle-button section-toggle"
                aria-expanded={section_expanded?(@section_state, :context)}
                phx-click="toggle_section"
                phx-value-section="context"
              >
                <%= section_toggle_label(@section_state, :context) %>
              </button>
            </div>

            <div class="detail-stack run-section-body" hidden={!section_expanded?(@section_state, :context)}>
              <%= case @context_state.status do %>
                <% :loading -> %>
                  <p class="empty-state">Loading context…</p>
                <% :error -> %>
                  <p class="empty-state"><%= context_error_text(@context_state.error) %></p>
                <% :ready -> %>
                  <div class="detail-stack">
                    <h3 class="section-title">Thread &amp; Turn</h3>
                    <p class="mono">session: <%= @context_state.context.anchor.session_id || "n/a" %></p>
                    <p class="mono">thread: <%= @context_state.context.anchor.thread_id || "n/a" %></p>
                    <p class="mono">turn: <%= @context_state.context.anchor.turn_id || "n/a" %></p>
                    <p class="mono">turn_count: <%= summary_value(@context_state.context.anchor, :turn_count) %></p>
                  </div>

                  <div class="detail-stack">
                    <h3 class="section-title">Recent interaction signals</h3>
                    <div :for={item <- @context_state.context.conversation.items} class="detail-stack">
                      <p class="mono"><%= item.label %>: <%= item.text %></p>
                      <button
                        type="button"
                        class="issue-link"
                        phx-click="show_event_detail"
                        phx-value-event_id={item.event_id}
                      >
                        Open detail: <%= item.event_id %>
                      </button>
                    </div>
                    <p :if={@context_state.context.conversation.items == []} class="mono">none observed</p>
                  </div>

                  <div class="detail-stack">
                    <h3 class="section-title">Continuation &amp; Retry</h3>
                    <p class="mono"><%= @context_state.context.continuation.label || "none observed" %></p>
                    <p class="mono">event_id: <%= @context_state.context.continuation.event_id || "n/a" %></p>
                    <button
                      :if={is_binary(@context_state.context.continuation.event_id)}
                      type="button"
                      class="issue-link"
                      phx-click="show_event_detail"
                      phx-value-event_id={@context_state.context.continuation.event_id}
                    >
                      Open detail: <%= @context_state.context.continuation.event_id %>
                    </button>
                  </div>

                  <div class="detail-stack">
                    <h3 class="section-title">Issue Refresh</h3>
                    <p class="mono"><%= @context_state.context.issue_refresh.status_text || "none observed" %></p>
                    <p :for={change <- @context_state.context.issue_refresh.observed_changes} class="mono"><%= change %></p>
                    <p :for={note <- @context_state.context.issue_refresh.notes} class="mono"><%= note %></p>
                    <p :if={@context_state.context.issue_refresh.observed_changes == [] and @context_state.context.issue_refresh.notes == []} class="mono">none observed</p>
                  </div>

                  <div class="detail-stack">
                    <h3 class="section-title">Tools &amp; Shell</h3>
                    <div :for={item <- @context_state.context.tools.items} class="detail-stack">
                      <p class="mono"><%= item.summary %></p>
                      <button
                        type="button"
                        class="issue-link"
                        phx-click="show_event_detail"
                        phx-value-event_id={item.event_id}
                      >
                        Open detail: <%= item.event_id %>
                      </button>
                    </div>
                    <div :for={item <- @context_state.context.shell.items} class="detail-stack">
                      <p class="mono"><%= item.text %></p>
                      <button
                        type="button"
                        class="issue-link"
                        phx-click="show_event_detail"
                        phx-value-event_id={item.event_id}
                      >
                        Open detail: <%= item.event_id %>
                      </button>
                    </div>
                    <p :if={@context_state.context.tools.items == [] and @context_state.context.shell.items == []} class="mono">none observed</p>
                  </div>

                  <div class="detail-stack">
                    <h3 class="section-title">Sub-agent</h3>
                    <p :for={item <- @context_state.context.subagents.items} class="mono"><%= item.text %></p>
                    <p :if={@context_state.context.subagents.items == []} class="mono"><%= humanize_context_status(@context_state.context.subagents.status) %></p>
                  </div>
                <% _ -> %>
                  <p class="empty-state">Context unavailable</p>
              <% end %>
            </div>
          </section>

          <section class="section-card run-section" data-section="event-detail">
            <div class="section-header">
              <div>
                <h2 class="section-title">Event Detail</h2>
                <p class="section-copy">Single-event metadata first. Heavy surfaces stay lazy.</p>
              </div>
              <button
                type="button"
                class="subtle-button section-toggle"
                aria-expanded={section_expanded?(@section_state, :event_detail)}
                phx-click="toggle_section"
                phx-value-section="event_detail"
              >
                <%= section_toggle_label(@section_state, :event_detail) %>
              </button>
            </div>

            <div class="detail-stack run-section-body" hidden={!section_expanded?(@section_state, :event_detail)}>
              <%= case @detail_state.status do %>
                <% :idle -> %>
                  <p class="empty-state">Choose an event to inspect details.</p>
                <% :loading -> %>
                  <p class="empty-state">Loading event detail…</p>
                <% :error -> %>
                  <p class="empty-state"><%= detail_error_text(@detail_state.error) %></p>
                <% :ready -> %>
                  <div class="detail-stack">
                    <p class="mono">event_id: <%= @detail_state.detail.event.event_id || "n/a" %></p>
                    <p class="mono">timestamp: <%= @detail_state.detail.event.timestamp || "n/a" %></p>
                    <p class="mono">source: <%= @detail_state.detail.event.source || "n/a" %></p>
                    <p class="mono">event_type: <%= @detail_state.detail.event.event_type || "n/a" %></p>
                    <p class="mono">event_group: <%= @detail_state.detail.event.event_group || "n/a" %></p>
                    <p class="mono">summary: <%= @detail_state.detail.event.summary || "n/a" %></p>
                    <p class="mono">session: <%= @detail_state.detail.context.session_id || "n/a" %></p>
                    <p class="mono">thread: <%= @detail_state.detail.context.thread_id || "n/a" %></p>
                    <p class="mono">turn: <%= @detail_state.detail.context.turn_id || "n/a" %></p>
                  </div>

                  <div class="detail-stack">
                    <p class="mono">tool summary: <%= detail_summary_value(@detail_state.detail.summaries.tool_call) %></p>
                    <p class="mono">payload summary: <%= detail_summary_value(@detail_state.detail.summaries.payload) %></p>
                    <p class="mono">prompt summary: <%= detail_summary_value(@detail_state.detail.summaries.prompt) %></p>
                    <p class="mono">shell summary: <%= detail_summary_value(@detail_state.detail.summaries.shell) %></p>
                  </div>

                  <div class="detail-stack">
                    <button :for={surface <- @surface_names} type="button" class="issue-link" phx-click="load_event_surface" phx-value-surface={surface}>
                      Load <%= surface %>
                    </button>
                  </div>

                  <%= for surface <- @surface_names do %>
                    <% preview = Map.fetch!(@detail_state.detail.surfaces, String.to_atom(surface)) %>
                    <% surface_state = Map.fetch!(@detail_state.surfaces, surface) %>
                    <article class="section-card">
                      <div class="section-header">
                        <div>
                          <h3 class="section-title"><%= surface %></h3>
                          <p class="section-copy">
                            <%= surface_preview_text(preview) %>
                          </p>
                        </div>
                      </div>

                      <%= case surface_state.status do %>
                        <% :idle -> %>
                          <p class="empty-state">Surface body stays unloaded.</p>
                        <% :loading -> %>
                          <p class="empty-state">Loading <%= surface %>…</p>
                        <% :error -> %>
                          <p class="empty-state"><%= surface_error_text(surface_state.error) %></p>
                        <% :ready -> %>
                          <pre class="mono"><%= surface_state.content %></pre>
                      <% end %>
                    </article>
                  <% end %>
              <% end %>
            </div>
          </section>
        <% {:error, :project_not_found} -> %>
          <section class="error-card">
            <h2 class="error-title">Project unavailable</h2>
            <p class="error-copy">
              No project matched <span class="mono"><%= @project_id %></span>.
            </p>
          </section>
        <% {:error, :run_not_found} -> %>
          <section class="error-card">
            <h2 class="error-title">Run unavailable</h2>
            <p class="error-copy">
              No lightweight run summary matched <span class="mono"><%= @issue_identifier %></span>.
            </p>
          </section>
      <% end %>
    </section>
    """
  end

  defp load_run(socket) do
    case Presenter.project_run_summary_payload(
           socket.assigns.project_id,
           socket.assigns.issue_identifier,
           HttpServer.project_registry()
         ) do
      {:ok, payload} -> assign(socket, :run_state, {:ok, payload})
      {:error, reason} -> assign(socket, :run_state, {:error, reason})
    end
  end

  defp load_recent_timeline(socket) do
    socket
    |> assign(:timeline_state, %{initial_timeline_state() | status: :loading})
    |> case do
      %{assigns: %{run_state: {:ok, _payload}}} = ready_socket ->
        case fetch_timeline(ready_socket.assigns.project_id, ready_socket.assigns.issue_identifier, nil) do
          {:ok, timeline} ->
            assign(ready_socket, :timeline_state, %{
              status: :ready,
              items: timeline.items,
              next_cursor: timeline.next_cursor,
              error: nil,
              load_more_error: nil
            })

          {:error, reason} ->
            assign(ready_socket, :timeline_state, %{
              status: :error,
              items: [],
              next_cursor: nil,
              error: reason,
              load_more_error: nil
            })
        end

      other_socket ->
        other_socket
    end
  end

  defp load_context_summary(socket) do
    socket
    |> assign(:context_state, %{initial_context_state() | status: :loading})
    |> case do
      %{assigns: %{run_state: {:ok, _payload}}} = ready_socket ->
        case fetch_context_summary(ready_socket.assigns.project_id, ready_socket.assigns.issue_identifier) do
          {:ok, context} ->
            assign(ready_socket, :context_state, %{status: :ready, context: context, error: nil})

          {:error, reason} ->
            assign(ready_socket, :context_state, %{status: :error, context: nil, error: reason})
        end

      other_socket ->
        other_socket
    end
  end

  defp load_more_timeline(%{assigns: %{timeline_state: %{status: :ready, next_cursor: cursor}}} = socket)
       when is_binary(cursor) do
    case fetch_timeline(socket.assigns.project_id, socket.assigns.issue_identifier, cursor) do
      {:ok, timeline} ->
        assign(socket, :timeline_state, %{
          socket.assigns.timeline_state
          | items: socket.assigns.timeline_state.items ++ timeline.items,
            next_cursor: timeline.next_cursor,
            load_more_error: nil
        })

      {:error, :invalid_cursor} ->
        assign(socket, :timeline_state, %{
          socket.assigns.timeline_state
          | next_cursor: nil,
            load_more_error: "Timeline load more failed"
        })

      {:error, _reason} ->
        assign(socket, :timeline_state, %{
          socket.assigns.timeline_state
          | next_cursor: nil,
            load_more_error: "Timeline load more failed"
        })
    end
  end

  defp load_more_timeline(socket), do: socket

  defp toggle_section(socket, section) when is_binary(section) do
    key = normalize_section_key(section)

    case Map.fetch(socket.assigns.section_state, key) do
      {:ok, expanded?} -> assign(socket, :section_state, Map.put(socket.assigns.section_state, key, !expanded?))
      :error -> socket
    end
  end

  defp expand_section(socket, key) when is_atom(key) do
    assign(socket, :section_state, Map.put(socket.assigns.section_state, key, true))
  end

  defp start_event_detail_task(socket, event_id) when is_binary(event_id) do
    parent = self()
    project_id = socket.assigns.project_id
    issue_identifier = socket.assigns.issue_identifier

    Task.start(fn ->
      send(parent, {:event_detail_loaded, event_id, fetch_event_detail(project_id, issue_identifier, event_id)})
    end)

    socket
  end

  defp start_event_detail_task(socket, _event_id), do: socket

  defp finish_event_detail_load(%{assigns: %{selected_event_id: event_id}} = socket, event_id, result)
       when is_binary(event_id) do
    case result do
      {:ok, detail} ->
        assign(socket, :detail_state, %{
          status: :ready,
          event_id: event_id,
          detail: detail,
          error: nil,
          surfaces: initial_surface_states()
        })

      {:error, reason} ->
        assign(socket, :detail_state, %{
          initial_detail_state()
          | status: :error,
            event_id: event_id,
            error: reason
        })
    end
  end

  defp finish_event_detail_load(socket, _event_id, _result), do: socket

  defp start_event_surface_task(%{assigns: %{detail_state: %{status: :ready, event_id: selected_event_id}}} = socket, event_id, surface)
       when surface in @surface_names and is_binary(event_id) and event_id == selected_event_id do
    parent = self()
    project_id = socket.assigns.project_id
    issue_identifier = socket.assigns.issue_identifier

    Task.start(fn ->
      send(
        parent,
        {:event_surface_loaded, event_id, surface, fetch_event_surface(project_id, issue_identifier, event_id, surface)}
      )
    end)

    socket
  end

  defp start_event_surface_task(socket, _event_id, _surface), do: socket

  defp finish_event_surface_load(
         %{assigns: %{detail_state: %{status: :ready, event_id: selected_event_id}}} = socket,
         event_id,
         surface,
         result
       )
       when surface in @surface_names and is_binary(event_id) and event_id == selected_event_id do
    case result do
      {:ok, payload} ->
        updated_detail_state =
          put_in(socket.assigns.detail_state, [:surfaces, surface], %{
            status: :ready,
            content: payload.content,
            error: nil
          })

        assign(socket, :detail_state, updated_detail_state)

      {:error, reason} ->
        updated_detail_state =
          put_in(socket.assigns.detail_state, [:surfaces, surface], %{
            status: :error,
            content: nil,
            error: reason
          })

        assign(socket, :detail_state, updated_detail_state)
    end
  end

  defp finish_event_surface_load(socket, _event_id, _surface, _result), do: socket

  defp fetch_timeline(project_id, issue_identifier, cursor) do
    if Endpoint.config(:runtime_mode) == :control_plane do
      ObservabilityApiController.project_run_timeline_payload(project_id, issue_identifier, cursor)
    else
      orchestrator = Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
      timeout = Endpoint.config(:snapshot_timeout_ms) || 15_000

      case Orchestrator.run_timeline(orchestrator, issue_identifier, cursor: cursor, timeout: timeout) do
        {:ok, payload} -> {:ok, Presenter.run_timeline_payload(payload)}
        {:error, reason} -> {:error, reason}
        :timeout -> {:error, :timeline_unavailable}
        :unavailable -> {:error, :timeline_unavailable}
      end
    end
  end

  defp fetch_event_detail(project_id, issue_identifier, event_id) do
    if Endpoint.config(:runtime_mode) == :control_plane do
      ObservabilityApiController.project_run_event_detail_payload(project_id, issue_identifier, event_id)
    else
      orchestrator = Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
      timeout = Endpoint.config(:snapshot_timeout_ms) || 15_000

      case Orchestrator.run_event_detail(orchestrator, issue_identifier, event_id, timeout: timeout) do
        {:ok, payload} -> {:ok, Presenter.run_event_detail_payload(payload)}
        {:error, reason} -> {:error, reason}
        :timeout -> {:error, :event_detail_unavailable}
        :unavailable -> {:error, :event_detail_unavailable}
      end
    end
  end

  defp fetch_event_surface(project_id, issue_identifier, event_id, surface) do
    if Endpoint.config(:runtime_mode) == :control_plane do
      ObservabilityApiController.project_run_event_surface_payload(project_id, issue_identifier, event_id, surface)
    else
      orchestrator = Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
      timeout = Endpoint.config(:snapshot_timeout_ms) || 15_000

      case Orchestrator.run_event_surface(orchestrator, issue_identifier, event_id, surface, timeout: timeout) do
        {:ok, payload} -> {:ok, Presenter.run_event_surface_payload(payload)}
        {:error, reason} -> {:error, reason}
        :timeout -> {:error, :event_surface_unavailable}
        :unavailable -> {:error, :event_surface_unavailable}
      end
    end
  end

  defp fetch_context_summary(project_id, issue_identifier) do
    if Endpoint.config(:runtime_mode) == :control_plane do
      ObservabilityApiController.project_run_context_payload(project_id, issue_identifier)
    else
      orchestrator = Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
      timeout = Endpoint.config(:snapshot_timeout_ms) || 15_000

      case Orchestrator.run_context_summary(orchestrator, issue_identifier, timeout: timeout) do
        {:ok, payload} -> {:ok, Presenter.run_context_payload(payload)}
        {:error, reason} -> {:error, reason}
        :timeout -> {:error, :context_unavailable}
        :unavailable -> {:error, :context_unavailable}
      end
    end
  end

  defp initial_timeline_state do
    %{
      status: :idle,
      items: [],
      next_cursor: nil,
      error: nil,
      load_more_error: nil
    }
  end

  defp initial_context_state do
    %{
      status: :idle,
      context: nil,
      error: nil
    }
  end

  defp initial_detail_state do
    %{
      status: :idle,
      event_id: nil,
      detail: nil,
      error: nil,
      surfaces: initial_surface_states()
    }
  end

  defp initial_surface_states do
    Enum.into(@surface_names, %{}, fn surface ->
      {surface, %{status: :idle, content: nil, error: nil}}
    end)
  end

  defp initial_section_state do
    %{
      overview: true,
      action_needed: true,
      timeline: true,
      context: false,
      event_detail: false
    }
  end

  defp summary_loaded?(socket) do
    match?({:ok, _payload}, socket.assigns.run_state)
  end

  defp quiet_attention?(run) do
    run
    |> Map.get(:health)
    |> to_string()
    |> String.contains?("stalled")
  end

  defp timeline_error_text(_reason), do: "Timeline unavailable"
  defp context_error_text(_reason), do: "Context unavailable"
  defp detail_error_text(_reason), do: "Event detail unavailable"
  defp surface_error_text(:surface_not_available), do: "Surface unavailable for this event"
  defp surface_error_text(:invalid_surface), do: "Surface unavailable for this event"
  defp surface_error_text(_reason), do: "Surface unavailable for this event"

  defp timeline_labels(item) do
    base =
      item.status_markers
      |> List.wrap()
      |> Enum.map(&String.replace(&1, "_", " "))

    base
    |> maybe_add_label(item.event_type == "session_started", "session started")
    |> maybe_add_label(item.event_type == "turn_completed", "turn completed")
    |> maybe_add_label(item.event_type == "run_result", "run result")
    |> maybe_add_label(item.source == "orchestrator" and item.event_type == "retry_scheduled", "retry")
  end

  defp maybe_add_label(labels, true, label) do
    if label in labels, do: labels, else: labels ++ [label]
  end

  defp maybe_add_label(labels, false, _label), do: labels

  defp summary_fields, do: @summary_fields

  defp timeline_filter_options do
    [
      {"all", "All"},
      {"attention", "Attention"},
      {"retry", "Retry"},
      {"session", "Session"},
      {"turn_completed", "Turn completed"},
      {"run_result", "Run result"}
    ]
  end

  defp normalize_timeline_filter(filter) when filter in ~w(all attention retry session turn_completed run_result),
    do: filter

  defp normalize_timeline_filter(_filter), do: "all"

  defp filtered_timeline_items(items, filter) do
    normalized_filter = normalize_timeline_filter(filter)
    Enum.filter(List.wrap(items), &timeline_item_matches_filter?(&1, normalized_filter))
  end

  defp timeline_item_matches_filter?(_item, "all"), do: true

  defp timeline_item_matches_filter?(item, "attention") do
    "attention" in List.wrap(item.status_markers)
  end

  defp timeline_item_matches_filter?(item, "retry") do
    item.source == "orchestrator" and item.event_type == "retry_scheduled"
  end

  defp timeline_item_matches_filter?(item, "session"), do: item.event_type == "session_started"
  defp timeline_item_matches_filter?(item, "turn_completed"), do: item.event_type == "turn_completed"
  defp timeline_item_matches_filter?(item, "run_result"), do: item.event_type == "run_result"

  defp timeline_filter_button_class(active_filter, filter) do
    base = "subtle-button filter-chip"
    if active_filter == filter, do: base <> " filter-chip-active", else: base
  end

  defp normalize_section_key(section) do
    section
    |> String.replace("-", "_")
    |> String.to_existing_atom()
  rescue
    ArgumentError -> :unknown
  end

  defp section_expanded?(section_state, key) do
    Map.get(section_state, key, false)
  end

  defp section_toggle_label(section_state, key) do
    if section_expanded?(section_state, key), do: "Collapse", else: "Expand"
  end

  defp dependency_entries(run, key) do
    run
    |> Map.get(key, [])
    |> List.wrap()
    |> Enum.filter(&dependency_displayable?/1)
  end

  defp dependency_label(dependency) when is_map(dependency) do
    case [
           Map.get(dependency, :issue_identifier),
           Map.get(dependency, :title),
           Map.get(dependency, :linear_state)
         ]
         |> Enum.filter(&(is_binary(&1) and &1 != ""))
         |> Enum.join(" · ") do
      "" -> "Related issue"
      label -> label
    end
  end

  defp dependency_href(dependency) when is_map(dependency) do
    case Map.get(dependency, :url) do
      url when is_binary(url) and url != "" -> url
      _ -> "#"
    end
  end

  defp dependency_displayable?(dependency) when is_map(dependency) do
    Enum.any?([
      present_string?(Map.get(dependency, :issue_identifier)),
      present_string?(Map.get(dependency, :title)),
      present_string?(Map.get(dependency, :linear_state)),
      present_string?(Map.get(dependency, :url))
    ])
  end

  defp dependency_displayable?(_dependency), do: false

  defp present_string?(value) when is_binary(value), do: value != ""
  defp present_string?(_value), do: false

  defp attention_items(run) do
    run
    |> Map.get(:attention_items, [])
    |> List.wrap()
    |> Enum.filter(fn item ->
      is_map(item) and is_binary(Map.get(item, :message)) and Map.get(item, :message) != ""
    end)
  end

  defp primary_attention_message(run) do
    case attention_items(run) do
      [%{message: message} | _rest] -> message
      _ -> "No action needed."
    end
  end

  defp attention_count(run), do: length(attention_items(run))
  defp blocked_by_count(run), do: length(dependency_entries(run, :blocked_by))
  defp blocks_count(run), do: length(dependency_entries(run, :blocks))

  defp detail_summary_value(nil), do: "n/a"
  defp detail_summary_value(""), do: "n/a"
  defp detail_summary_value(value), do: value

  defp surface_preview_text(preview) do
    cond do
      preview.available != true -> "Preview unavailable"
      is_binary(preview.preview) and preview.truncated -> "Preview loaded (truncated)"
      is_binary(preview.preview) -> "Preview loaded"
      true -> "Preview unavailable"
    end
  end

  defp summary_value(run, key) do
    case Map.get(run, key) do
      value when is_integer(value) and key == :run_duration_seconds -> "#{value}s"
      value when is_integer(value) -> Integer.to_string(value)
      "" -> "n/a"
      nil -> "n/a"
      value -> value
    end
  end

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

  defp humanize_context_status("none_observed"), do: "none observed"
  defp humanize_context_status("unavailable"), do: "unavailable"
  defp humanize_context_status("ready"), do: "ready"
  defp humanize_context_status(_status), do: "unavailable"
end
