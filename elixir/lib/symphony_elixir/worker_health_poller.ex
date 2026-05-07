defmodule SymphonyElixir.WorkerHealthPoller do
  @moduledoc """
  Periodically probes running workers via the lightweight health endpoint.
  """

  use GenServer

  alias SymphonyElixir.{Config, ProjectProcessManager}

  @default_name __MODULE__

  @type state :: %{
          manager: GenServer.name(),
          poll_interval_ms: pos_integer(),
          in_flight_projects: MapSet.t(String.t())
        }

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @default_name))
  end

  @impl true
  def init(opts) do
    state = %{
      manager: Keyword.get(opts, :manager, ProjectProcessManager),
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, Config.settings!().control_plane.health_poll_interval_ms),
      in_flight_projects: MapSet.new()
    }

    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, state.poll_interval_ms)

    next_state =
      state.manager
      |> poll_targets()
      |> Enum.reduce(state, &start_poll_if_idle(&2, &1))

    {:noreply, next_state}
  end

  def handle_info({:poll_complete, project_id}, state) when is_binary(project_id) do
    {:noreply, %{state | in_flight_projects: MapSet.delete(state.in_flight_projects, project_id)}}
  end

  defp poll_targets(manager) do
    ProjectProcessManager.health_poll_targets(manager)
  catch
    :exit, _reason -> []
  end

  defp start_poll_if_idle(state, %{project_id: project_id} = target) do
    if MapSet.member?(state.in_flight_projects, project_id) do
      state
    else
      caller = self()
      manager = state.manager

      spawn(fn ->
        try do
          poll_target(manager, target)
        after
          send(caller, {:poll_complete, project_id})
        end
      end)

      %{state | in_flight_projects: MapSet.put(state.in_flight_projects, project_id)}
    end
  end

  defp poll_target(manager, %{project_id: project_id, worker_port: worker_port, health_check_timeout_ms: timeout_ms}) do
    case Req.get("http://127.0.0.1:#{worker_port}/api/v1/health", retry: false, receive_timeout: timeout_ms) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        ProjectProcessManager.record_health_success(manager, project_id, DateTime.utc_now())

      {:ok, %Req.Response{status: status}} ->
        ProjectProcessManager.record_health_failure(
          manager,
          project_id,
          DateTime.utc_now(),
          "health check returned status #{status}"
        )

      {:error, error} ->
        ProjectProcessManager.record_health_failure(manager, project_id, DateTime.utc_now(), format_error(error))
    end
  end

  defp format_error(%Req.TransportError{reason: :timeout}), do: "request timed out"
  defp format_error(error), do: Exception.message(error)
end
