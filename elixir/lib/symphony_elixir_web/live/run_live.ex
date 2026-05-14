defmodule SymphonyElixirWeb.RunLive do
  @moduledoc """
  Lightweight run deep-view skeleton backed only by existing run summary fields.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.HttpServer
  alias SymphonyElixirWeb.Presenter

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
      |> load_run()

    {:ok, socket}
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
                  Lightweight deep view skeleton for <%= project.project_name || project.project_id || @project_id %>.
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
                <p class="section-copy">Top-level run status only. No heavy data is loaded on first open.</p>
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
                <p class="section-copy">Not loaded by default.</p>
              </div>
            </div>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Event detail</h2>
                <p class="section-copy">Entry point only. Event body stays unloaded by default.</p>
              </div>
            </div>
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
