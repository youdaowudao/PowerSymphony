defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{HttpServer, ProjectProcessManager}
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec project_m3_precheck_payload(String.t()) ::
          {:ok, map()} | {:error, :project_not_found | term()}
  def project_m3_precheck_payload(project_id) when is_binary(project_id) do
    with {:ok, body} <- project_worker_request(project_id, "/api/v1/m3_precheck") do
      {:ok, Presenter.m3_precheck_payload(body)}
    end
  end

  @spec project_run_timeline_payload(String.t(), String.t(), String.t() | nil) ::
          {:ok, map()}
          | {:error,
             :project_not_found
             | :run_not_found
             | :invalid_cursor
             | :duplicate_run
             | :timeline_unavailable}
  def project_run_timeline_payload(project_id, issue_identifier, cursor \\ nil)
      when is_binary(project_id) and is_binary(issue_identifier) do
    with {:ok, _project_payload} <-
           Presenter.project_summary_payload(project_id, project_registry()),
         {:ok, body} <-
           project_worker_request(
             project_id,
             timeline_path(issue_identifier, cursor)
           ) do
      {:ok, Presenter.run_timeline_payload(body)}
    else
      {:error, :project_not_found} ->
        {:error, :project_not_found}

      {:error, :run_not_found} ->
        {:error, :timeline_unavailable}

      {:error, {:worker_status, 400, %{"error" => %{"code" => "invalid_cursor"}}}} ->
        {:error, :invalid_cursor}

      {:error, {:worker_status, 404, %{"error" => %{"code" => "run_not_found"}}}} ->
        {:error, :run_not_found}

      {:error, {:worker_status, 409, %{"error" => %{"code" => "duplicate_run"}}}} ->
        {:error, :duplicate_run}

      {:error, {:worker_status, 503, %{"error" => %{"code" => "timeline_unavailable"}}}} ->
        {:error, :timeline_unavailable}

      {:error, {:worker_status, _status, _body}} ->
        {:error, :timeline_unavailable}

      {:error, _reason} ->
        {:error, :timeline_unavailable}
    end
  end

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

  @spec run_timeline(Conn.t(), map()) :: Conn.t()
  def run_timeline(conn, %{"issue_identifier" => issue_identifier} = params) do
    cursor = Map.get(params, "cursor")

    if control_plane_mode?() do
      control_plane_not_available(conn)
    else
      case SymphonyElixir.Orchestrator.run_timeline(
             orchestrator(),
             issue_identifier,
             cursor: cursor,
             timeout: snapshot_timeout_ms()
           ) do
        {:ok, payload} ->
          json(conn, Presenter.run_timeline_payload(payload))

        {:error, :invalid_cursor} ->
          error_response(conn, 400, "invalid_cursor", "Timeline cursor is invalid")

        {:error, :run_not_found} ->
          error_response(conn, 404, "run_not_found", "Run timeline not found")

        {:error, :duplicate_run} ->
          error_response(conn, 409, "duplicate_run", "Multiple running entries matched this run")

        {:error, :timeline_unavailable} ->
          error_response(conn, 503, "timeline_unavailable", "Run timeline is unavailable")

        :timeout ->
          error_response(conn, 503, "timeline_unavailable", "Run timeline is unavailable")

        :unavailable ->
          error_response(conn, 503, "timeline_unavailable", "Run timeline is unavailable")
      end
    end
  end

  @spec projects(Conn.t(), map()) :: Conn.t()
  def projects(conn, _params) do
    json(conn, Presenter.projects_payload(project_registry()))
  end

  @spec health(Conn.t(), map()) :: Conn.t()
  def health(conn, _params) do
    json(conn, %{
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      status: "ok",
      runtime_mode: runtime_mode() |> to_string()
    })
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

  @spec project_run_timeline(Conn.t(), map()) :: Conn.t()
  def project_run_timeline(conn, %{"project_id" => project_id, "issue_identifier" => issue_identifier} = params) do
    if control_plane_mode?() do
      cursor = Map.get(params, "cursor")

      case project_run_timeline_payload(project_id, issue_identifier, cursor) do
        {:ok, payload} ->
          json(conn, payload)

        {:error, :project_not_found} ->
          error_response(conn, 404, "project_not_found", "Project not found")

        {:error, :run_not_found} ->
          error_response(conn, 404, "run_not_found", "Run timeline not found")

        {:error, :invalid_cursor} ->
          error_response(conn, 400, "invalid_cursor", "Timeline cursor is invalid")

        {:error, :duplicate_run} ->
          error_response(conn, 409, "duplicate_run", "Multiple running entries matched this run")

        {:error, :timeline_unavailable} ->
          error_response(conn, 503, "timeline_unavailable", "Run timeline is unavailable")
      end
    else
      control_plane_not_available(conn)
    end
  end

  @spec m3_precheck(Conn.t(), map()) :: Conn.t()
  def m3_precheck(conn, _params) do
    if control_plane_mode?() do
      control_plane_not_available(conn)
    else
      case SymphonyElixir.Orchestrator.m3_precheck(orchestrator()) do
        {:ok, payload} -> json(conn, Presenter.m3_precheck_payload(payload))
        {:error, reason} -> error_response(conn, 503, "m3_precheck_unavailable", inspect(reason))
      end
    end
  end

  @spec project_m3_precheck(Conn.t(), map()) :: Conn.t()
  def project_m3_precheck(conn, %{"project_id" => project_id}) do
    if control_plane_mode?() do
      case project_m3_precheck_payload(project_id) do
        {:ok, payload} -> json(conn, payload)
        {:error, :project_not_found} -> error_response(conn, 404, "project_not_found", "Project not found")
        {:error, reason} -> error_response(conn, 503, "m3_precheck_proxy_failed", inspect(reason))
      end
    else
      control_plane_not_available(conn)
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

  defp runtime_mode do
    Endpoint.config(:runtime_mode) || SymphonyElixir.runtime_mode()
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

  defp project_worker_request(project_id, path) when is_binary(project_id) and is_binary(path) do
    manager_name =
      Application.get_env(
        :symphony_elixir,
        :project_process_manager_name,
        SymphonyElixir.ProjectProcessManager
      )

    with {:ok, worker_port} <- safe_worker_port_for_project(manager_name, project_id),
         {:ok, %Req.Response{} = response} <- worker_req(worker_port, path) do
      case response do
        %Req.Response{status: status, body: body} when status in 200..299 ->
          {:ok, body}

        %Req.Response{status: status, body: body} ->
          {:error, {:worker_status, status, body}}
      end
    else
      {:error, :not_found} -> {:error, :project_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp worker_req(worker_port, path) when is_integer(worker_port) and is_binary(path) do
    if String.contains?(path, "/m3_precheck") do
      Req.post("http://127.0.0.1:#{worker_port}#{path}", json: %{}, retry: false)
    else
      Req.get("http://127.0.0.1:#{worker_port}#{path}", retry: false)
    end
  end

  defp safe_worker_port_for_project(manager_name, project_id) do
    ProjectProcessManager.worker_port_for_project(manager_name, project_id)
  catch
    :exit, _reason -> {:error, :project_manager_unavailable}
  end

  defp timeline_query_string(nil), do: ""
  defp timeline_query_string(""), do: ""
  defp timeline_query_string(cursor), do: "?cursor=#{URI.encode_www_form(cursor)}"

  defp timeline_path(issue_identifier, cursor) do
    "/api/v1/runs/#{URI.encode(issue_identifier, &URI.char_unreserved?/1)}/timeline#{timeline_query_string(cursor)}"
  end
end
