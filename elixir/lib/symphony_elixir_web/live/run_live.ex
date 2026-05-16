defmodule SymphonyElixirWeb.RunLive do
  @moduledoc """
  Run deep-view with lightweight summary plus lazily loaded timeline browsing.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.HttpServer
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixirWeb.{Endpoint, ObservabilityApiController, Presenter}

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
      |> assign(:selected_event, nil)
      |> assign(:timeline_state, initial_timeline_state())
      |> load_run()

    if connected?(socket) and summary_loaded?(socket) do
      send(self(), :load_timeline)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:load_timeline, socket) do
    {:noreply, load_recent_timeline(socket)}
  end

  @impl true
  def handle_event("load_more_timeline", _params, socket) do
    {:noreply, load_more_timeline(socket)}
  end

  def handle_event("show_event_detail", %{"event_id" => event_id}, socket) do
    selected_event =
      socket.assigns.timeline_state.items
      |> Enum.find(fn item -> item.event_id == event_id end)

    {:noreply, assign(socket, :selected_event, selected_event)}
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

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Summary</h2>
                <p class="section-copy">Top-level run status only. Timeline loads independently.</p>
              </div>
            </div>

            <div class="session-stack">
              <p :for={{label, key} <- summary_fields()} class="mono">
                <strong><%= label %></strong>: <%= summary_value(run, key) %>
              </p>
            </div>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Timeline</h2>
                <p class="section-copy">Default recent window with incremental history loading.</p>
              </div>
            </div>

            <p :if={quiet_attention?(run)} class="mono">quiet attention</p>

            <%= case @timeline_state.status do %>
              <% :loading -> %>
                <p class="empty-state">Loading timeline…</p>
              <% :error -> %>
                <p class="empty-state"><%= timeline_error_text(@timeline_state.error) %></p>
              <% :ready -> %>
                <div class="session-stack">
                  <article :for={item <- @timeline_state.items} class="section-card">
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
                        Open detail placeholder
                      </button>
                    </div>

                    <div class="detail-stack">
                      <p :for={marker <- timeline_labels(item)} class="mono"><%= marker %></p>
                    </div>
                  </article>
                </div>

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
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Event detail</h2>
                <p class="section-copy">M4-3 entry point only. Event body stays unloaded.</p>
              </div>
            </div>

            <%= if @selected_event do %>
              <div class="detail-stack">
                <p class="mono">Detail placeholder</p>
                <p class="mono"><%= @selected_event.event_id %></p>
                <p class="mono"><%= @selected_event.summary %></p>
              </div>
            <% else %>
              <p class="empty-state">Entry point only. Event body stays unloaded by default.</p>
            <% end %>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Context surfaces</h2>
                <p class="section-copy">Thread, turn, conversation, tools, and sub-agent context placeholders.</p>
              </div>
            </div>

            <div class="detail-stack">
              <p class="mono">Thread</p>
              <p class="mono">Turn</p>
              <p class="mono">Conversation</p>
              <p class="mono">Tools</p>
              <p class="mono">Sub-agent context</p>
            </div>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Dependencies & attention</h2>
                <p class="section-copy">Reserved surface for downstream dependency and attention panels.</p>
              </div>
            </div>

            <div class="detail-stack">
              <p class="mono">Dependencies</p>
              <p class="mono">Attention</p>
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

  defp initial_timeline_state do
    %{
      status: :idle,
      items: [],
      next_cursor: nil,
      error: nil,
      load_more_error: nil
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
end
