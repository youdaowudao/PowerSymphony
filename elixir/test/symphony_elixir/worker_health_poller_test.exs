defmodule SymphonyElixir.WorkerHealthPollerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ProjectProcessManager
  alias SymphonyElixir.WorkerHealthPoller

  defmodule FlakyRecordManager do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts) do
      {:ok,
       %{
         targets: Keyword.fetch!(opts, :targets),
         result_agent: Keyword.fetch!(opts, :result_agent),
         crash_once_agent: Keyword.fetch!(opts, :crash_once_agent)
       }}
    end

    def handle_call(:health_poll_targets, _from, state) do
      {:reply, state.targets, state}
    end

    def handle_call({:record_health_success, "alpha", observed_at}, _from, state) do
      if Agent.get_and_update(state.crash_once_agent, fn
           true -> {true, false}
           false -> {false, false}
         end) do
        raise "intentional record_health_success crash"
      else
        Agent.update(state.result_agent, fn _ -> {:ok, observed_at} end)
        {:reply, :ok, state}
      end
    end

    def handle_call({:record_health_failure, "alpha", observed_at, error}, _from, state) do
      Agent.update(state.result_agent, fn _ -> {:error, observed_at, error} end)
      {:reply, :ok, state}
    end
  end

  defmodule HealthOnlyServer do
    def start_link(opts) do
      Task.start_link(fn -> serve(Keyword.fetch!(opts, :port)) end)
    end

    defp serve(port) do
      {:ok, listener} =
        :gen_tcp.listen(port, [:binary, {:active, false}, {:reuseaddr, true}, {:ip, {127, 0, 0, 1}}])

      accept_loop(listener)
    end

    defp accept_loop(listener) do
      {:ok, socket} = :gen_tcp.accept(listener)

      spawn(fn ->
        _request = :gen_tcp.recv(socket, 0, 5_000)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-length: 2\r\ncontent-type: text/plain\r\nconnection: close\r\n\r\nok"
          )

        :gen_tcp.close(socket)
      end)

      accept_loop(listener)
    end
  end

  setup do
    previous_config_path = Application.get_env(:symphony_elixir, :project_config_path_override)
    {:ok, cleanup_agent} = Agent.start(fn -> [] end)
    Process.put(:fake_worker_cleanup_agent, cleanup_agent)

    on_exit(fn ->
      restore_app_env(:project_config_path_override, previous_config_path)

      cleanup_agent
      |> maybe_agent_values()
      |> Enum.each(&kill_fake_worker_port/1)

      if Process.alive?(cleanup_agent) do
        Agent.stop(cleanup_agent)
      end
    end)

    :ok
  end

  test "poller keeps responsive running worker as running and stamps last_seen_at" do
    test_root = temp_root!("poller-running")
    manager_name = Module.concat(__MODULE__, RunningManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    write_workflow_file!(Workflow.workflow_file_path(),
      control_plane: %{health_poll_interval_ms: 10, health_check_timeout_ms: 50}
    )

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)

    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{"alpha" => "normal"})})
    assert {:ok, runtime_state} = ProjectProcessManager.start_project(manager_name, "alpha")

    start_supervised!({WorkerHealthPoller, manager: manager_name, poll_interval_ms: 100})

    assert_eventually(fn ->
      entry = fetch_entry!(manager_name, "alpha")

      entry.runtime_state.status == :running and
        entry.runtime_state.pid == runtime_state.pid and
        entry.runtime_state.health_status == :healthy and
        match?(%DateTime{}, entry.runtime_state.last_seen_at) and
        entry.runtime_state.last_health_check_at == entry.runtime_state.last_seen_at and
        entry.runtime_state.last_error == nil
    end)
  end

  test "poller marks a running worker unreachable after timeout" do
    test_root = temp_root!("poller-timeout")
    manager_name = Module.concat(__MODULE__, TimeoutManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    write_workflow_file!(Workflow.workflow_file_path(),
      control_plane: %{health_poll_interval_ms: 10, health_check_timeout_ms: 50}
    )

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)

    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{"alpha" => "hang"})})
    assert {:ok, _runtime_state} = ProjectProcessManager.start_project(manager_name, "alpha")

    start_supervised!({WorkerHealthPoller, manager: manager_name, poll_interval_ms: 100})

    assert_eventually(
      fn ->
        entry = fetch_entry!(manager_name, "alpha")

        entry.runtime_state.status == :unreachable and
          entry.runtime_state.health_status == :unreachable and
          entry.runtime_state.last_seen_at == nil and
          entry.runtime_state.last_error == "request timed out"
      end,
      40
    )
  end

  test "poller returns unreachable worker to running after a later successful response" do
    test_root = temp_root!("poller-recovery")
    manager_name = Module.concat(__MODULE__, RecoveryManager)
    port = reserve_tcp_port!()
    request_log = Path.join(test_root, "requests.log")

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    write_workflow_file!(Workflow.workflow_file_path(),
      control_plane: %{health_poll_interval_ms: 10, health_check_timeout_ms: 50}
    )

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)

    start_supervised!(
      {ProjectProcessManager,
       [
         name: manager_name,
         command_builder: fake_worker_builder(%{"alpha" => {"hang_once", request_log}})
       ]}
    )

    assert {:ok, _runtime_state} = ProjectProcessManager.start_project(manager_name, "alpha")

    start_supervised!({WorkerHealthPoller, manager: manager_name, poll_interval_ms: 100})

    assert_eventually(
      fn ->
        fetch_entry!(manager_name, "alpha").runtime_state.status == :unreachable
      end,
      40
    )

    assert_eventually(
      fn ->
        entry = fetch_entry!(manager_name, "alpha")

        entry.runtime_state.status == :running and
          entry.runtime_state.health_status == :healthy and
          match?(%DateTime{}, entry.runtime_state.last_seen_at) and
          entry.runtime_state.last_error == nil
      end,
      40
    )
  end

  test "poller marks worker unreachable immediately after the first timeout following a success" do
    test_root = temp_root!("poller-first-timeout-unreachable")
    manager_name = Module.concat(__MODULE__, FirstTimeoutUnreachableManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    write_workflow_file!(Workflow.workflow_file_path(),
      control_plane: %{health_poll_interval_ms: 10, health_check_timeout_ms: 50}
    )

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)

    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{"alpha" => "ok_then_hang"})})

    assert {:ok, _runtime_state} = ProjectProcessManager.start_project(manager_name, "alpha")
    start_supervised!({WorkerHealthPoller, manager: manager_name, poll_interval_ms: 1})

    assert_eventually(fn ->
      fetch_entry!(manager_name, "alpha").runtime_state.last_error == "request timed out"
    end)

    entry_after_first_timeout = fetch_entry!(manager_name, "alpha")
    assert entry_after_first_timeout.runtime_state.status == :unreachable
    assert entry_after_first_timeout.runtime_state.health_status == :unreachable
    assert match?(%DateTime{}, entry_after_first_timeout.runtime_state.last_seen_at)
    assert entry_after_first_timeout.runtime_state.last_error == "request timed out"
  end

  test "poller does not cross-write last_seen_at or last_error across projects" do
    test_root = temp_root!("poller-isolation")
    manager_name = Module.concat(__MODULE__, IsolationManager)
    alpha_port = reserve_tcp_port!()
    beta_port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", alpha_port),
        project_fixture(test_root, "beta", beta_port)
      ])

    write_workflow_file!(Workflow.workflow_file_path(),
      control_plane: %{health_poll_interval_ms: 10, health_check_timeout_ms: 50}
    )

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)

    start_supervised!(
      {ProjectProcessManager,
       name: manager_name,
       command_builder:
         fake_worker_builder(%{
           "alpha" => "normal",
           "beta" => "hang"
         })}
    )

    assert {:ok, _} = ProjectProcessManager.start_project(manager_name, "alpha")
    assert {:ok, _} = ProjectProcessManager.start_project(manager_name, "beta")

    start_supervised!({WorkerHealthPoller, manager: manager_name, poll_interval_ms: 10})

    assert_eventually(fn ->
      alpha_entry = fetch_entry!(manager_name, "alpha")
      beta_entry = fetch_entry!(manager_name, "beta")

      alpha_entry.runtime_state.status == :running and
        match?(%DateTime{}, alpha_entry.runtime_state.last_seen_at) and
        alpha_entry.runtime_state.last_error == nil and
        beta_entry.runtime_state.status == :unreachable and
        beta_entry.runtime_state.last_seen_at == nil and
        beta_entry.runtime_state.last_error == "request timed out"
    end)
  end

  test "poller does not let one timeout block healthy workers in the same cycle" do
    test_root = temp_root!("poller-nonblocking")
    manager_name = Module.concat(__MODULE__, NonBlockingManager)
    alpha_port = reserve_tcp_port!()
    beta_port = reserve_tcp_port!()
    alpha_request_log = Path.join(test_root, "alpha-requests.log")
    beta_request_log = Path.join(test_root, "beta-requests.log")

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", alpha_port),
        project_fixture(test_root, "beta", beta_port)
      ])

    write_workflow_file!(Workflow.workflow_file_path(),
      control_plane: %{health_poll_interval_ms: 1_000, health_check_timeout_ms: 120}
    )

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)

    start_supervised!(
      {ProjectProcessManager,
       name: manager_name,
       command_builder:
         fake_worker_builder(%{
           "alpha" => {"hang", alpha_request_log},
           "beta" => {"normal", beta_request_log}
         })}
    )

    assert {:ok, _} = ProjectProcessManager.start_project(manager_name, "alpha")
    assert {:ok, _} = ProjectProcessManager.start_project(manager_name, "beta")

    start_supervised!({WorkerHealthPoller, manager: manager_name, poll_interval_ms: 1_000})

    assert_eventually(
      fn ->
        beta_entry = fetch_entry!(manager_name, "beta")

        File.exists?(beta_request_log) and
          File.read!(beta_request_log) != "" and
          beta_entry.runtime_state.status == :running and
          beta_entry.runtime_state.health_status == :healthy and
          match?(%DateTime{}, beta_entry.runtime_state.last_seen_at)
      end,
      8
    )

    alpha_entry = fetch_entry!(manager_name, "alpha")
    beta_entry = fetch_entry!(manager_name, "beta")

    alpha_request_count =
      if File.exists?(alpha_request_log) do
        alpha_request_log
        |> File.read!()
        |> String.split("\n", trim: true)
        |> length()
      else
        0
      end

    assert alpha_request_count <= 1
    assert beta_entry.runtime_state.status == :running
    assert beta_entry.runtime_state.health_status == :healthy
    assert alpha_entry.runtime_state.last_error in [nil, "request timed out"]
  end

  test "poller only calls /api/v1/health" do
    test_root = temp_root!("poller-health-only")
    manager_name = Module.concat(__MODULE__, HealthOnlyManager)
    port = reserve_tcp_port!()
    request_log = Path.join(test_root, "requests.log")

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    write_workflow_file!(Workflow.workflow_file_path(),
      control_plane: %{health_poll_interval_ms: 10, health_check_timeout_ms: 50}
    )

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)

    start_supervised!(
      {ProjectProcessManager,
       [
         name: manager_name,
         command_builder: fake_worker_builder(%{"alpha" => {"normal", request_log}})
       ]}
    )

    assert {:ok, _} = ProjectProcessManager.start_project(manager_name, "alpha")
    start_supervised!({WorkerHealthPoller, manager: manager_name, poll_interval_ms: 10})

    assert_eventually(fn -> File.exists?(request_log) and File.read!(request_log) != "" end)

    paths =
      request_log
      |> File.read!()
      |> String.split("\n", trim: true)

    assert paths != []
    assert Enum.all?(paths, &(&1 == "/api/v1/health"))
  end

  test "start_link without opts uses default registration and ignores dead manager exits" do
    original_manager_name = Application.get_env(:symphony_elixir, :project_process_manager_name)
    default_manager_name = SymphonyElixir.ProjectProcessManager

    on_exit(fn ->
      restore_app_env(:project_process_manager_name, original_manager_name)

      case GenServer.whereis(WorkerHealthPoller) do
        pid when is_pid(pid) -> GenServer.stop(pid)
        _other -> :ok
      end
    end)

    Application.put_env(:symphony_elixir, :project_process_manager_name, default_manager_name)

    assert {:ok, pid} = WorkerHealthPoller.start_link()
    assert GenServer.whereis(WorkerHealthPoller) == pid

    dead_manager_name = Module.concat(__MODULE__, DeadManager)
    Process.register(spawn(fn -> :ok end), dead_manager_name)

    send(pid, :poll)
    Process.sleep(50)

    assert Process.alive?(pid)
  end

  test "poller records non-2xx and non-timeout transport failures" do
    test_root = temp_root!("poller-error-branches")
    manager_name = Module.concat(__MODULE__, ErrorBranchManager)
    alpha_port = reserve_tcp_port!()
    beta_port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", alpha_port),
        project_fixture(test_root, "beta", beta_port)
      ])

    write_workflow_file!(Workflow.workflow_file_path(),
      control_plane: %{health_poll_interval_ms: 10, health_check_timeout_ms: 50}
    )

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)

    start_supervised!(
      {ProjectProcessManager,
       name: manager_name,
       command_builder:
         fake_worker_builder(%{
           "alpha" => "status_503",
           "beta" => "close"
         })}
    )

    assert {:ok, _} = ProjectProcessManager.start_project(manager_name, "alpha")
    assert {:ok, _} = ProjectProcessManager.start_project(manager_name, "beta")

    start_supervised!({WorkerHealthPoller, manager: manager_name, poll_interval_ms: 100})

    assert_eventually(
      fn ->
        alpha_entry = fetch_entry!(manager_name, "alpha")
        beta_entry = fetch_entry!(manager_name, "beta")

        alpha_entry.runtime_state.last_error == "health check returned status 503" and
          is_binary(beta_entry.runtime_state.last_error) and
          beta_entry.runtime_state.last_error != "request timed out"
      end,
      40
    )
  end

  test "poller clears in-flight project after record path crash and polls it again" do
    port = reserve_tcp_port!()
    manager_name = Module.concat(__MODULE__, FlakyRecordManagerInstance)
    poller_name = Module.concat(__MODULE__, FlakyPoller)

    {:ok, result_agent} =
      start_supervised(%{
        id: Module.concat(__MODULE__, FlakyResultAgent),
        start: {Agent, :start_link, [fn -> :pending end]},
        restart: :temporary
      })

    {:ok, crash_once_agent} =
      start_supervised(%{
        id: Module.concat(__MODULE__, FlakyCrashOnceAgent),
        start: {Agent, :start_link, [fn -> true end]},
        restart: :temporary
      })

    {:ok, _server} =
      start_supervised(%{
        id: Module.concat(__MODULE__, HealthOnlyServerInstance),
        start: {HealthOnlyServer, :start_link, [[port: port]]},
        restart: :temporary
      })

    {:ok, _manager} =
      start_supervised(
        {FlakyRecordManager,
         [
           name: manager_name,
           targets: [%{project_id: "alpha", worker_port: port, health_check_timeout_ms: 50}],
           result_agent: result_agent,
           crash_once_agent: crash_once_agent
         ]}
      )

    {:ok, poller_pid} =
      start_supervised({WorkerHealthPoller, name: poller_name, manager: manager_name, poll_interval_ms: 50})

    assert_eventually(
      fn ->
        case Agent.get(result_agent, & &1) do
          {:ok, %DateTime{}} -> true
          _other -> false
        end
      end,
      40
    )

    assert Process.alive?(poller_pid)

    poller_state = :sys.get_state(poller_name)
    assert MapSet.size(poller_state.in_flight_projects) == 0
    assert Agent.get(crash_once_agent, & &1) == false
  end

  defp fetch_entry!(manager_name, project_id) do
    registry = ProjectProcessManager.project_registry(manager_name)
    entry = Enum.find(registry.entries, &(&1.project_id == project_id))
    assert entry != nil
    entry
  end

  defp fake_worker_builder(modes) do
    fake_worker_path = Path.expand("../support/project_process_manager_fake_worker.exs", __DIR__)

    fn entry ->
      {mode, request_log} =
        case Map.get(modes, entry.project_id, "normal") do
          {mode, request_log} -> {mode, request_log}
          mode -> {mode, nil}
        end

      base =
        "elixir #{shell_escape(fake_worker_path)} --mode #{mode} --port #{entry.normalized_config.worker_port}"

      if is_binary(request_log) do
        base <> " --request-log #{shell_escape(request_log)}"
      else
        base
      end
    end
  end

  defp project_fixture(test_root, project_id, worker_port, opts \\ []) do
    project_root = Path.join(test_root, project_id)
    workspace_root = Path.join(project_root, "workspace")
    logs_root = Path.join(project_root, "logs")
    workflow_path = Path.join(project_root, "generated/WORKFLOW.md")

    File.mkdir_p!(workspace_root)
    File.mkdir_p!(logs_root)

    if Keyword.get(opts, :workflow?, true) do
      File.mkdir_p!(Path.dirname(workflow_path))
      write_workflow_file!(workflow_path)
    end

    %{
      id: project_id,
      name: String.capitalize(project_id),
      workflow_generated: workflow_path,
      workspace_root: workspace_root,
      logs_root: logs_root,
      enabled: Keyword.get(opts, :enabled, true),
      worker_port: worker_port
    }
  end

  defp write_projects_config!(test_root, projects) do
    config_path = Path.join(test_root, "symphony.projects.yaml")

    body =
      [
        "projects:",
        Enum.map_join(projects, "\n", &project_yaml/1)
      ]
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    File.write!(config_path, body)
    config_path
  end

  defp project_yaml(project) do
    """
      - id: "#{project.id}"
        name: "#{project.name}"
        workflow_generated: "#{project.workflow_generated}"
        workspace_root: "#{project.workspace_root}"
        logs_root: "#{project.logs_root}"
        enabled: #{if(project.enabled, do: "true", else: "false")}
        worker_port: #{project.worker_port}
    """
  end

  defp temp_root!(label) do
    root = Path.join(System.tmp_dir!(), "symphony-worker-health-poller-#{label}-#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    root
  end

  defp reserve_tcp_port! do
    base = 40_000 + rem(System.unique_integer([:positive]), 20_000)
    port = reserve_tcp_port!(base, 200)

    case Process.get(:fake_worker_cleanup_agent) do
      cleanup_agent when is_pid(cleanup_agent) ->
        Agent.update(cleanup_agent, &[port | &1])

      _other ->
        :ok
    end

    port
  end

  defp reserve_tcp_port!(port, attempts_left) when attempts_left > 0 do
    case :gen_tcp.listen(port, [:binary, {:active, false}, {:reuseaddr, true}, {:ip, {127, 0, 0, 1}}]) do
      {:ok, socket} ->
        :ok = :gen_tcp.close(socket)
        port

      {:error, :eaddrinuse} ->
        reserve_tcp_port!(port + 1, attempts_left - 1)
    end
  end

  defp reserve_tcp_port!(_port, 0), do: flunk("failed to reserve fake worker tcp port")

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end

  defp kill_fake_worker_port(port) when is_integer(port) do
    fake_worker_path = Path.expand("../support/project_process_manager_fake_worker.exs", __DIR__)
    port_fragment = "--port #{port}"

    case System.cmd("ps", ["-eo", "pid,args"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&(String.contains?(&1, fake_worker_path) and String.contains?(&1, port_fragment)))
        |> Enum.map(&String.trim_leading/1)
        |> Enum.map(&Integer.parse/1)
        |> Enum.flat_map(fn
          {pid, _rest} -> [pid]
          :error -> []
        end)
        |> Enum.each(fn pid ->
          _ = System.cmd("kill", ["-TERM", Integer.to_string(pid)])
        end)

        Process.sleep(100)

        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&(String.contains?(&1, fake_worker_path) and String.contains?(&1, port_fragment)))
        |> Enum.map(&String.trim_leading/1)
        |> Enum.map(&Integer.parse/1)
        |> Enum.flat_map(fn
          {pid, _rest} -> [pid]
          :error -> []
        end)
        |> Enum.each(fn pid ->
          _ = System.cmd("kill", ["-KILL", Integer.to_string(pid)])
        end)

      _other ->
        :ok
    end

    :ok
  end

  defp kill_fake_worker_port(_port), do: :ok

  defp maybe_agent_values(agent) when is_pid(agent) do
    if Process.alive?(agent) do
      Agent.get(agent, & &1)
    else
      []
    end
  end

  defp maybe_agent_values(_agent), do: []

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
