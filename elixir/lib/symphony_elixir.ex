defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @type runtime_mode :: :workflow | :control_plane

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end

  @spec runtime_mode() :: runtime_mode()
  def runtime_mode do
    case Application.get_env(:symphony_elixir, :runtime_mode, :workflow) do
      :control_plane -> :control_plane
      _ -> :workflow
    end
  end

  @spec control_plane_mode?() :: boolean()
  def control_plane_mode? do
    runtime_mode() == :control_plane
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 ->
        port

      _ ->
        case runtime_mode() do
          :control_plane -> 4000
          :workflow -> SymphonyElixir.Config.server_port()
        end
    end
  end

  @spec server_host() :: String.t()
  def server_host do
    case runtime_mode() do
      :control_plane ->
        Application.get_env(:symphony_elixir, :control_plane_host_override, "127.0.0.1")

      :workflow ->
        SymphonyElixir.Config.settings!().server.host
    end
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  @runtime_worker_children [
    SymphonyElixir.Orchestrator,
    SymphonyElixir.HttpServer,
    SymphonyElixir.StatusDashboard
  ]

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.LogFile.configure()
    children = child_specs(SymphonyElixir.runtime_mode())

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: SymphonyElixir.Supervisor
    )
  end

  @spec child_specs(SymphonyElixir.runtime_mode()) :: [Supervisor.child_spec() | module()]
  def child_specs(mode) when mode in [:workflow, :control_plane] do
    base_children = [
      {Phoenix.PubSub, name: SymphonyElixir.PubSub},
      {Task.Supervisor, name: SymphonyElixir.TaskSupervisor}
    ]

    case mode do
      :workflow ->
        workflow_children =
          [SymphonyElixir.WorkflowStore] ++
            if disable_runtime_workers_in_tests?(), do: [], else: @runtime_worker_children

        base_children ++ workflow_children

      :control_plane ->
        base_children ++
          [
            SymphonyElixir.ControlPlaneSnapshotServer,
            SymphonyElixir.HttpServer
          ]
    end
  end

  defp disable_runtime_workers_in_tests? do
    Application.get_env(:symphony_elixir, :disable_runtime_workers_in_tests, false)
  end

  @impl true
  def stop(_state) do
    if SymphonyElixir.runtime_mode() == :workflow do
      SymphonyElixir.StatusDashboard.render_offline_status()
    end

    :ok
  end
end
