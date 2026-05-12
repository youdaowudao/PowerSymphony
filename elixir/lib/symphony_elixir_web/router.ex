defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", SymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
  end

  scope "/", SymphonyElixirWeb do
    get("/api/v1/health", ObservabilityApiController, :health)
    get("/api/v1/state", ObservabilityApiController, :state)
    get("/api/v1/projects", ObservabilityApiController, :projects)
    get("/api/v1/projects/:project_id/summary", ObservabilityApiController, :project_summary)
    post("/api/v1/projects/:project_id/m3_precheck", ObservabilityApiController, :project_m3_precheck)
    post("/api/v1/projects/:project_id/start", ObservabilityApiController, :start_project)
    post("/api/v1/projects/:project_id/stop", ObservabilityApiController, :stop_project)
    post("/api/v1/projects/:project_id/restart", ObservabilityApiController, :restart_project)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/health", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/projects", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/projects/:project_id/summary", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/projects/:project_id/m3_precheck", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/projects/:project_id/start", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/projects/:project_id/stop", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/projects/:project_id/restart", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/m3_precheck", ObservabilityApiController, :m3_precheck)
    match(:*, "/api/v1/m3_precheck", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
