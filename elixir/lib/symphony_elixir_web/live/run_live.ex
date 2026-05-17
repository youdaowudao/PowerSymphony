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
      |> assign(:timeline_state, initial_timeline_state())
      |> assign(:detail_state, initial_detail_state())
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

  def handle_event("show_event_detail", %{"event_id" => event_id}, socket) do
    socket =
      socket
      |> assign(:selected_event_id, event_id)
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
                        Open detail
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
                <p class="section-copy">Single-event metadata first. Heavy surfaces stay lazy.</p>
              </div>
            </div>

            <%= case @detail_state.status do %>
              <% :idle -> %>
                <p class="empty-state">Entry point only. Event body stays unloaded by default.</p>
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

  defp initial_timeline_state do
    %{
      status: :idle,
      items: [],
      next_cursor: nil,
      error: nil,
      load_more_error: nil
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
end
