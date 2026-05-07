defmodule SymphonyElixir.ControlPlaneRuntimeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Application, as: SymphonyApplication
  alias SymphonyElixir.ControlPlaneSnapshotServer

  setup do
    previous_runtime_mode = Application.get_env(:symphony_elixir, :runtime_mode)
    previous_control_plane_host = Application.get_env(:symphony_elixir, :control_plane_host_override)
    previous_server_port = Application.get_env(:symphony_elixir, :server_port_override)

    on_exit(fn ->
      restore_app_env(:runtime_mode, previous_runtime_mode)
      restore_app_env(:control_plane_host_override, previous_control_plane_host)
      restore_app_env(:server_port_override, previous_server_port)
    end)

    :ok
  end

  test "control-plane mode starts only minimal children" do
    ids =
      SymphonyApplication.child_specs(:control_plane)
      |> Enum.map(&child_id/1)

    assert ids == [
             Phoenix.PubSub,
             Task.Supervisor,
             SymphonyElixir.ControlPlaneSnapshotServer,
             SymphonyElixir.HttpServer
           ]
  end

  test "workflow mode can still include full runtime children when test override is disabled" do
    previous_disable_runtime_workers =
      Application.get_env(:symphony_elixir, :disable_runtime_workers_in_tests)

    on_exit(fn ->
      restore_app_env(:disable_runtime_workers_in_tests, previous_disable_runtime_workers)
    end)

    Application.put_env(:symphony_elixir, :disable_runtime_workers_in_tests, false)

    ids =
      SymphonyApplication.child_specs(:workflow)
      |> Enum.map(&child_id/1)

    assert ids == [
             Phoenix.PubSub,
             Task.Supervisor,
             SymphonyElixir.WorkflowStore,
             SymphonyElixir.Orchestrator,
             SymphonyElixir.HttpServer,
             SymphonyElixir.StatusDashboard
           ]
  end

  test "workflow mode in test env does not auto-start runtime workers" do
    previous_disable_runtime_workers =
      Application.get_env(:symphony_elixir, :disable_runtime_workers_in_tests)

    on_exit(fn ->
      restore_app_env(:disable_runtime_workers_in_tests, previous_disable_runtime_workers)
    end)

    Application.put_env(:symphony_elixir, :disable_runtime_workers_in_tests, true)

    ids =
      SymphonyApplication.child_specs(:workflow)
      |> Enum.map(&child_id/1)

    assert ids == [
             Phoenix.PubSub,
             Task.Supervisor,
             SymphonyElixir.WorkflowStore
           ]
  end

  test "control plane snapshot server returns default static snapshot and refresh payload" do
    server_name = Module.concat(__MODULE__, DefaultSnapshotServer)
    start_supervised!({ControlPlaneSnapshotServer, name: server_name})

    assert GenServer.call(server_name, :snapshot) == %{
             running: [],
             retrying: [],
             codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
             rate_limits: nil
           }

    refresh_payload = GenServer.call(server_name, :request_refresh)
    assert refresh_payload.queued == false
    assert refresh_payload.coalesced == false
    assert refresh_payload.operations == []
    assert %DateTime{} = refresh_payload.requested_at
  end

  test "control plane snapshot server preserves custom snapshot and refresh metadata" do
    server_name = Module.concat(__MODULE__, CustomSnapshotServer)

    custom_snapshot = %{
      running: [%{issue_id: "issue-1"}],
      retrying: [],
      codex_totals: %{input_tokens: 1, output_tokens: 2, total_tokens: 3, seconds_running: 4},
      rate_limits: %{"primary" => %{"remaining" => 7}}
    }

    custom_refresh = %{
      queued: true,
      coalesced: true,
      requested_at: nil,
      operations: ["projects"]
    }

    server_opts = [name: server_name, snapshot: custom_snapshot, refresh: custom_refresh]
    start_supervised!({ControlPlaneSnapshotServer, server_opts})

    assert GenServer.call(server_name, :snapshot) == custom_snapshot

    refresh_payload = GenServer.call(server_name, :request_refresh)

    assert Map.drop(refresh_payload, [:requested_at]) == %{
             queued: true,
             coalesced: true,
             operations: ["projects"]
           }

    assert %DateTime{} = refresh_payload.requested_at
  end

  test "control plane snapshot server starts with default name and payloads" do
    default_name = SymphonyElixir.ControlPlaneSnapshotServer
    previous_pid = Process.whereis(default_name)

    if previous_pid do
      Process.unregister(default_name)
    end

    on_exit(fn ->
      current_pid = Process.whereis(default_name)

      if current_pid do
        GenServer.stop(current_pid)
      end

      if previous_pid do
        Process.register(previous_pid, default_name)
      end
    end)

    assert {:ok, pid} = ControlPlaneSnapshotServer.start_link()
    assert Process.whereis(default_name) == pid

    assert GenServer.call(default_name, :snapshot) == %{
             running: [],
             retrying: [],
             codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
             rate_limits: nil
           }
  end

  test "runtime mode helpers and control plane host port helpers honor env overrides" do
    write_workflow_file!(Workflow.workflow_file_path(), server_host: "0.0.0.0")

    Application.delete_env(:symphony_elixir, :runtime_mode)
    assert SymphonyElixir.runtime_mode() == :workflow
    assert SymphonyElixir.control_plane_mode?() == false
    assert SymphonyElixir.server_host() == "0.0.0.0"
    assert SymphonyElixir.server_port() == nil

    Application.put_env(:symphony_elixir, :runtime_mode, :unexpected)
    assert SymphonyElixir.runtime_mode() == :workflow

    Application.put_env(:symphony_elixir, :runtime_mode, :control_plane)
    Application.put_env(:symphony_elixir, :control_plane_host_override, "0.0.0.0")
    assert SymphonyElixir.runtime_mode() == :control_plane
    assert SymphonyElixir.control_plane_mode?() == true
    assert SymphonyElixir.server_host() == "0.0.0.0"
    assert SymphonyElixir.server_port() == 4000

    Application.put_env(:symphony_elixir, :server_port_override, 4999)
    assert SymphonyElixir.server_port() == 4999
  end

  test "application stop renders offline status in workflow mode" do
    Application.put_env(:symphony_elixir, :runtime_mode, :workflow)

    rendered =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = SymphonyApplication.stop(:normal)
      end)

    assert rendered =~ "app_status=offline"
  end

  defp child_id(%{id: id}), do: id
  defp child_id({module, _opts}) when is_atom(module), do: module
  defp child_id(module) when is_atom(module), do: module

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
