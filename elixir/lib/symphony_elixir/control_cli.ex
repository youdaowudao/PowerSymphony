defmodule SymphonyElixir.ControlCLI do
  @moduledoc """
  Entrypoint for the standalone Symphony control plane.
  """

  @default_config_path Path.expand("../../../bin/symphony.projects.yaml", __DIR__)
  @switches [config: :string, port: :integer]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type main_result :: {0 | 1, String.t() | nil}
  @type deps :: %{
          file_regular?: (String.t() -> boolean()),
          set_runtime_mode: (atom() -> :ok | {:error, term()}),
          set_project_config_path: (String.t() -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() -> :ok | {:error, term()}),
          ensure_all_started: (-> ensure_started_result())
        }

  @spec main_result([String.t()], deps(), (-> pid() | nil)) :: main_result()
  def main_result(args, deps \\ runtime_deps(), supervisor_lookup \\ fn -> Process.whereis(SymphonyElixir.Supervisor) end) do
    case evaluate(args, deps) do
      :ok ->
        wait_for_shutdown_result(supervisor_lookup)

      {:error, message} ->
        {1, message}
    end
  end

  @spec evaluate([String.t()], deps()) :: :ok | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        config_path = Keyword.get(opts, :config, @default_config_path)

        with :ok <- maybe_set_server_port(opts, deps) do
          run(config_path, deps)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(config_path, deps) do
    expanded_path = Path.expand(config_path)

    if deps.file_regular?.(expanded_path) do
      :ok = deps.set_runtime_mode.(:control_plane)
      :ok = deps.set_project_config_path.(expanded_path)

      case deps.ensure_all_started.() do
        {:ok, _started_apps} ->
          :ok

        {:error, reason} ->
          {:error, "Failed to start Symphony control plane with config #{expanded_path}: #{inspect(reason)}"}
      end
    else
      {:error, "Project config file not found: #{expanded_path}"}
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    "Usage: symphony_control [--config <path>] [--port <port>]"
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      set_runtime_mode: &set_runtime_mode/1,
      set_project_config_path: &set_project_config_path/1,
      set_server_port_override: &set_server_port_override/1,
      ensure_all_started: fn -> Application.ensure_all_started(:symphony_elixir) end
    }
  end

  defp set_runtime_mode(mode) when mode in [:workflow, :control_plane] do
    Application.put_env(:symphony_elixir, :runtime_mode, mode)
    :ok
  end

  defp set_project_config_path(path) when is_binary(path) do
    Application.put_env(:symphony_elixir, :project_config_path_override, path)
    :ok
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:symphony_elixir, :server_port_override, port)
    :ok
  end

  @spec wait_for_shutdown_result((-> pid() | nil)) :: main_result()
  def wait_for_shutdown_result(supervisor_lookup) do
    case supervisor_lookup.() do
      nil ->
        {1, "Symphony supervisor is not running"}

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> {0, nil}
              _ -> {1, nil}
            end
        end
    end
  end
end
