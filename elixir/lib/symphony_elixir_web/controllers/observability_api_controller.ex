defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{HttpServer, ProjectProcessManager}
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    if control_plane_mode?() do
      control_plane_not_available(conn)
    else
      json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
    end
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    if control_plane_mode?() do
      control_plane_not_available(conn)
    else
      case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
        {:ok, payload} ->
          json(conn, payload)

        {:error, :issue_not_found} ->
          error_response(conn, 404, "issue_not_found", "Issue not found")
      end
    end
  end

  @spec projects(Conn.t(), map()) :: Conn.t()
  def projects(conn, _params) do
    json(conn, Presenter.projects_payload(project_registry()))
  end

  @spec project_summary(Conn.t(), map()) :: Conn.t()
  def project_summary(conn, %{"project_id" => project_id}) do
    case Presenter.project_summary_payload(project_id, project_registry()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :project_not_found} ->
        error_response(conn, 404, "project_not_found", "Project not found")
    end
  end

  @spec start_project(Conn.t(), map()) :: Conn.t()
  def start_project(conn, %{"project_id" => project_id}) do
    control_plane_project_action(conn, project_id, &ProjectProcessManager.start_project/1)
  end

  @spec stop_project(Conn.t(), map()) :: Conn.t()
  def stop_project(conn, %{"project_id" => project_id}) do
    control_plane_project_action(conn, project_id, &ProjectProcessManager.stop_project/1)
  end

  @spec restart_project(Conn.t(), map()) :: Conn.t()
  def restart_project(conn, %{"project_id" => project_id}) do
    control_plane_project_action(conn, project_id, &ProjectProcessManager.restart_project/1)
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    if control_plane_mode?() do
      control_plane_not_available(conn)
    else
      case Presenter.refresh_payload(orchestrator()) do
        {:ok, payload} ->
          conn
          |> put_status(202)
          |> json(payload)

        {:error, :unavailable} ->
          error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
      end
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp control_plane_not_available(conn) do
    error_response(
      conn,
      404,
      "not_available_in_control_plane",
      "Route not available in control-plane mode"
    )
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

  defp control_plane_mode? do
    Endpoint.config(:runtime_mode) == :control_plane
  end

  defp project_action(conn, project_id, action) do
    case action.(project_id) do
      {:ok, _runtime_state} ->
        case Presenter.project_summary_payload(project_id, project_registry()) do
          {:ok, payload} ->
            conn
            |> put_status(202)
            |> json(payload)

          {:error, :project_not_found} ->
            error_response(conn, 404, "project_not_found", "Project not found")
        end

      {:error, :not_found} ->
        error_response(conn, 404, "project_not_found", "Project not found")

      {:error, reason}
      when reason in [:config_invalid, :disabled, :already_running, :not_running, :start_failed] ->
        error_response(conn, 409, Atom.to_string(reason), "Project action is not allowed")
    end
  end

  defp control_plane_project_action(conn, project_id, action) do
    if control_plane_mode?() do
      project_action(conn, project_id, action)
    else
      control_plane_not_available(conn)
    end
  end
end
