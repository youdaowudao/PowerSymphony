defmodule SymphonyElixirWeb.StaticAssets do
  @moduledoc false

  resolve_dependency_asset = fn app, relative_path ->
    source_path =
      Path.expand("../../deps/#{Atom.to_string(app)}/#{relative_path}", __DIR__)

    if File.exists?(source_path) do
      source_path
    else
      Application.app_dir(app, relative_path)
    end
  end

  @dashboard_css_path Path.expand("../../priv/static/dashboard.css", __DIR__)
  @phoenix_html_js_path resolve_dependency_asset.(:phoenix_html, "priv/static/phoenix_html.js")
  @phoenix_js_path resolve_dependency_asset.(:phoenix, "priv/static/phoenix.js")
  @phoenix_live_view_js_path resolve_dependency_asset.(:phoenix_live_view, "priv/static/phoenix_live_view.js")

  @external_resource @dashboard_css_path
  @external_resource @phoenix_html_js_path
  @external_resource @phoenix_js_path
  @external_resource @phoenix_live_view_js_path

  @dashboard_css File.read!(@dashboard_css_path)
  @phoenix_html_js File.read!(@phoenix_html_js_path)
  @phoenix_js File.read!(@phoenix_js_path)
  @phoenix_live_view_js File.read!(@phoenix_live_view_js_path)

  @assets %{
    "/dashboard.css" => {"text/css", @dashboard_css},
    "/vendor/phoenix_html/phoenix_html.js" => {"application/javascript", @phoenix_html_js},
    "/vendor/phoenix/phoenix.js" => {"application/javascript", @phoenix_js},
    "/vendor/phoenix_live_view/phoenix_live_view.js" => {"application/javascript", @phoenix_live_view_js}
  }

  @spec fetch(String.t()) :: {:ok, String.t(), binary()} | :error
  def fetch(path) when is_binary(path) do
    case Map.fetch(@assets, path) do
      {:ok, {content_type, body}} -> {:ok, content_type, body}
      :error -> :error
    end
  end
end
