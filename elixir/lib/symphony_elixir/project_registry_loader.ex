defmodule SymphonyElixir.ProjectRegistryLoader do
  @moduledoc """
  Resolves and loads the static project registry for the control plane.
  """

  alias SymphonyElixir.ProjectRegistry

  @default_config_filename "symphony.projects.yaml"

  @spec load() :: ProjectRegistry.t()
  def load do
    case project_config_path() do
      path when is_binary(path) ->
        case ProjectRegistry.load(path) do
          {:ok, registry} -> registry
          {:error, _errors} -> empty_registry()
        end

      nil ->
        empty_registry()
    end
  end

  @spec project_config_path() :: Path.t() | nil
  def project_config_path do
    path =
      Application.get_env(:symphony_elixir, :project_config_path_override) ||
        Path.expand(@default_config_filename)

    if File.regular?(path), do: path, else: nil
  end

  @spec empty_registry() :: ProjectRegistry.t()
  def empty_registry do
    %ProjectRegistry{entries: []}
  end
end
