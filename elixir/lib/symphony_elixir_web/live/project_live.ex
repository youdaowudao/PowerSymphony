defmodule SymphonyElixirWeb.ProjectLive do
  @moduledoc """
  Lightweight project detail page for control-plane project summaries.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.HttpServer
  alias SymphonyElixirWeb.Presenter

  @impl true
  def mount(%{"project_id" => project_id}, _session, socket) do
    socket =
      socket
      |> assign(:project_id, project_id)
      |> assign(:page_title, "Project details")
      |> load_project()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <%= case @project_state do %>
        <% {:ok, project} -> %>
          <header class="hero-card">
            <div class="hero-grid">
              <div>
                <p class="eyebrow">Project detail</p>
                <h1 class="hero-title"><%= project.project_name || project.project_id || @project_id %></h1>
                <p class="hero-copy">
                  Lightweight run summary view for project <span class="mono"><%= @project_id %></span>.
                </p>
              </div>

              <div class="status-stack">
                <span class={state_badge_class(project.worker_status)}>
                  <%= project.worker_status %>
                </span>
                <span class="muted"><%= project.validation_result %></span>
              </div>
            </div>
          </header>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Project summary</h2>
                <p class="section-copy">Static project metadata and lightweight runtime state.</p>
              </div>
            </div>

            <div class="detail-stack">
              <p class="mono"><%= "project_id: #{blank_to_na(project.project_id)}" %></p>
              <p class="mono"><%= "enabled: #{project.enabled}" %></p>
              <p class="mono"><%= "worker status: #{blank_to_na(project.worker_status)}" %></p>
              <p class="mono"><%= "worker port: #{blank_to_na(project.worker_port)}" %></p>
              <p class="mono"><%= "last seen: #{blank_to_na(project.last_seen_at)}" %></p>
              <p class="mono"><%= "last error: #{blank_to_na(Presenter.project_runtime_or_validation_error(project))}" %></p>
            </div>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Run summaries</h2>
                <p class="section-copy">Lightweight list only. Deep run data stays in the run page.</p>
              </div>
            </div>

            <%= if project.run_summaries == [] do %>
              <p class="empty-state">No run summaries available.</p>
            <% else %>
              <div class="session-stack">
                <article :for={summary <- project.run_summaries} class="section-card">
                  <div class="section-header">
                    <div>
                      <h3 class="section-title"><%= summary.issue_identifier || "n/a" %></h3>
                      <p class="section-copy"><%= Presenter.project_run_summary_title(summary) %></p>
                    </div>

                    <a class="issue-link" href={run_path(@project_id, summary.issue_identifier)}>Open run</a>
                  </div>

                  <div class="detail-stack">
                    <p>
                      <span class={state_badge_class(summary.current_phase || summary.linear_state || summary.health)}>
                        <%= summary.current_phase || "unknown" %>
                      </span>
                      <span class="muted event-meta"><%= Presenter.project_run_summary_health_meta(summary) %></span>
                    </p>
                    <p class="mono"><%= blank_to_na(summary.current_action) %></p>
                    <p class="muted event-meta"><%= Presenter.project_run_summary_ids(summary) %></p>
                    <p class="muted event-meta"><%= Presenter.project_run_summary_runtime(summary) %></p>
                    <p :if={is_binary(summary.last_error) and summary.last_error != ""} class="mono">
                      <%= summary.last_error %>
                    </p>
                  </div>
                </article>
              </div>
            <% end %>
          </section>
        <% {:error, :project_not_found} -> %>
          <section class="error-card">
            <h2 class="error-title">Project unavailable</h2>
            <p class="error-copy">
              No lightweight project summary matched <span class="mono"><%= @project_id %></span>.
            </p>
          </section>
      <% end %>
    </section>
    """
  end

  defp load_project(socket) do
    case Presenter.project_summary_payload(socket.assigns.project_id, HttpServer.project_registry()) do
      {:ok, %{project: project}} -> assign(socket, :project_state, {:ok, project})
      {:error, :project_not_found} -> assign(socket, :project_state, {:error, :project_not_found})
    end
  end

  defp run_path(project_id, issue_identifier) do
    encoded_project_id = URI.encode(to_string(project_id), &URI.char_unreserved?/1)
    encoded_issue_identifier = URI.encode(to_string(issue_identifier), &URI.char_unreserved?/1)

    "/projects/#{encoded_project_id}/runs/#{encoded_issue_identifier}"
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

  defp blank_to_na(""), do: "n/a"
  defp blank_to_na(nil), do: "n/a"
  defp blank_to_na(value), do: value
end
