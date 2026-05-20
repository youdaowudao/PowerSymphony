defmodule SymphonyElixir.ProjectProcessManagerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ProjectProcessManager

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

  test "starts a project worker and records pid, port, stdout/stderr paths" do
    test_root = temp_root!("start-worker")
    manager_name = Module.concat(__MODULE__, StartManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{"alpha" => "normal"})})

    assert {:ok, runtime_state} = ProjectProcessManager.start_project(manager_name, "alpha")
    assert runtime_state.status == :running
    assert is_integer(runtime_state.pid)
    assert runtime_state.worker_port == port
    assert %DateTime{} = runtime_state.started_at
    assert File.regular?(runtime_state.stdout_path)
    assert File.regular?(runtime_state.stderr_path)

    entry = fetch_entry!(manager_name, "alpha")
    assert entry.runtime_state.status == :running
    assert entry.runtime_state.pid == runtime_state.pid
    assert entry.runtime_state.worker_port == port
    assert %DateTime{} = entry.runtime_state.started_at
    assert entry.runtime_state.stdout_path == runtime_state.stdout_path
    assert entry.runtime_state.stderr_path == runtime_state.stderr_path

    runtime_dir = control_plane_runtime_dir(test_root, "alpha")
    assert File.read!(Path.join(runtime_dir, "worker.pid")) == Integer.to_string(runtime_state.pid)
    persisted = runtime_dir |> Path.join("runtime.json") |> File.read!() |> Jason.decode!()
    assert persisted["status"] == "running"
    assert persisted["pid"] == runtime_state.pid
    assert persisted["worker_port"] == port
    assert persisted["stdout_path"] == runtime_state.stdout_path
    assert persisted["stderr_path"] == runtime_state.stderr_path

    assert_eventually(fn -> request_ok?(port) end, 80)
  end

  test "stops one project without affecting another running project" do
    test_root = temp_root!("stop-one-project")
    manager_name = Module.concat(__MODULE__, StopManager)
    alpha_port = reserve_tcp_port!()
    beta_port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", alpha_port),
        project_fixture(test_root, "beta", beta_port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)

    start_supervised!(
      {ProjectProcessManager,
       name: manager_name,
       command_builder:
         fake_worker_builder(%{
           "alpha" => "normal",
           "beta" => "normal"
         })}
    )

    assert {:ok, alpha_running} = ProjectProcessManager.start_project(manager_name, "alpha")
    assert {:ok, beta_running} = ProjectProcessManager.start_project(manager_name, "beta")

    assert {:ok, stopped_state} = ProjectProcessManager.stop_project(manager_name, "alpha")
    assert stopped_state.status == :stopped
    assert is_nil(stopped_state.pid)

    alpha_entry = fetch_entry!(manager_name, "alpha")
    beta_entry = fetch_entry!(manager_name, "beta")

    assert alpha_entry.runtime_state.status == :stopped
    assert is_nil(alpha_entry.runtime_state.pid)
    assert beta_entry.runtime_state.status == :running
    assert beta_entry.runtime_state.pid == beta_running.pid
    assert beta_entry.runtime_state.pid != alpha_running.pid
    assert_eventually(fn -> request_ok?(beta_port) end, 80)
  end

  test "restarts a project worker with a new pid" do
    test_root = temp_root!("restart-worker")
    manager_name = Module.concat(__MODULE__, RestartManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{"alpha" => "normal"})})

    assert {:ok, first_state} = ProjectProcessManager.start_project(manager_name, "alpha")
    assert {:ok, restarted_state} = ProjectProcessManager.restart_project(manager_name, "alpha")

    assert restarted_state.status == :running
    assert restarted_state.pid != first_state.pid
    assert fetch_entry!(manager_name, "alpha").runtime_state.pid == restarted_state.pid
    assert_eventually(fn -> request_ok?(port) end, 80)
  end

  test "marks crashed when fake worker exits unexpectedly" do
    test_root = temp_root!("crash-worker")
    manager_name = Module.concat(__MODULE__, CrashManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{"alpha" => "normal"})})

    assert {:ok, running_state} = ProjectProcessManager.start_project(manager_name, "alpha")
    assert {_, 0} = System.cmd("kill", ["-9", Integer.to_string(running_state.pid)])

    assert_eventually(fn ->
      fetch_entry!(manager_name, "alpha").runtime_state.status == :crashed
    end)

    crashed_entry = fetch_entry!(manager_name, "alpha")
    assert crashed_entry.runtime_state.status == :crashed
    assert crashed_entry.runtime_state.exit_code != nil
    assert crashed_entry.runtime_state.exit_reason != nil
  end

  test "marks start_failed when worker command exits during startup" do
    test_root = temp_root!("start-failed")
    manager_name = Module.concat(__MODULE__, StartFailedManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: raw_command_builder("exit 1")})

    assert {:error, :start_failed} = ProjectProcessManager.start_project(manager_name, "alpha")

    entry = fetch_entry!(manager_name, "alpha")
    assert entry.runtime_state.status == :start_failed
    assert is_nil(entry.runtime_state.pid)
    assert entry.runtime_state.exit_code != nil
    assert entry.runtime_state.error_summary != nil
  end

  test "start_link/0 uses the configured default manager name" do
    test_root = temp_root!("direct-start-link")
    manager_name = Module.concat(__MODULE__, DirectStartLinkManager)
    port = reserve_tcp_port!()
    previous_manager_name = Application.get_env(:symphony_elixir, :project_process_manager_name)

    on_exit(fn ->
      restore_app_env(:project_process_manager_name, previous_manager_name)
    end)

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

    assert {:ok, pid} = ProjectProcessManager.start_link()
    assert Process.alive?(pid)
    assert GenServer.whereis(manager_name) == pid
    assert fetch_entry!(manager_name, "alpha").runtime_state.status == :not_started

    GenServer.stop(pid)
  end

  test "marks start_failed with status 0 when startup command exits cleanly" do
    test_root = temp_root!("start-failed-zero-exit")
    manager_name = Module.concat(__MODULE__, ZeroExitStartFailedManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: raw_command_builder("sleep 0.05")})

    assert {:error, :start_failed} = ProjectProcessManager.start_project(manager_name, "alpha")

    entry = fetch_entry!(manager_name, "alpha")
    assert entry.runtime_state.status == :start_failed
    assert entry.runtime_state.exit_code == 0
    assert entry.runtime_state.exit_reason == "worker exited with status 0"
  end

  test "marks start_failed when bash executable is unavailable" do
    test_root = temp_root!("bash-not-found")
    manager_name = Module.concat(__MODULE__, BashNotFoundManager)
    port = reserve_tcp_port!()
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      if previous_path do
        System.put_env("PATH", previous_path)
      else
        System.delete_env("PATH")
      end
    end)

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{"alpha" => "normal"})})

    System.put_env("PATH", "")

    assert {:error, :start_failed} = ProjectProcessManager.start_project(manager_name, "alpha")

    entry = fetch_entry!(manager_name, "alpha")
    assert entry.runtime_state.status == :start_failed
    assert entry.runtime_state.started_at == nil
    assert entry.runtime_state.error_summary == "worker failed to start: :bash_not_found"
  end

  test "startup shell output does not prevent start_failed projection" do
    test_root = temp_root!("startup-output")
    manager_name = Module.concat(__MODULE__, StartupOutputManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: raw_command_builder("printf boot-noise")})

    assert {:error, :start_failed} = ProjectProcessManager.start_project(manager_name, "alpha")

    entry = fetch_entry!(manager_name, "alpha")
    assert entry.runtime_state.status == :start_failed
    assert entry.runtime_state.exit_code == 0
    assert entry.runtime_state.exit_reason == "worker exited with status 0"
    assert entry.runtime_state.error_summary == "worker command exited during startup"
  end

  test "startup shell parse errors surface as start_failed" do
    test_root = temp_root!("startup-parse-error")
    manager_name = Module.concat(__MODULE__, StartupParseErrorManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: raw_command_builder("(")})

    assert {:error, :start_failed} = ProjectProcessManager.start_project(manager_name, "alpha")

    entry = fetch_entry!(manager_name, "alpha")
    assert entry.runtime_state.status == :start_failed
    assert entry.runtime_state.exit_code == 2
    assert entry.runtime_state.exit_reason == "worker exited with status 2"
    assert File.read!(entry.runtime_state.stderr_path) =~ "syntax error"
  end

  test "startup data message before grace timeout recurses and can still reach running" do
    test_root = temp_root!("startup-data-recursion")
    manager_name = Module.concat(__MODULE__, StartupDataRecursionManager)
    port = reserve_tcp_port!()
    runtime_dir = control_plane_runtime_dir(test_root, "alpha")

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: raw_command_builder("sleep 2")})

    manager_pid = GenServer.whereis(manager_name)
    existing_ports = :erlang.ports()
    task = Task.async(fn -> ProjectProcessManager.start_project(manager_name, "alpha") end)
    os_pid = await_worker_pid!(runtime_dir)
    startup_port = await_port_for_os_pid!(existing_ports, os_pid)

    send(manager_pid, {startup_port, {:data, "boot-noise"}})

    assert {:ok, runtime_state} = Task.await(task, 3_000)
    assert runtime_state.status == :running
    assert is_integer(runtime_state.pid)

    assert {:ok, stopped_state} = ProjectProcessManager.stop_project(manager_name, "alpha")
    assert stopped_state.status == :stopped
  end

  test "closed port during startup falls back to await_exit_status recursion" do
    test_root = temp_root!("startup-closed-port")
    manager_name = Module.concat(__MODULE__, StartupClosedPortManager)
    port = reserve_tcp_port!()
    runtime_dir = control_plane_runtime_dir(test_root, "alpha")

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: raw_command_builder("sleep 5")})

    manager_pid = GenServer.whereis(manager_name)
    existing_ports = :erlang.ports()
    task = Task.async(fn -> ProjectProcessManager.start_project(manager_name, "alpha") end)
    os_pid = await_worker_pid!(runtime_dir)
    startup_port = await_port_for_os_pid!(existing_ports, os_pid)

    send(manager_pid, {startup_port, {:data, "prelude"}})
    Process.sleep(30)
    Port.close(startup_port)
    send(manager_pid, {startup_port, {:data, "after-close"}})
    send(manager_pid, {startup_port, {:exit_status, 41}})

    assert {:error, :start_failed} = Task.await(task, 3_000)

    entry = fetch_entry!(manager_name, "alpha")
    assert entry.runtime_state.status == :start_failed
    assert entry.runtime_state.exit_code == 41
    assert entry.runtime_state.exit_reason == "worker exited with status 41"

    kill_pid(os_pid)
  end

  test "timeout grace can consume a late exit_status message" do
    test_root = temp_root!("startup-timeout-exit-status")
    manager_name = Module.concat(__MODULE__, StartupTimeoutExitStatusManager)
    port = reserve_tcp_port!()
    runtime_dir = control_plane_runtime_dir(test_root, "alpha")

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: raw_command_builder("sleep 5")})

    manager_pid = GenServer.whereis(manager_name)
    existing_ports = :erlang.ports()
    task = Task.async(fn -> ProjectProcessManager.start_project(manager_name, "alpha") end)
    os_pid = await_worker_pid!(runtime_dir)
    startup_port = await_port_for_os_pid!(existing_ports, os_pid)

    Process.sleep(1_050)
    send(manager_pid, {startup_port, {:exit_status, 23}})

    assert {:error, :start_failed} = Task.await(task, 3_000)

    entry = fetch_entry!(manager_name, "alpha")
    assert entry.runtime_state.status == :start_failed
    assert entry.runtime_state.exit_code == 23
    assert entry.runtime_state.exit_reason == "worker exited with status 23"

    kill_pid(os_pid)
  end

  test "timeout grace can consume late data and recurse back into startup wait" do
    test_root = temp_root!("startup-timeout-data")
    manager_name = Module.concat(__MODULE__, StartupTimeoutDataManager)
    port = reserve_tcp_port!()
    runtime_dir = control_plane_runtime_dir(test_root, "alpha")

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: raw_command_builder("sleep 3")})

    manager_pid = GenServer.whereis(manager_name)
    existing_ports = :erlang.ports()
    task = Task.async(fn -> ProjectProcessManager.start_project(manager_name, "alpha") end)
    os_pid = await_worker_pid!(runtime_dir)
    startup_port = await_port_for_os_pid!(existing_ports, os_pid)

    Process.sleep(1_050)
    send(manager_pid, {startup_port, {:data, "late-boot-noise"}})

    assert {:ok, runtime_state} = Task.await(task, 3_000)
    assert runtime_state.status == :running

    assert {:ok, stopped_state} = ProjectProcessManager.stop_project(manager_name, "alpha")
    assert stopped_state.status == :stopped
  end

  test "timeout fallback awaits exit_status after the port stops being open" do
    test_root = temp_root!("startup-timeout-closed-port")
    manager_name = Module.concat(__MODULE__, StartupTimeoutClosedPortManager)
    port = reserve_tcp_port!()
    runtime_dir = control_plane_runtime_dir(test_root, "alpha")

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: raw_command_builder("sleep 5")})

    manager_pid = GenServer.whereis(manager_name)
    existing_ports = :erlang.ports()
    task = Task.async(fn -> ProjectProcessManager.start_project(manager_name, "alpha") end)
    os_pid = await_worker_pid!(runtime_dir)
    startup_port = await_port_for_os_pid!(existing_ports, os_pid)

    Process.sleep(1_050)
    Port.close(startup_port)
    send(manager_pid, {startup_port, {:exit_status, 31}})

    assert {:error, :start_failed} = Task.await(task, 3_000)

    entry = fetch_entry!(manager_name, "alpha")
    assert entry.runtime_state.status == :start_failed
    assert entry.runtime_state.exit_code == 31
    assert entry.runtime_state.exit_reason == "worker exited with status 31"

    kill_pid(os_pid)
  end

  test "startup detects closed port before grace timeout and awaits injected exit_status" do
    test_root = temp_root!("startup-closed-port-exit-status")
    manager_name = Module.concat(__MODULE__, StartupClosedPortExitStatusManager)
    port = reserve_tcp_port!()
    runtime_dir = control_plane_runtime_dir(test_root, "alpha")

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: raw_command_builder("sleep 5")})

    manager_pid = GenServer.whereis(manager_name)
    existing_ports = :erlang.ports()
    task = Task.async(fn -> ProjectProcessManager.start_project(manager_name, "alpha") end)
    os_pid = await_worker_pid!(runtime_dir)
    startup_port = await_port_for_os_pid!(existing_ports, os_pid)

    Port.close(startup_port)
    send(manager_pid, {startup_port, {:exit_status, 52}})

    assert {:error, :start_failed} = Task.await(task, 3_000)

    entry = fetch_entry!(manager_name, "alpha")
    assert entry.runtime_state.status == :start_failed
    assert entry.runtime_state.exit_code == 52
    assert entry.runtime_state.exit_reason == "worker exited with status 52"

    kill_pid(os_pid)
  end

  test "startup marks start_failed when worker pid dies before the startup port closes" do
    test_root = temp_root!("startup-dead-os-pid")
    manager_name = Module.concat(__MODULE__, StartupDeadOsPidManager)
    port = reserve_tcp_port!()
    runtime_dir = control_plane_runtime_dir(test_root, "alpha")

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: raw_command_builder("sleep 5")})

    task = Task.async(fn -> ProjectProcessManager.start_project(manager_name, "alpha") end)
    os_pid = await_worker_pid!(runtime_dir)

    assert {_, 0} = System.cmd("kill", ["-9", Integer.to_string(os_pid)])
    assert {:error, :start_failed} = Task.await(task, 3_000)

    entry = fetch_entry!(manager_name, "alpha")
    assert entry.runtime_state.status == :start_failed
    assert is_nil(entry.runtime_state.pid)
  end

  test "startup timeout fallback can recurse on await_exit_status data and then time out" do
    test_root = temp_root!("startup-timeout-await-exit-status-data")
    manager_name = Module.concat(__MODULE__, StartupTimeoutAwaitExitStatusDataManager)
    port = reserve_tcp_port!()
    runtime_dir = control_plane_runtime_dir(test_root, "alpha")

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: raw_command_builder("sleep 5")})

    manager_pid = GenServer.whereis(manager_name)
    existing_ports = :erlang.ports()
    task = Task.async(fn -> ProjectProcessManager.start_project(manager_name, "alpha") end)
    os_pid = await_worker_pid!(runtime_dir)
    startup_port = await_port_for_os_pid!(existing_ports, os_pid)

    Process.sleep(1_050)
    Port.close(startup_port)
    Process.sleep(150)
    send(manager_pid, {startup_port, {:data, "await-exit-status-noise"}})

    assert {:error, :start_failed} = Task.await(task, 3_000)

    entry = fetch_entry!(manager_name, "alpha")
    assert entry.runtime_state.status == :start_failed
    assert entry.runtime_state.exit_code == nil
    assert entry.runtime_state.exit_reason == nil

    kill_pid(os_pid)
  end

  test "start_project generates a missing workflow before starting the worker" do
    test_root = temp_root!("generate-before-start")
    manager_name = Module.concat(__MODULE__, GenerateBeforeStartManager)
    port = reserve_tcp_port!()
    workflow_source = Path.join(test_root, "shared/WORKFLOW.md")

    File.mkdir_p!(Path.dirname(workflow_source))

    write_workflow_file!(workflow_source,
      tracker_project_slug: "source-project",
      workspace_root: Path.join(test_root, "shared-workspace"),
      hook_after_create: "git clone --depth 1 https://example.com/source.git ."
    )

    project =
      project_fixture(test_root, "alpha", port,
        workflow?: false,
        workflow_source: workflow_source,
        project_slug: "slug-alpha",
        repo_url: "https://example.com/alpha.git"
      )

    config_path = write_projects_config!(test_root, [project])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{"alpha" => "normal"})})

    refute File.regular?(project.workflow_generated)
    assert fetch_entry!(manager_name, "alpha").runtime_state.status == :not_started

    assert {:ok, _running_state} = ProjectProcessManager.start_project(manager_name, "alpha")
    assert File.regular?(project.workflow_generated)

    assert {:ok, %{config: generated_config}} = Workflow.load(project.workflow_generated)
    assert get_in(generated_config, ["tracker", "project_slug"]) == "slug-alpha"
    assert get_in(generated_config, ["workspace", "root"]) == project.workspace_root
    assert get_in(generated_config, ["hooks", "after_create"]) =~ "https://example.com/alpha.git"
  end

  test "projects with invalid static config or missing workflow generation inputs project as config_invalid" do
    missing_root = temp_root!("missing-workflow")
    manager_name = Module.concat(__MODULE__, InvalidProjectionManager)
    port = reserve_tcp_port!()

    missing_config_path =
      write_projects_config!(missing_root, [
        project_fixture(missing_root, "alpha", port,
          workflow?: false,
          source_workflow?: false,
          workflow_source: nil,
          project_slug: nil,
          repo_url: nil
        )
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, missing_config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{})})

    missing_entry = fetch_entry!(manager_name, "alpha")
    assert missing_entry.runtime_state.status == :config_invalid
    assert {:error, :config_invalid} = ProjectProcessManager.start_project(manager_name, "alpha")

    missing_source_root = temp_root!("missing-workflow-source-file")

    missing_source_config_path =
      write_projects_config!(missing_source_root, [
        project_fixture(missing_source_root, "alpha", port,
          workflow?: false,
          source_workflow?: false,
          workflow_source: Path.join(missing_source_root, "alpha/source/WORKFLOW.md")
        )
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, missing_source_config_path)

    missing_source_registry = ProjectProcessManager.project_registry(manager_name)
    missing_source_entry = find_entry!(missing_source_registry, "alpha")
    assert missing_source_entry.validation_result == :valid
    assert missing_source_entry.runtime_state.status == :config_invalid
    assert {:error, :config_invalid} = ProjectProcessManager.start_project(manager_name, "alpha")

    invalid_root = temp_root!("invalid-static")
    invalid_config_path = write_invalid_projects_config!(invalid_root)

    Application.put_env(:symphony_elixir, :project_config_path_override, invalid_config_path)

    invalid_registry = ProjectProcessManager.project_registry(manager_name)
    [invalid_entry] = invalid_registry.entries
    assert invalid_entry.validation_result == :invalid
    assert invalid_entry.runtime_state.status == :config_invalid
  end

  test "workflow generation failures stay distinct from static config_invalid" do
    test_root = temp_root!("workflow-generation-failure")
    manager_name = Module.concat(__MODULE__, WorkflowGenerationFailureManager)
    port = reserve_tcp_port!()

    project =
      project_fixture(test_root, "alpha", port,
        workflow?: false,
        project_slug: "slug-alpha",
        repo_url: "https://example.com/alpha.git"
      )

    File.write!(project.workflow_source, "---\n[]\n---\nPrompt body\n")

    config_path = write_projects_config!(test_root, [project])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{})})

    entry = fetch_entry!(manager_name, "alpha")
    assert entry.validation_result == :valid
    assert entry.runtime_state.status == :not_started
    refute File.regular?(project.workflow_generated)

    assert {:error, {:workflow_generation_failed, :workflow_front_matter_not_a_map}} =
             ProjectProcessManager.start_project(manager_name, "alpha")

    failed_entry = fetch_entry!(manager_name, "alpha")
    assert failed_entry.runtime_state.status == :not_started
    refute File.regular?(project.workflow_generated)
  end

  test "projected config_invalid and disabled states do not persist in internal runtime state" do
    test_root = temp_root!("projected-states")
    manager_name = Module.concat(__MODULE__, ProjectedStatesManager)
    alpha_port = reserve_tcp_port!()
    beta_port = reserve_tcp_port!()

    alpha =
      project_fixture(test_root, "alpha", alpha_port,
        workflow?: false,
        source_workflow?: false,
        workflow_source: nil,
        project_slug: nil,
        repo_url: nil
      )

    beta = project_fixture(test_root, "beta", beta_port, enabled: false)

    config_path = write_projects_config!(test_root, [alpha, beta])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)

    start_supervised!(
      {ProjectProcessManager,
       name: manager_name,
       command_builder:
         fake_worker_builder(%{
           "alpha" => "normal",
           "beta" => "normal"
         })}
    )

    assert fetch_entry!(manager_name, "alpha").runtime_state.status == :config_invalid
    assert fetch_entry!(manager_name, "beta").runtime_state.status == :disabled

    internal_state = :sys.get_state(manager_name)
    assert internal_state.runtimes["alpha"].status == :not_started
    assert internal_state.runtimes["beta"].status == :not_started

    alpha_valid = project_fixture(test_root, "alpha", alpha_port)
    write_projects_config!(test_root, [%{alpha_valid | enabled: true}, %{beta | enabled: true}])

    assert {:ok, alpha_state} = ProjectProcessManager.start_project(manager_name, "alpha")
    assert {:ok, beta_state} = ProjectProcessManager.start_project(manager_name, "beta")
    assert alpha_state.status == :running
    assert beta_state.status == :running
  end

  test "registry preserves runtime status for valid entries that do not match projected overrides" do
    test_root = temp_root!("projected-default-status")
    manager_name = Module.concat(__MODULE__, ProjectedDefaultStatusManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{})})

    :sys.replace_state(manager_name, fn state ->
      runtime_state =
        state.runtimes["alpha"]
        |> Map.put(:status, :stopped)
        |> Map.put(:pid, nil)
        |> Map.put(:worker_port, port)

      %{state | runtimes: Map.put(state.runtimes, "alpha", runtime_state)}
    end)

    entry = fetch_entry!(manager_name, "alpha")
    assert entry.validation_result == :valid
    assert entry.normalized_config.enabled == true
    assert entry.runtime_state.status == :stopped
  end

  test "explicit manager calls avoid global env routing collisions" do
    test_root = temp_root!("manager-routing")
    manager_name = Module.concat(__MODULE__, RoutingManager)
    wrong_manager = Module.concat(__MODULE__, WrongRoutingManager)
    port = reserve_tcp_port!()

    config_path = write_projects_config!(test_root, [project_fixture(test_root, "alpha", port)])
    previous_manager_name = Application.get_env(:symphony_elixir, :project_process_manager_name)

    on_exit(fn ->
      restore_app_env(:project_process_manager_name, previous_manager_name)
    end)

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)

    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{"alpha" => "normal"})})

    Application.put_env(:symphony_elixir, :project_process_manager_name, wrong_manager)

    assert {:ok, state} = ProjectProcessManager.start_project(manager_name, "alpha")
    assert state.worker_port == port
    assert ProjectProcessManager.project_registry(manager_name) |> find_entry!("alpha") |> Map.get(:runtime_state) |> Map.get(:worker_port) == port
  end

  test "default-name API routes through configured manager name and fallback registry works without server" do
    test_root = temp_root!("default-api")
    configured_name = Module.concat(__MODULE__, DefaultApiManager)
    port = reserve_tcp_port!()
    previous_manager_name = Application.get_env(:symphony_elixir, :project_process_manager_name)

    on_exit(fn ->
      restore_app_env(:project_process_manager_name, previous_manager_name)
    end)

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    Application.put_env(:symphony_elixir, :project_process_manager_name, configured_name)

    fallback_entry = ProjectProcessManager.project_registry() |> find_entry!("alpha")
    assert fallback_entry.runtime_state.status == :not_started
    assert fallback_entry.runtime_state.worker_port == port

    fallback_display_entry = ProjectProcessManager.project_registry_for_display() |> find_entry!("alpha")
    assert fallback_display_entry.runtime_state.status == :not_started
    assert fallback_display_entry.runtime_state.pid == nil
    assert fallback_display_entry.runtime_state.worker_port == port
    assert fallback_display_entry.runtime_state.run_summaries == []

    start_supervised!({ProjectProcessManager, command_builder: fake_worker_builder(%{"alpha" => "normal"})})

    assert {:ok, started_state} = ProjectProcessManager.start_project("alpha")
    assert started_state.status == :running
    assert started_state.worker_port == port

    assert {:ok, stopped_state} = ProjectProcessManager.stop_project("alpha")
    assert stopped_state.status == :stopped

    assert {:ok, restarted_state} = ProjectProcessManager.restart_project("alpha")
    assert restarted_state.status == :running
    assert restarted_state.pid != started_state.pid
  end

  test "worker_port_for_project default wrapper uses configured manager and falls back to config when not started" do
    test_root = temp_root!("worker-port-default-wrapper")
    configured_name = Module.concat(__MODULE__, WorkerPortDefaultApiManager)
    port = reserve_tcp_port!()
    previous_manager_name = Application.get_env(:symphony_elixir, :project_process_manager_name)

    on_exit(fn ->
      restore_app_env(:project_process_manager_name, previous_manager_name)
    end)

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    Application.put_env(:symphony_elixir, :project_process_manager_name, configured_name)

    start_supervised!({ProjectProcessManager, command_builder: fake_worker_builder(%{"alpha" => "normal"})})

    assert {:ok, ^port} = ProjectProcessManager.worker_port_for_project("alpha")
    assert {:error, :not_found} = ProjectProcessManager.worker_port_for_project("missing")

    assert {:ok, runtime_state} = ProjectProcessManager.start_project("alpha")
    assert runtime_state.status == :running
    assert runtime_state.worker_port == port

    assert {:ok, ^port} = ProjectProcessManager.worker_port_for_project("alpha")
  end

  test "worker_port_for_project returns worker_port_unavailable when config exists but port is invalid" do
    test_root = temp_root!("worker-port-unavailable")
    manager_name = Module.concat(__MODULE__, WorkerPortUnavailableManager)
    config_path = write_invalid_projects_config!(test_root)

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{})})

    assert {:error, :worker_port_unavailable} =
             ProjectProcessManager.worker_port_for_project(manager_name, "alpha")
  end

  test "running worker health success keeps lifecycle running and records timestamps" do
    test_root = temp_root!("health-success")
    manager_name = Module.concat(__MODULE__, HealthSuccessManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    write_workflow_file!(Workflow.workflow_file_path(), control_plane: %{health_check_timeout_ms: 50})
    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)

    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{"alpha" => "normal"})})

    assert {:ok, runtime_state} = ProjectProcessManager.start_project(manager_name, "alpha")
    check_at = DateTime.utc_now() |> DateTime.truncate(:second)
    seen_at = DateTime.add(check_at, 1, :second)

    targets = ProjectProcessManager.health_poll_targets(manager_name)
    assert [%{project_id: "alpha", worker_port: ^port, health_check_timeout_ms: 50}] = targets

    assert :ok = ProjectProcessManager.record_health_success(manager_name, "alpha", seen_at)

    entry = fetch_entry!(manager_name, "alpha")
    assert entry.runtime_state.status == :running
    assert entry.runtime_state.pid == runtime_state.pid
    assert entry.runtime_state.health_status == :healthy
    assert entry.runtime_state.last_seen_at == seen_at
    assert entry.runtime_state.last_health_check_at == seen_at
    assert entry.runtime_state.last_error == nil
    assert entry.runtime_state.health_check_timeout_ms == 50
  end

  test "default-name health APIs route through configured manager name" do
    test_root = temp_root!("default-health-api")
    configured_name = Module.concat(__MODULE__, DefaultHealthApiManager)
    port = reserve_tcp_port!()
    previous_manager_name = Application.get_env(:symphony_elixir, :project_process_manager_name)

    on_exit(fn ->
      restore_app_env(:project_process_manager_name, previous_manager_name)
    end)

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    write_workflow_file!(Workflow.workflow_file_path(), control_plane: %{health_check_timeout_ms: 50})
    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    Application.put_env(:symphony_elixir, :project_process_manager_name, configured_name)

    start_supervised!({ProjectProcessManager, command_builder: fake_worker_builder(%{"alpha" => "normal"})})

    assert {:ok, runtime_state} = ProjectProcessManager.start_project("alpha")
    assert runtime_state.status == :running

    assert [%{project_id: "alpha", worker_port: ^port, health_check_timeout_ms: 50}] =
             ProjectProcessManager.health_poll_targets()

    seen_at = DateTime.utc_now() |> DateTime.truncate(:second)
    assert :ok = ProjectProcessManager.record_health_success("alpha", seen_at)

    entry = fetch_entry!(configured_name, "alpha")
    assert entry.runtime_state.status == :running
    assert entry.runtime_state.last_seen_at == seen_at
    assert entry.runtime_state.health_status == :healthy
  end

  test "default-name health failure API routes through configured manager name" do
    test_root = temp_root!("default-health-failure-api")
    configured_name = Module.concat(__MODULE__, DefaultHealthFailureApiManager)
    port = reserve_tcp_port!()
    previous_manager_name = Application.get_env(:symphony_elixir, :project_process_manager_name)

    on_exit(fn ->
      restore_app_env(:project_process_manager_name, previous_manager_name)
    end)

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    write_workflow_file!(Workflow.workflow_file_path(), control_plane: %{health_check_timeout_ms: 50})
    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    Application.put_env(:symphony_elixir, :project_process_manager_name, configured_name)

    start_supervised!({ProjectProcessManager, command_builder: fake_worker_builder(%{"alpha" => "normal"})})

    assert {:ok, runtime_state} = ProjectProcessManager.start_project("alpha")
    assert runtime_state.status == :running

    baseline_seen_at = DateTime.utc_now() |> DateTime.truncate(:second)
    assert :ok = ProjectProcessManager.record_health_success("alpha", baseline_seen_at)

    failure_at = DateTime.add(baseline_seen_at, 55, :millisecond)
    assert :ok = ProjectProcessManager.record_health_failure("alpha", failure_at, "request timed out")

    entry = fetch_entry!(configured_name, "alpha")
    assert entry.runtime_state.status == :unreachable
    assert entry.runtime_state.health_status == :unreachable
    assert entry.runtime_state.last_error == "request timed out"
  end

  test "running worker failure after timeout projects as unreachable and later success returns to running" do
    test_root = temp_root!("health-unreachable")
    manager_name = Module.concat(__MODULE__, HealthUnreachableManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    write_workflow_file!(Workflow.workflow_file_path(), control_plane: %{health_check_timeout_ms: 50})
    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)

    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{"alpha" => "normal"})})

    assert {:ok, runtime_state} = ProjectProcessManager.start_project(manager_name, "alpha")
    baseline_seen_at = DateTime.utc_now()
    assert :ok = ProjectProcessManager.record_health_success(manager_name, "alpha", baseline_seen_at)

    before_timeout = DateTime.add(baseline_seen_at, 49, :millisecond)

    assert :ok =
             ProjectProcessManager.record_health_failure(
               manager_name,
               "alpha",
               before_timeout,
               "connection refused"
             )

    running_entry = fetch_entry!(manager_name, "alpha")
    assert running_entry.runtime_state.status == :running
    assert running_entry.runtime_state.health_status != :unreachable
    assert running_entry.runtime_state.pid == runtime_state.pid

    after_timeout = DateTime.add(baseline_seen_at, 55, :millisecond)

    assert :ok =
             ProjectProcessManager.record_health_failure(
               manager_name,
               "alpha",
               after_timeout,
               "request timed out"
             )

    unreachable_entry = fetch_entry!(manager_name, "alpha")
    assert unreachable_entry.runtime_state.status == :unreachable
    assert unreachable_entry.runtime_state.health_status == :unreachable
    assert unreachable_entry.runtime_state.last_health_check_at == after_timeout
    assert unreachable_entry.runtime_state.last_seen_at == baseline_seen_at
    assert unreachable_entry.runtime_state.last_error == "request timed out"

    assert [%{project_id: "alpha", worker_port: ^port, health_check_timeout_ms: 50}] =
             ProjectProcessManager.health_poll_targets(manager_name)

    recovery_at = DateTime.add(after_timeout, 1, :second)
    assert :ok = ProjectProcessManager.record_health_success(manager_name, "alpha", recovery_at)

    recovered_entry = fetch_entry!(manager_name, "alpha")
    assert recovered_entry.runtime_state.status == :running
    assert recovered_entry.runtime_state.health_status == :healthy
    assert recovered_entry.runtime_state.last_seen_at == recovery_at
    assert recovered_entry.runtime_state.last_health_check_at == recovery_at
    assert recovered_entry.runtime_state.last_error == nil
  end

  test "health updates do not overwrite stopped crashed start_failed disabled or config_invalid states" do
    test_root = temp_root!("health-no-overwrite")
    manager_name = Module.concat(__MODULE__, HealthNoOverwriteManager)
    alpha_port = reserve_tcp_port!()
    beta_port = reserve_tcp_port!()
    gamma_port = reserve_tcp_port!()
    delta_port = reserve_tcp_port!()
    epsilon_port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", alpha_port),
        project_fixture(test_root, "beta", beta_port),
        project_fixture(test_root, "gamma", gamma_port),
        project_fixture(test_root, "delta", delta_port, enabled: false),
        project_fixture(test_root, "epsilon", epsilon_port,
          workflow?: false,
          source_workflow?: false,
          workflow_source: nil,
          project_slug: nil,
          repo_url: nil
        )
      ])

    write_workflow_file!(Workflow.workflow_file_path(), control_plane: %{health_check_timeout_ms: 50})
    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)

    start_supervised!(
      {ProjectProcessManager,
       name: manager_name,
       command_builder: fn entry ->
         case entry.project_id do
           "alpha" -> fake_worker_builder(%{"alpha" => "normal"}).(entry)
           "beta" -> fake_worker_builder(%{"beta" => "normal"}).(entry)
           "gamma" -> "exit 1"
         end
       end}
    )

    assert {:ok, _} = ProjectProcessManager.start_project(manager_name, "alpha")
    assert {:ok, _} = ProjectProcessManager.stop_project(manager_name, "alpha")
    assert {:ok, _} = ProjectProcessManager.start_project(manager_name, "beta")
    assert {:error, :start_failed} = ProjectProcessManager.start_project(manager_name, "gamma")

    failed_at = DateTime.utc_now() |> DateTime.truncate(:second)

    for project_id <- ~w(alpha beta gamma delta epsilon) do
      assert :ok =
               ProjectProcessManager.record_health_failure(
                 manager_name,
                 project_id,
                 DateTime.add(failed_at, 1, :second),
                 "#{project_id}-failure"
               )

      assert :ok =
               ProjectProcessManager.record_health_success(
                 manager_name,
                 project_id,
                 DateTime.add(failed_at, 2, :second)
               )
    end

    assert fetch_entry!(manager_name, "alpha").runtime_state.status == :stopped
    assert fetch_entry!(manager_name, "beta").runtime_state.status == :running
    assert fetch_entry!(manager_name, "gamma").runtime_state.status == :start_failed
    assert fetch_entry!(manager_name, "delta").runtime_state.status == :disabled
    assert fetch_entry!(manager_name, "epsilon").runtime_state.status == :config_invalid
  end

  test "health updates do not overwrite a real crashed worker back to running" do
    test_root = temp_root!("health-real-crashed")
    manager_name = Module.concat(__MODULE__, HealthRealCrashedManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    write_workflow_file!(Workflow.workflow_file_path(), control_plane: %{health_check_timeout_ms: 50})
    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)

    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{"alpha" => "normal"})})

    assert {:ok, running_state} = ProjectProcessManager.start_project(manager_name, "alpha")
    assert {_, 0} = System.cmd("kill", ["-9", Integer.to_string(running_state.pid)])

    assert_eventually(fn ->
      fetch_entry!(manager_name, "alpha").runtime_state.status == :crashed
    end)

    crashed_entry = fetch_entry!(manager_name, "alpha")
    assert crashed_entry.runtime_state.status == :crashed
    assert crashed_entry.runtime_state.pid == nil

    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
    assert :ok = ProjectProcessManager.record_health_success(manager_name, "alpha", observed_at)

    still_crashed_entry = fetch_entry!(manager_name, "alpha")
    assert still_crashed_entry.runtime_state.status == :crashed
    refute still_crashed_entry.runtime_state.status == :running
    assert still_crashed_entry.runtime_state.last_health_check_at == observed_at
    assert still_crashed_entry.runtime_state.last_seen_at == nil
  end

  test "health poll targets ignore invalid entries and missing health updates are no-ops" do
    test_root = temp_root!("health-invalid-entry")
    manager_name = Module.concat(__MODULE__, HealthInvalidEntryManager)
    config_path = write_missing_id_projects_config!(test_root)

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{})})

    assert ProjectProcessManager.health_poll_targets(manager_name) == []

    state_before = :sys.get_state(manager_name)
    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

    assert :ok = ProjectProcessManager.record_health_success(manager_name, "missing-project", observed_at)
    assert :ok = ProjectProcessManager.record_health_failure(manager_name, "missing-project", observed_at, "boom")

    assert :sys.get_state(manager_name) == state_before
  end

  test "loads persisted health statuses and times out running workers without a reference timestamp" do
    test_root = temp_root!("persisted-health-statuses")
    manager_name = Module.concat(__MODULE__, PersistedHealthStatusesManager)

    projects = [
      project_fixture(test_root, "alpha", reserve_tcp_port!()),
      project_fixture(test_root, "beta", reserve_tcp_port!()),
      project_fixture(test_root, "gamma", reserve_tcp_port!()),
      project_fixture(test_root, "delta", reserve_tcp_port!())
    ]

    config_path = write_projects_config!(test_root, projects)
    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)

    Enum.each(projects, fn project ->
      runtime_dir = control_plane_runtime_dir(test_root, project.id)
      File.mkdir_p!(runtime_dir)
      File.write!(Path.join(runtime_dir, "worker.stdout.log"), "")
      File.write!(Path.join(runtime_dir, "worker.stderr.log"), "")
    end)

    write_runtime_json!(test_root, "alpha", %{
      status: "running",
      pid: nil,
      worker_port: Enum.at(projects, 0).worker_port,
      started_at: nil,
      exit_code: nil,
      exit_reason: nil,
      stdout_path: Path.join(control_plane_runtime_dir(test_root, "alpha"), "worker.stdout.log"),
      stderr_path: Path.join(control_plane_runtime_dir(test_root, "alpha"), "worker.stderr.log"),
      error_summary: nil,
      health_status: "healthy",
      last_seen_at: nil,
      last_health_check_at: DateTime.utc_now() |> DateTime.truncate(:second),
      last_error: nil,
      health_check_timeout_ms: 50
    })

    write_runtime_json!(test_root, "beta", %{
      status: "running",
      pid: nil,
      worker_port: Enum.at(projects, 1).worker_port,
      started_at: nil,
      exit_code: nil,
      exit_reason: nil,
      stdout_path: Path.join(control_plane_runtime_dir(test_root, "beta"), "worker.stdout.log"),
      stderr_path: Path.join(control_plane_runtime_dir(test_root, "beta"), "worker.stderr.log"),
      error_summary: nil,
      health_status: "degraded",
      last_seen_at: nil,
      last_health_check_at: nil,
      last_error: nil,
      health_check_timeout_ms: 50
    })

    write_runtime_json!(test_root, "gamma", %{
      status: "running",
      pid: nil,
      worker_port: Enum.at(projects, 2).worker_port,
      started_at: nil,
      exit_code: nil,
      exit_reason: nil,
      stdout_path: Path.join(control_plane_runtime_dir(test_root, "gamma"), "worker.stdout.log"),
      stderr_path: Path.join(control_plane_runtime_dir(test_root, "gamma"), "worker.stderr.log"),
      error_summary: nil,
      health_status: "mystery",
      last_seen_at: nil,
      last_health_check_at: nil,
      last_error: nil,
      health_check_timeout_ms: 50
    })

    write_runtime_json!(test_root, "delta", %{
      status: "running",
      pid: nil,
      worker_port: Enum.at(projects, 3).worker_port,
      started_at: nil,
      exit_code: nil,
      exit_reason: nil,
      stdout_path: Path.join(control_plane_runtime_dir(test_root, "delta"), "worker.stdout.log"),
      stderr_path: Path.join(control_plane_runtime_dir(test_root, "delta"), "worker.stderr.log"),
      error_summary: nil,
      health_status: "unknown",
      last_seen_at: nil,
      last_health_check_at: nil,
      last_error: nil,
      health_check_timeout_ms: 50
    })

    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{})})

    assert fetch_entry!(manager_name, "alpha").runtime_state.health_status == :healthy
    assert fetch_entry!(manager_name, "beta").runtime_state.health_status == :degraded
    assert fetch_entry!(manager_name, "gamma").runtime_state.health_status == :unknown

    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

    assert :ok =
             ProjectProcessManager.record_health_failure(
               manager_name,
               "delta",
               observed_at,
               "delta timeout"
             )

    delta_entry = fetch_entry!(manager_name, "delta")
    assert delta_entry.runtime_state.status == :unreachable
    assert delta_entry.runtime_state.health_status == :unreachable
    assert delta_entry.runtime_state.last_seen_at == nil
    assert delta_entry.runtime_state.last_error == "delta timeout"
  end

  test "health metadata persists and reloads from runtime.json" do
    test_root = temp_root!("health-persist")
    manager_name = Module.concat(__MODULE__, HealthPersistManager)
    reloaded_manager = Module.concat(__MODULE__, HealthPersistReloadedManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    write_workflow_file!(Workflow.workflow_file_path(), control_plane: %{health_check_timeout_ms: 250})
    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)

    manager_pid =
      start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{"alpha" => "normal"})})

    assert {:ok, _runtime_state} = ProjectProcessManager.start_project(manager_name, "alpha")
    failure_at = DateTime.utc_now() |> DateTime.truncate(:second)

    assert :ok =
             ProjectProcessManager.record_health_failure(
               manager_name,
               "alpha",
               DateTime.add(failure_at, 300, :millisecond),
               "request timed out"
             )

    runtime_dir = control_plane_runtime_dir(test_root, "alpha")
    persisted = runtime_dir |> Path.join("runtime.json") |> File.read!() |> Jason.decode!()
    assert persisted["status"] == "running"
    assert persisted["health_status"] == "unreachable"
    assert persisted["last_health_check_at"] != nil
    assert persisted["last_error"] == "request timed out"
    assert persisted["health_check_timeout_ms"] == 250

    GenServer.stop(manager_pid)

    start_supervised!(%{
      id: reloaded_manager,
      start:
        {ProjectProcessManager, :start_link,
         [
           [
             name: reloaded_manager,
             command_builder: fake_worker_builder(%{})
           ]
         ]},
      restart: :temporary
    })

    entry = fetch_entry!(reloaded_manager, "alpha")
    assert entry.runtime_state.status == :unreachable
    assert entry.runtime_state.health_status == :unreachable
    assert %DateTime{} = entry.runtime_state.last_health_check_at
    assert entry.runtime_state.last_error == "request timed out"
    assert entry.runtime_state.health_check_timeout_ms == 250
  end

  test "stopped worker clears stale run summaries" do
    test_root = temp_root!("stop-clears-run-summaries")
    manager_name = Module.concat(__MODULE__, StopClearsRunSummariesManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    write_workflow_file!(Workflow.workflow_file_path(), control_plane: %{health_check_timeout_ms: 50})
    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)

    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{"alpha" => "normal"})})
    assert {:ok, _runtime_state} = ProjectProcessManager.start_project(manager_name, "alpha")

    running_entry =
      await_display_entry!(manager_name, "alpha", fn entry ->
        entry.runtime_state.status == :running and entry.runtime_state.run_summaries != []
      end)

    assert running_entry.runtime_state.run_summaries != []

    assert {:ok, _stopped_state} = ProjectProcessManager.stop_project(manager_name, "alpha")

    stopped_entry = fetch_display_entry!(manager_name, "alpha")
    assert stopped_entry.runtime_state.status == :stopped
    assert stopped_entry.runtime_state.run_summaries == []
  end

  test "default project registry read does not refresh run summaries" do
    test_root = temp_root!("registry-without-run-summaries")
    manager_name = Module.concat(__MODULE__, RegistryWithoutRunSummariesManager)
    port = reserve_tcp_port!()
    request_log = Path.join(test_root, "default-registry.requests.log")

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    write_workflow_file!(Workflow.workflow_file_path(), control_plane: %{health_check_timeout_ms: 50})
    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    command_builder = fake_worker_builder(%{"alpha" => {"normal", request_log}})
    child_spec = {ProjectProcessManager, name: manager_name, command_builder: command_builder}

    start_supervised!(child_spec)

    assert {:ok, _runtime_state} = ProjectProcessManager.start_project(manager_name, "alpha")

    entry = fetch_entry!(manager_name, "alpha")
    assert entry.runtime_state.status == :running
    assert entry.runtime_state.run_summaries == []
    refute File.exists?(request_log)

    display_entry =
      await_display_entry!(manager_name, "alpha", fn entry ->
        entry.runtime_state.run_summaries != []
      end)

    assert display_entry.runtime_state.run_summaries != []
    assert_eventually(fn -> state_request_logged?(request_log) end, 40)
  end

  test "display registry filters malformed worker run summaries" do
    test_root = temp_root!("display-filters-malformed-run-summaries")
    manager_name = Module.concat(__MODULE__, MalformedRunSummariesManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{"alpha" => "malformed_run_summaries"})})

    assert {:ok, _runtime_state} = ProjectProcessManager.start_project(manager_name, "alpha")

    assert_eventually(fn ->
      match?([_summary], fetch_display_entry!(manager_name, "alpha").runtime_state.run_summaries)
    end)

    entry = fetch_display_entry!(manager_name, "alpha")
    assert entry.runtime_state.status == :running
    [summary] = entry.runtime_state.run_summaries
    assert summary.issue_identifier == "MT-PPM-1"
    assert summary.turn_count == 3
    assert %DateTime{} = summary.last_event_at
    assert summary.attention_items == []

    assert {:ok, _stopped_state} = ProjectProcessManager.stop_project(manager_name, "alpha")
  end

  test "display registry derives blocker and blocked-children attention from worker run summaries" do
    test_root = temp_root!("display-derives-dependency-attention")
    manager_name = Module.concat(__MODULE__, DependencyAttentionManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)

    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{"alpha" => "dependency_attention"})})

    assert {:ok, _runtime_state} = ProjectProcessManager.start_project(manager_name, "alpha")

    assert_eventually(fn ->
      summaries =
        manager_name
        |> fetch_display_entry!("alpha")
        |> then(& &1.runtime_state.run_summaries)
        |> Enum.sort_by(& &1.issue_identifier)

      match?(
        [%{issue_identifier: "MT-CHILD-1"}, %{issue_identifier: "MT-ROOT-1"}],
        summaries
      )
    end)

    entry = fetch_display_entry!(manager_name, "alpha")
    assert entry.runtime_state.status == :running

    summaries = Enum.sort_by(entry.runtime_state.run_summaries, & &1.issue_identifier)
    assert [%{issue_identifier: "MT-CHILD-1"}, %{issue_identifier: "MT-ROOT-1"}] = summaries

    root_summary = Enum.find(summaries, &(&1.issue_identifier == "MT-ROOT-1"))
    assert root_summary.health == "normal"

    assert [%{issue_identifier: "MT-BLOCKER-1", linear_state: "In Progress"}] = root_summary.blocked_by
    assert [%{issue_identifier: "MT-CHILD-1", linear_state: "Todo", url: "https://linear.app/acme/issue/MT-CHILD-1"}] = root_summary.blocks

    assert Enum.any?(
             root_summary.attention_items,
             &(&1.kind == "blocked_by" and String.contains?(&1.message, "MT-BLOCKER-1"))
           )

    assert Enum.any?(
             root_summary.attention_items,
             &(&1.kind == "blocks" and String.contains?(&1.message, "MT-CHILD-1"))
           )

    assert {:ok, _stopped_state} = ProjectProcessManager.stop_project(manager_name, "alpha")
  end

  test "display registry ignores terminal blockers for blocker attention" do
    test_root = temp_root!("display-ignores-terminal-blockers")
    manager_name = Module.concat(__MODULE__, TerminalBlockerAttentionManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)

    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{"alpha" => "terminal_blocker_attention"})})

    assert {:ok, _runtime_state} = ProjectProcessManager.start_project(manager_name, "alpha")

    entry = fetch_display_entry!(manager_name, "alpha")
    assert entry.runtime_state.status == :running

    [summary] = entry.runtime_state.run_summaries
    assert summary.issue_identifier == "MT-TERMINAL-1"
    assert [%{issue_identifier: "MT-DONE-1", linear_state: "Done"}] = summary.blocked_by
    refute Enum.any?(summary.attention_items, &(&1.kind == "blocked_by"))

    assert {:ok, _stopped_state} = ProjectProcessManager.stop_project(manager_name, "alpha")
  end

  test "display registry does not promote slow worker summaries into attention" do
    test_root = temp_root!("display-does-not-promote-slow-health")
    manager_name = Module.concat(__MODULE__, SlowHealthAttentionManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{"alpha" => "slow_health_attention"})})

    assert {:ok, _runtime_state} = ProjectProcessManager.start_project(manager_name, "alpha")

    entry = fetch_display_entry!(manager_name, "alpha")
    assert entry.runtime_state.status == :running

    [summary] = entry.runtime_state.run_summaries
    assert summary.issue_identifier == "MT-SLOW-1"
    assert summary.health == "slow"
    assert summary.attention_items == []

    assert {:ok, _stopped_state} = ProjectProcessManager.stop_project(manager_name, "alpha")
  end

  test "display registry derives fallback health attention and keeps malformed dependency placeholders stable" do
    test_root = temp_root!("display-derives-fallback-health-attention")
    manager_name = Module.concat(__MODULE__, FallbackHealthAttentionManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{"alpha" => "fallback_health_attention"})})

    assert {:ok, _runtime_state} = ProjectProcessManager.start_project(manager_name, "alpha")

    assert_eventually(fn ->
      summaries =
        manager_name
        |> fetch_display_entry!("alpha")
        |> then(& &1.runtime_state.run_summaries)
        |> Map.new(&{&1.issue_identifier, &1})

      Map.has_key?(summaries, "MT-TOOL-1") and Map.has_key?(summaries, "MT-PARENT-UNKNOWN-1")
    end)

    entry = fetch_display_entry!(manager_name, "alpha")
    assert entry.runtime_state.status == :running

    summaries = Map.new(entry.runtime_state.run_summaries, &{&1.issue_identifier, &1})

    tool_summary = Map.fetch!(summaries, "MT-TOOL-1")
    assert tool_summary.health == nil
    assert tool_summary.run_status == "running"
    assert Enum.any?(tool_summary.attention_items, &(&1.kind == "tool_blocked"))
    assert [%{issue_identifier: nil, linear_state: "Todo", url: "https://linear.app/acme/issue/UNLABELED"}] = tool_summary.blocked_by
    assert Enum.any?(tool_summary.attention_items, &(&1.kind == "blocked_by" and &1.message == "Current blockers are still unresolved."))

    codex_summary = Map.fetch!(summaries, "MT-CODEX-1")
    assert codex_summary.health == nil
    assert codex_summary.run_status == "failed"
    assert Enum.any?(codex_summary.attention_items, &(&1.kind == "codex_error"))

    stalled_summary = Map.fetch!(summaries, "MT-STALL-1")
    assert stalled_summary.health == nil
    assert Enum.any?(stalled_summary.attention_items, &(&1.kind == "stalled"))

    quiet_summary = Map.fetch!(summaries, "MT-QUIET-1")
    assert quiet_summary.health == "quiet"
    assert [%{issue_identifier: nil, linear_state: nil, url: "https://linear.app/acme/issue/QUIET-UNKNOWN"}] = quiet_summary.blocked_by
    assert quiet_summary.attention_items == [%{kind: "blocked_by", message: "Current blockers are still unresolved."}]

    parent_summary = Map.fetch!(summaries, "MT-PARENT-UNKNOWN-1")

    assert [%{issue_identifier: "MT-BLOCKS-UNKNOWN-1", linear_state: "In Progress", url: "https://linear.app/acme/issue/MT-BLOCKS-UNKNOWN-1"}] =
             parent_summary.blocks

    assert Enum.any?(parent_summary.attention_items, &(&1.kind == "blocks" and &1.message == "Related blocked issues are still waiting: MT-BLOCKS-UNKNOWN-1."))

    assert {:ok, _stopped_state} = ProjectProcessManager.stop_project(manager_name, "alpha")
  end

  test "display registry covers approval pending, possible stall, generic blocked children, and mixed terminal states" do
    test_root = temp_root!("display-edge-case-attention")
    manager_name = Module.concat(__MODULE__, EdgeCaseAttentionManager)
    port = reserve_tcp_port!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_stall_timeout_ms: 10_000)

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{"alpha" => "edge_case_attention"})})

    assert {:ok, _runtime_state} = ProjectProcessManager.start_project(manager_name, "alpha")

    entry =
      await_display_entry!(manager_name, "alpha", fn entry ->
        summaries = entry.runtime_state.run_summaries

        entry.runtime_state.status == :running and
          Enum.any?(summaries, &(&1.issue_identifier == "MT-APPROVAL-1")) and
          Enum.any?(summaries, &(&1.issue_identifier == "MT-POSSIBLE-1")) and
          Enum.any?(summaries, &(&1.issue_identifier == "MT-PARENT-GENERIC-1")) and
          Enum.any?(summaries, &(is_nil(&1.issue_identifier) and &1.approval_pending == true)) and
          Enum.any?(summaries, &(is_nil(&1.issue_identifier) and &1.turn_count == 7))
      end)

    assert entry.runtime_state.status == :running

    summaries = entry.runtime_state.run_summaries

    approval_summary = Enum.find(summaries, &(&1.issue_identifier == "MT-APPROVAL-1"))
    assert approval_summary.health == nil
    assert approval_summary.attention_items == [%{kind: "needs_attention", message: "Run requires manual follow-up."}]

    possible_summary = Enum.find(summaries, &(&1.issue_identifier == "MT-POSSIBLE-1"))
    assert possible_summary.health == nil
    assert possible_summary.attention_items == [%{kind: "possibly_stalled", message: "Run may be stalled and needs a closer look."}]

    parent_summary = Enum.find(summaries, &(&1.issue_identifier == "MT-PARENT-GENERIC-1"))

    assert [%{issue_identifier: nil, linear_state: "Todo", url: "https://linear.app/acme/issue/UNLABELED-CHILD"}] =
             parent_summary.blocks

    assert parent_summary.attention_items == [%{kind: "blocks", message: "Related blocked issues are still waiting."}]

    approval_only_summary = Enum.find(summaries, &(&1.issue_identifier == nil and &1.approval_pending == true))
    assert approval_only_summary.attention_items == [%{kind: "needs_attention", message: "Run requires manual follow-up."}]

    integer_only_summary = Enum.find(summaries, &(is_nil(&1.issue_identifier) and &1.turn_count == 7))
    assert integer_only_summary.attention_items == []

    assert {:ok, _stopped_state} = ProjectProcessManager.stop_project(manager_name, "alpha")
  end

  test "worker state 503 clears stale run summaries" do
    test_root = temp_root!("state-503-clears-run-summaries")
    manager_name = Module.concat(__MODULE__, State503ClearsRunSummariesManager)
    port = reserve_tcp_port!()
    request_log = Path.join(test_root, "state-503.requests.log")

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    write_workflow_file!(Workflow.workflow_file_path(), control_plane: %{health_check_timeout_ms: 50})
    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    command_builder = fake_worker_builder(%{"alpha" => {"status_503", request_log}})
    child_spec = {ProjectProcessManager, name: manager_name, command_builder: command_builder}

    start_supervised!(child_spec)

    assert {:ok, _runtime_state} = ProjectProcessManager.start_project(manager_name, "alpha")

    inject_runtime!(manager_name, "alpha", fn runtime_state ->
      runtime_state
      |> Map.put(:status, :running)
      |> Map.put(:run_summaries, [%{issue_identifier: "STALE-503"}])
    end)

    assert_eventually(
      fn ->
        entry = fetch_display_entry!(manager_name, "alpha")

        entry.runtime_state.status == :running and
          entry.runtime_state.run_summaries == [] and
          state_request_logged?(request_log)
      end,
      40
    )
  end

  test "worker state timeout clears stale run summaries" do
    test_root = temp_root!("state-timeout-clears-run-summaries")
    manager_name = Module.concat(__MODULE__, StateTimeoutClearsRunSummariesManager)
    port = reserve_tcp_port!()
    request_log = Path.join(test_root, "state-timeout.requests.log")

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    write_workflow_file!(Workflow.workflow_file_path(), control_plane: %{health_check_timeout_ms: 50})
    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    command_builder = fake_worker_builder(%{"alpha" => {"hang", request_log}})
    child_spec = {ProjectProcessManager, name: manager_name, command_builder: command_builder}

    start_supervised!(child_spec)

    assert {:ok, _runtime_state} = ProjectProcessManager.start_project(manager_name, "alpha")

    inject_runtime!(manager_name, "alpha", fn runtime_state ->
      runtime_state
      |> Map.put(:status, :running)
      |> Map.put(:run_summaries, [%{issue_identifier: "STALE-TIMEOUT"}])
    end)

    assert_eventually(
      fn ->
        entry = fetch_display_entry!(manager_name, "alpha")

        entry.runtime_state.status == :running and
          entry.runtime_state.run_summaries == [] and
          state_request_logged?(request_log)
      end,
      40
    )
  end

  test "runtime reload does not restore persisted run summaries" do
    test_root = temp_root!("reload-without-run-summaries")
    manager_name = Module.concat(__MODULE__, ReloadWithoutRunSummariesManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    write_runtime_json!(test_root, "alpha", %{
      status: "stopped",
      pid: nil,
      worker_port: port,
      run_summaries: [%{"issue_identifier" => "STALE-RELOAD"}]
    })

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{})})

    internal_state = :sys.get_state(manager_name)
    assert internal_state.runtimes["alpha"].run_summaries == []

    entry = fetch_entry!(manager_name, "alpha")
    assert entry.runtime_state.run_summaries == []
  end

  test "health updates do not cross projects" do
    test_root = temp_root!("health-isolation")
    manager_name = Module.concat(__MODULE__, HealthIsolationManager)
    alpha_port = reserve_tcp_port!()
    beta_port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", alpha_port),
        project_fixture(test_root, "beta", beta_port)
      ])

    write_workflow_file!(Workflow.workflow_file_path(), control_plane: %{health_check_timeout_ms: 50})
    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)

    start_supervised!(
      {ProjectProcessManager,
       name: manager_name,
       command_builder:
         fake_worker_builder(%{
           "alpha" => "normal",
           "beta" => "normal"
         })}
    )

    assert {:ok, _} = ProjectProcessManager.start_project(manager_name, "alpha")
    assert {:ok, _} = ProjectProcessManager.start_project(manager_name, "beta")

    alpha_seen_at = DateTime.utc_now() |> DateTime.truncate(:second)
    beta_failure_at = DateTime.add(alpha_seen_at, 100, :millisecond)

    assert :ok = ProjectProcessManager.record_health_success(manager_name, "alpha", alpha_seen_at)

    assert :ok =
             ProjectProcessManager.record_health_failure(
               manager_name,
               "beta",
               beta_failure_at,
               "beta timeout"
             )

    assert :ok =
             ProjectProcessManager.record_health_failure(
               manager_name,
               "beta",
               DateTime.add(beta_failure_at, 100, :millisecond),
               "beta timeout"
             )

    alpha_entry = fetch_entry!(manager_name, "alpha")
    beta_entry = fetch_entry!(manager_name, "beta")

    assert alpha_entry.runtime_state.status == :running
    assert alpha_entry.runtime_state.last_seen_at == alpha_seen_at
    assert alpha_entry.runtime_state.last_error == nil

    assert beta_entry.runtime_state.status == :unreachable
    assert beta_entry.runtime_state.last_seen_at == nil
    assert beta_entry.runtime_state.last_error == "beta timeout"
  end

  test "returns not_found for missing projects across project actions" do
    test_root = temp_root!("missing-project")
    manager_name = Module.concat(__MODULE__, MissingProjectManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{})})

    assert {:error, :not_found} = ProjectProcessManager.start_project(manager_name, "missing")
    assert {:error, :not_found} = ProjectProcessManager.stop_project(manager_name, "missing")
    assert {:error, :not_found} = ProjectProcessManager.restart_project(manager_name, "missing")
  end

  test "returns disabled for disabled projects and not_running for stopped projects" do
    test_root = temp_root!("disabled-not-running")
    manager_name = Module.concat(__MODULE__, DisabledManager)
    alpha_port = reserve_tcp_port!()
    beta_port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", alpha_port, enabled: false),
        project_fixture(test_root, "beta", beta_port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{})})

    assert {:error, :disabled} = ProjectProcessManager.start_project(manager_name, "alpha")
    assert {:error, :not_running} = ProjectProcessManager.stop_project(manager_name, "beta")
  end

  test "restarts a not-running project via allow_not_running path" do
    test_root = temp_root!("restart-not-running")
    manager_name = Module.concat(__MODULE__, RestartStoppedManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{"alpha" => "normal"})})

    assert {:ok, runtime_state} = ProjectProcessManager.restart_project(manager_name, "alpha")
    assert runtime_state.status == :running
    assert runtime_state.worker_port == port
  end

  test "ignores stray startup data messages and rejects already running projects" do
    test_root = temp_root!("already-running")
    manager_name = Module.concat(__MODULE__, AlreadyRunningManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{"alpha" => "normal"})})

    assert {:ok, running_state} = ProjectProcessManager.start_project(manager_name, "alpha")

    manager_pid = GenServer.whereis(manager_name)
    send(manager_pid, {:synthetic_port, {:data, "ignored"}})
    Process.sleep(20)

    assert {:error, :already_running} = ProjectProcessManager.start_project(manager_name, "alpha")

    entry = fetch_entry!(manager_name, "alpha")
    assert entry.runtime_state.status == :running
    assert entry.runtime_state.pid == running_state.pid
  end

  test "restart_project returns disabled when restart falls through allow_not_running path" do
    test_root = temp_root!("restart-disabled")
    manager_name = Module.concat(__MODULE__, RestartDisabledManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port, enabled: false)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{})})

    assert {:error, :disabled} = ProjectProcessManager.restart_project(manager_name, "alpha")
    assert fetch_entry!(manager_name, "alpha").runtime_state.status == :disabled
  end

  test "loads invalid persisted runtimes as not_started and projects invalid entries as config_invalid" do
    test_root = temp_root!("invalid-persisted-runtime")
    manager_name = Module.concat(__MODULE__, InvalidPersistedRuntimeManager)
    alpha_port = reserve_tcp_port!()
    invalid_config_path = write_invalid_projects_config!(test_root)

    Application.put_env(:symphony_elixir, :project_config_path_override, invalid_config_path)

    invalid_registry = ProjectProcessManager.project_registry(manager_name)
    [invalid_entry] = invalid_registry.entries
    assert invalid_entry.project_id == "alpha"
    assert invalid_entry.validation_result == :invalid
    assert invalid_entry.normalized_config == nil
    assert invalid_entry.runtime_state.status == :config_invalid

    alpha = project_fixture(test_root, "alpha", alpha_port)
    valid_config_path = write_projects_config!(test_root, [alpha])

    Application.put_env(:symphony_elixir, :project_config_path_override, valid_config_path)

    runtime_dir = control_plane_runtime_dir(test_root, "alpha")
    File.mkdir_p!(runtime_dir)
    File.write!(Path.join(runtime_dir, "runtime.json"), "{not-json")
    File.write!(Path.join(runtime_dir, "worker.pid"), "not-a-pid")

    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{})})

    entry = fetch_entry!(manager_name, "alpha")
    assert entry.runtime_state.status == :not_started
    assert entry.runtime_state.pid == nil

    internal_state = :sys.get_state(manager_name)
    assert Map.keys(internal_state.runtimes) == ["alpha"]
  end

  test "loads persisted runtimes with invalid pid files and downgrades dead running workers" do
    test_root = temp_root!("persisted-dead-worker")
    manager_name = Module.concat(__MODULE__, PersistedDeadWorkerManager)
    alpha_port = reserve_tcp_port!()
    beta_port = reserve_tcp_port!()

    alpha = project_fixture(test_root, "alpha", alpha_port)
    beta = project_fixture(test_root, "beta", beta_port)
    config_path = write_projects_config!(test_root, [alpha, beta])

    alpha_runtime_dir = control_plane_runtime_dir(test_root, "alpha")
    File.mkdir_p!(alpha_runtime_dir)

    File.write!(
      Path.join(alpha_runtime_dir, "runtime.json"),
      Jason.encode!(%{
        status: "crashed",
        pid: nil,
        worker_port: alpha_port,
        started_at: nil,
        exit_code: 11,
        exit_reason: "persisted-crash",
        stdout_path: Path.join(alpha_runtime_dir, "worker.stdout.log"),
        stderr_path: Path.join(alpha_runtime_dir, "worker.stderr.log"),
        error_summary: "persisted-crash"
      })
    )

    File.write!(Path.join(alpha_runtime_dir, "worker.pid"), "not-a-pid")

    dead_pid = 999_999
    beta_runtime_dir = control_plane_runtime_dir(test_root, "beta")
    File.mkdir_p!(beta_runtime_dir)

    File.write!(
      Path.join(beta_runtime_dir, "runtime.json"),
      Jason.encode!(%{
        status: "running",
        pid: dead_pid,
        worker_port: beta_port,
        started_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        exit_code: nil,
        exit_reason: nil,
        stdout_path: Path.join(beta_runtime_dir, "worker.stdout.log"),
        stderr_path: Path.join(beta_runtime_dir, "worker.stderr.log"),
        error_summary: nil
      })
    )

    File.write!(Path.join(beta_runtime_dir, "worker.pid"), Integer.to_string(dead_pid))

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{})})

    alpha_entry = fetch_entry!(manager_name, "alpha")
    assert alpha_entry.runtime_state.status == :crashed
    assert alpha_entry.runtime_state.pid == nil
    assert alpha_entry.runtime_state.exit_reason == "persisted-crash"

    beta_entry = fetch_entry!(manager_name, "beta")
    assert beta_entry.runtime_state.status == :stopped
    assert beta_entry.runtime_state.pid == nil
    assert beta_entry.runtime_state.exit_reason == "worker pid no longer exists"
    assert beta_entry.runtime_state.error_summary == nil
  end

  test "skips nil project_id entries when loading persisted runtimes and refreshing runtime truth" do
    test_root = temp_root!("nil-project-id")
    manager_name = Module.concat(__MODULE__, NilProjectIdManager)
    config_path = write_missing_id_projects_config!(test_root)

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{})})

    [entry] = ProjectProcessManager.project_registry(manager_name).entries
    assert entry.project_id == nil
    assert entry.validation_result == :invalid
    assert entry.runtime_state.status == :config_invalid

    internal_state = :sys.get_state(manager_name)
    assert internal_state.runtimes == %{}
  end

  test "normalizes persisted runtime status strings and invalid timestamps" do
    test_root = temp_root!("persisted-statuses")
    manager_name = Module.concat(__MODULE__, PersistedStatusManager)
    statuses = ["not_started", "starting", "running", "stopping", "stopped", "crashed", "start_failed", "disabled", "config_invalid", "mystery"]

    projects =
      Enum.with_index(statuses, 1)
      |> Enum.map(fn {status, index} ->
        project_fixture(test_root, "project-#{index}", reserve_tcp_port!(), enabled: status != "disabled")
      end)

    config_path = write_projects_config!(test_root, projects)
    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)

    Enum.zip(projects, statuses)
    |> Enum.each(fn {project, status} ->
      runtime_dir = control_plane_runtime_dir(test_root, project.id)
      File.mkdir_p!(runtime_dir)

      File.write!(
        Path.join(runtime_dir, "runtime.json"),
        Jason.encode!(%{
          status: status,
          pid: nil,
          worker_port: project.worker_port,
          started_at: "not-a-datetime",
          exit_code: 17,
          exit_reason: "reason-#{status}",
          stdout_path: Path.join(runtime_dir, "worker.stdout.log"),
          stderr_path: Path.join(runtime_dir, "worker.stderr.log"),
          error_summary: "error-#{status}"
        })
      )
    end)

    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{})})

    expected_statuses = [
      :not_started,
      :starting,
      :running,
      :stopping,
      :stopped,
      :crashed,
      :start_failed,
      :disabled,
      :config_invalid,
      :not_started
    ]

    Enum.zip(projects, expected_statuses)
    |> Enum.each(fn {project, expected_status} ->
      entry = fetch_entry!(manager_name, project.id)
      assert entry.runtime_state.status == expected_status
      assert entry.runtime_state.started_at == nil
      assert entry.runtime_state.exit_code == 17
    end)
  end

  test "display registry keeps atom runtime fields and treats non-binary terminal blockers as unresolved" do
    test_root = temp_root!("display-runtime-atom-fields")
    manager_name = Module.concat(__MODULE__, DisplayRuntimeAtomFieldsManager)
    port = reserve_tcp_port!()
    event_at = DateTime.utc_now() |> DateTime.truncate(:second)

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)

    start_supervised!({
      ProjectProcessManager,
      name: manager_name, command_builder: fake_worker_builder(%{"alpha" => "nonbinary_blocker_attention"})
    })

    assert {:ok, _runtime_state} = ProjectProcessManager.start_project(manager_name, "alpha")

    inject_runtime!(manager_name, "alpha", fn runtime_state ->
      runtime_state
      |> Map.put(:status, :running)
      |> Map.put(:started_at, event_at)
      |> Map.put(:last_seen_at, event_at)
      |> Map.put(:last_health_check_at, event_at)
      |> Map.put(:health_status, :healthy)
    end)

    entry = fetch_entry!(manager_name, "alpha")
    assert entry.runtime_state.status == :running
    assert entry.runtime_state.started_at == event_at
    assert entry.runtime_state.last_seen_at == event_at
    assert entry.runtime_state.last_health_check_at == event_at
    assert entry.runtime_state.health_status == :healthy

    assert_eventually(fn ->
      match?(
        [%{issue_identifier: "MT-NONBINARY-BLOCKER-1"}],
        manager_name
        |> fetch_display_entry!("alpha")
        |> then(& &1.runtime_state.run_summaries)
      )
    end)

    display_entry = fetch_display_entry!(manager_name, "alpha")
    assert display_entry.runtime_state.status == :running
    [summary] = display_entry.runtime_state.run_summaries

    assert summary.attention_items == [
             %{kind: "blocked_by", message: "Current blockers are still unresolved: MT-ACTIVE-1, MT-DONE-NONBINARY."}
           ]
  end

  test "display registry preserves summaries whose only populated field is last_event_at" do
    test_root = temp_root!("display-datetime-only-summary")
    manager_name = Module.concat(__MODULE__, DisplayDateTimeOnlySummaryManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{"alpha" => "datetime_only_summary"})})

    assert {:ok, _runtime_state} = ProjectProcessManager.start_project(manager_name, "alpha")

    assert_eventually(fn ->
      match?(
        [%{last_event_at: %DateTime{}}],
        manager_name
        |> fetch_display_entry!("alpha")
        |> then(& &1.runtime_state.run_summaries)
      )
    end)

    display_entry = fetch_display_entry!(manager_name, "alpha")
    assert display_entry.runtime_state.status == :running
    [summary] = display_entry.runtime_state.run_summaries
    assert summary.issue_identifier == nil
    assert %DateTime{} = summary.last_event_at
    assert summary.attention_items == []
  end

  test "default command builder quotes generated workflow paths" do
    test_root = temp_root!("default-command-builder 'quoted'")
    manager_name = Module.concat(__MODULE__, DefaultCommandBuilderManager)
    port = reserve_tcp_port!()
    project_id = "alpha"

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, project_id, port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name})

    entry = fetch_entry!(manager_name, project_id)
    command = :sys.get_state(manager_name).command_builder.(entry)

    assert command =~ "./bin/symphony --logs-root "
    assert command =~ "--port #{port}"
    assert command =~ shell_escape(entry.normalized_config.logs_root)
    assert command =~ shell_escape(entry.normalized_config.workflow_generated)
  end

  test "project registry reconciles dead in-memory workers as crashed" do
    test_root = temp_root!("dead-runtime-reconcile")
    manager_name = Module.concat(__MODULE__, DeadRuntimeReconcileManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{})})

    :sys.replace_state(manager_name, fn state ->
      put_in(state.runtimes["alpha"], %{
        status: :running,
        pid: 999_998,
        worker_port: port,
        started_at: nil,
        exit_code: nil,
        exit_reason: nil,
        stdout_path: nil,
        stderr_path: nil,
        error_summary: nil
      })
    end)

    entry = fetch_entry!(manager_name, "alpha")
    assert entry.runtime_state.status == :crashed
    assert entry.runtime_state.pid == nil
    assert entry.runtime_state.exit_reason == "worker pid no longer exists"
    assert entry.runtime_state.error_summary == "worker pid no longer exists"
  end

  test "unknown active port exit statuses persist stopped runtime in missing project directory" do
    test_root = temp_root!("missing-runtime-dir")
    manager_name = Module.concat(__MODULE__, MissingRuntimeDirManager)
    port = reserve_tcp_port!()
    missing_runtime_dir = Path.join(System.tmp_dir!(), "symphony-project-process-manager-missing")

    on_exit(fn ->
      File.rm_rf!(missing_runtime_dir)
    end)

    File.rm_rf!(missing_runtime_dir)

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{})})

    fake_port = open_sleep_port(5)

    on_exit(fn ->
      close_port(fake_port)
    end)

    :sys.replace_state(manager_name, fn state ->
      %{
        state
        | active_ports: %{inspect(fake_port) => %{project_id: "missing-project", port: fake_port}},
          runtimes: %{}
      }
    end)

    send(GenServer.whereis(manager_name), {fake_port, {:exit_status, 17}})
    Process.sleep(50)

    persisted = missing_runtime_dir |> Path.join("runtime.json") |> File.read!() |> Jason.decode!()
    assert persisted["status"] == "stopped"
    assert persisted["pid"] == nil
    assert persisted["exit_code"] == 17
    assert persisted["exit_reason"] == "worker exited with status 17"
  end

  test "runtime exit projections cover stopping and starting states" do
    test_root = temp_root!("runtime-exit-projections")
    manager_name = Module.concat(__MODULE__, RuntimeExitProjectionManager)
    alpha_port = reserve_tcp_port!()
    beta_port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", alpha_port),
        project_fixture(test_root, "beta", beta_port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{})})

    alpha_fake_port = open_sleep_port(5)
    beta_fake_port = open_sleep_port(5)

    on_exit(fn ->
      close_port(alpha_fake_port)
      close_port(beta_fake_port)
    end)

    :sys.replace_state(manager_name, fn state ->
      %{
        state
        | active_ports: %{
            inspect(alpha_fake_port) => %{project_id: "alpha", port: alpha_fake_port},
            inspect(beta_fake_port) => %{project_id: "beta", port: beta_fake_port}
          },
          runtimes: %{
            "alpha" => %{
              status: :stopping,
              pid: 1_001,
              worker_port: alpha_port,
              started_at: nil,
              exit_code: nil,
              exit_reason: nil,
              stdout_path: nil,
              stderr_path: nil,
              error_summary: "old"
            },
            "beta" => %{
              status: :starting,
              pid: 1_002,
              worker_port: beta_port,
              started_at: nil,
              exit_code: nil,
              exit_reason: nil,
              stdout_path: nil,
              stderr_path: nil,
              error_summary: nil
            }
          }
      }
    end)

    manager_pid = GenServer.whereis(manager_name)
    send(manager_pid, {alpha_fake_port, {:exit_status, 21}})
    send(manager_pid, {beta_fake_port, {:exit_status, 22}})

    assert_eventually(fn ->
      alpha_entry = fetch_entry!(manager_name, "alpha")
      beta_entry = fetch_entry!(manager_name, "beta")

      alpha_entry.runtime_state.status == :stopped and
        alpha_entry.runtime_state.error_summary == nil and
        beta_entry.runtime_state.status == :start_failed and
        beta_entry.runtime_state.error_summary == "worker command exited during startup"
    end)
  end

  test "closed startup port falls back through await_exit_status after port_open check" do
    test_root = temp_root!("startup-closed-port-await-exit-status")
    manager_name = Module.concat(__MODULE__, StartupClosedPortAwaitExitStatusManager)
    port = reserve_tcp_port!()
    runtime_dir = control_plane_runtime_dir(test_root, "alpha")

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: raw_command_builder("sleep 5")})

    manager_pid = GenServer.whereis(manager_name)
    existing_ports = :erlang.ports()
    task = Task.async(fn -> ProjectProcessManager.start_project(manager_name, "alpha") end)
    os_pid = await_worker_pid!(runtime_dir)
    startup_port = await_port_for_os_pid!(existing_ports, os_pid)

    Port.close(startup_port)

    Task.start(fn ->
      Process.sleep(100)
      send(manager_pid, {startup_port, {:exit_status, 61}})
    end)

    assert {:error, :start_failed} = Task.await(task, 3_000)

    entry = fetch_entry!(manager_name, "alpha")
    assert entry.runtime_state.status == :start_failed
    assert entry.runtime_state.exit_code == 61
    assert entry.runtime_state.exit_reason == "worker exited with status 61"

    kill_pid(os_pid)
  end

  test "startup reports start_failed when worker pid dies before port closes" do
    test_root = temp_root!("startup-dead-pid-open-port")
    manager_name = Module.concat(__MODULE__, StartupDeadPidOpenPortManager)
    port = reserve_tcp_port!()
    runtime_dir = control_plane_runtime_dir(test_root, "alpha")

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: raw_command_builder("sleep 5")})

    manager_pid = GenServer.whereis(manager_name)
    existing_ports = :erlang.ports()
    task = Task.async(fn -> ProjectProcessManager.start_project(manager_name, "alpha") end)
    os_pid = await_worker_pid!(runtime_dir)
    startup_port = await_port_for_os_pid!(existing_ports, os_pid)

    kill_pid(os_pid)

    Task.start(fn ->
      Process.sleep(100)
      send(manager_pid, {startup_port, {:exit_status, 62}})
    end)

    assert {:error, :start_failed} = Task.await(task, 3_000)

    entry = fetch_entry!(manager_name, "alpha")
    assert entry.runtime_state.status == :start_failed
    assert entry.runtime_state.exit_code in [62, 137]
    assert entry.runtime_state.exit_reason == "worker exited with status #{entry.runtime_state.exit_code}"
  end

  test "stops a hang worker and clears runtime resources" do
    test_root = temp_root!("hang-worker")
    manager_name = Module.concat(__MODULE__, HangManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{"alpha" => "hang"})})

    assert {:ok, running_state} = ProjectProcessManager.start_project(manager_name, "alpha")
    assert running_state.status == :running
    assert is_integer(running_state.pid)

    assert {:ok, stopped_state} = ProjectProcessManager.stop_project(manager_name, "alpha")
    assert stopped_state.status == :stopped
    assert is_nil(stopped_state.pid)

    runtime_dir = control_plane_runtime_dir(test_root, "alpha")
    assert fetch_entry!(manager_name, "alpha").runtime_state.status == :stopped
    refute File.exists?(Path.join(runtime_dir, "worker.pid"))
    assert_eventually(fn -> not process_alive?(running_state.pid) end)
  end

  test "stop_project escalates from TERM to KILL when worker ignores TERM" do
    test_root = temp_root!("term-then-kill-worker")
    manager_name = Module.concat(__MODULE__, TermThenKillManager)
    port = reserve_tcp_port!()

    ignored_term_command =
      "bash -c " <> shell_escape("trap '' TERM; while true; do sleep 1; done")

    command_builder = raw_command_builder(ignored_term_command)

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)

    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: command_builder})

    assert {:ok, running_state} = ProjectProcessManager.start_project(manager_name, "alpha")
    assert running_state.status == :running
    assert is_integer(running_state.pid)

    assert {:ok, stopped_state} = ProjectProcessManager.stop_project(manager_name, "alpha")
    assert stopped_state.status == :stopped
    assert is_nil(stopped_state.pid)
    assert_eventually(fn -> not process_alive?(running_state.pid) end)
  end

  test "reconciles persisted pid after control-plane restart" do
    test_root = temp_root!("reconcile-pid")
    manager_name = Module.concat(__MODULE__, ReconcileManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", port)
      ])

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    {pid, cleanup_ref} = launch_detached_fake_worker!(port)

    on_exit(fn ->
      cleanup_detached_worker(pid, cleanup_ref)
    end)

    runtime_dir = control_plane_runtime_dir(test_root, "alpha")
    File.mkdir_p!(runtime_dir)
    File.write!(Path.join(runtime_dir, "worker.pid"), Integer.to_string(pid))

    runtime_payload = %{
      status: "running",
      pid: pid,
      worker_port: port,
      started_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      exit_code: nil,
      exit_reason: nil,
      stdout_path: Path.join(runtime_dir, "worker.stdout.log"),
      stderr_path: Path.join(runtime_dir, "worker.stderr.log"),
      error_summary: nil
    }

    File.write!(Path.join(runtime_dir, "runtime.json"), Jason.encode!(runtime_payload))
    File.write!(Path.join(runtime_dir, "worker.stdout.log"), "")
    File.write!(Path.join(runtime_dir, "worker.stderr.log"), "")

    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{"alpha" => "normal"})})

    entry = fetch_entry!(manager_name, "alpha")
    assert entry.runtime_state.status == :running
    assert entry.runtime_state.pid == pid
    assert entry.runtime_state.worker_port == port
    assert request_ok?(port)
  end

  defp fetch_entry!(manager_name, project_id) do
    registry = ProjectProcessManager.project_registry(manager_name)
    entry = Enum.find(registry.entries, &(&1.project_id == project_id))
    assert entry != nil
    entry
  end

  defp fetch_display_entry!(manager_name, project_id) do
    registry = ProjectProcessManager.project_registry_for_display(manager_name)
    entry = Enum.find(registry.entries, &(&1.project_id == project_id))
    assert entry != nil
    entry
  end

  defp await_display_entry!(manager_name, project_id, predicate, attempts \\ 20)

  defp await_display_entry!(manager_name, project_id, predicate, attempts)
       when is_function(predicate, 1) and attempts > 0 do
    entry = fetch_display_entry!(manager_name, project_id)

    if predicate.(entry) do
      entry
    else
      Process.sleep(25)
      await_display_entry!(manager_name, project_id, predicate, attempts - 1)
    end
  end

  defp await_display_entry!(_manager_name, _project_id, _predicate, 0),
    do: flunk("display entry did not satisfy predicate in time")

  defp find_entry!(registry, project_id) do
    entry = Enum.find(registry.entries, &(&1.project_id == project_id))
    assert entry != nil
    entry
  end

  defp inject_runtime!(manager_name, project_id, updater) when is_function(updater, 1) do
    :sys.replace_state(manager_name, fn state ->
      runtime_state = Map.fetch!(state.runtimes, project_id)
      %{state | runtimes: Map.put(state.runtimes, project_id, updater.(runtime_state))}
    end)
  end

  defp fake_worker_builder(modes) do
    fake_worker_path = Path.expand("../support/project_process_manager_fake_worker.exs", __DIR__)

    fn entry ->
      case Map.get(modes, entry.project_id, "normal") do
        {mode, request_log} ->
          "elixir #{shell_escape(fake_worker_path)} --mode #{mode} --port #{entry.normalized_config.worker_port} --request-log #{shell_escape(request_log)}"

        mode ->
          "elixir #{shell_escape(fake_worker_path)} --mode #{mode} --port #{entry.normalized_config.worker_port}"
      end
    end
  end

  defp state_request_logged?(request_log) do
    case File.read(request_log) do
      {:ok, contents} -> String.contains?(contents, "/api/v1/state")
      _other -> false
    end
  end

  defp raw_command_builder(command) do
    fn _entry -> command end
  end

  defp await_worker_pid!(runtime_dir, attempts \\ 40)

  defp await_worker_pid!(runtime_dir, attempts) when attempts > 0 do
    pid_path = Path.join(runtime_dir, "worker.pid")

    case File.read(pid_path) do
      {:ok, raw_pid} ->
        case Integer.parse(String.trim(raw_pid)) do
          {pid, _rest} -> pid
          :error -> retry_worker_pid!(runtime_dir, attempts)
        end

      _other ->
        retry_worker_pid!(runtime_dir, attempts)
    end
  end

  defp await_worker_pid!(_runtime_dir, 0), do: flunk("failed to read worker pid")

  defp retry_worker_pid!(runtime_dir, attempts) do
    Process.sleep(10)
    await_worker_pid!(runtime_dir, attempts - 1)
  end

  defp await_port_for_os_pid!(existing_ports, os_pid, attempts \\ 40)

  defp await_port_for_os_pid!(existing_ports, os_pid, attempts) when attempts > 0 do
    port =
      Enum.find(:erlang.ports() -- existing_ports, fn port ->
        match?({:os_pid, ^os_pid}, :erlang.port_info(port, :os_pid))
      end)

    if is_port(port) do
      port
    else
      Process.sleep(10)
      await_port_for_os_pid!(existing_ports, os_pid, attempts - 1)
    end
  end

  defp await_port_for_os_pid!(_existing_ports, _os_pid, 0), do: flunk("failed to observe startup port for worker pid")

  defp temp_root!(label) do
    root = Path.join(System.tmp_dir!(), "symphony-project-process-manager-#{label}-#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    root
  end

  defp project_fixture(test_root, project_id, worker_port, opts \\ []) do
    project_root = Path.join(test_root, project_id)
    workspace_root = Path.join(project_root, "workspace")
    logs_root = Path.join(project_root, "logs")
    workflow_path = Path.join(project_root, "generated/WORKFLOW.md")
    workflow_source = Path.join(project_root, "source/WORKFLOW.md")

    File.mkdir_p!(workspace_root)
    File.mkdir_p!(logs_root)
    File.mkdir_p!(Path.dirname(workflow_source))

    if Keyword.get(opts, :source_workflow?, true) do
      write_workflow_file!(workflow_source)
    end

    if Keyword.get(opts, :workflow?, true) do
      File.mkdir_p!(Path.dirname(workflow_path))
      write_workflow_file!(workflow_path)
    end

    %{
      id: project_id,
      name: String.capitalize(project_id),
      workflow_source: Keyword.get(opts, :workflow_source, if(Keyword.get(opts, :source_workflow?, true), do: workflow_source, else: nil)),
      workflow_generated: workflow_path,
      workspace_root: workspace_root,
      logs_root: logs_root,
      project_slug: Keyword.get(opts, :project_slug, "#{project_id}-slug"),
      repo_url: Keyword.get(opts, :repo_url, "https://example.com/#{project_id}.git"),
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

  defp write_invalid_projects_config!(test_root) do
    config_path = Path.join(test_root, "invalid.projects.yaml")

    File.write!(
      config_path,
      """
      projects:
        - id: alpha
          name: Alpha
          workflow_generated: "/tmp/alpha/WORKFLOW.md"
          workspace_root: "/tmp/alpha/workspace"
          logs_root: "/tmp/alpha/logs"
          enabled: true
          worker_port: nope
      """
    )

    config_path
  end

  defp write_missing_id_projects_config!(test_root) do
    config_path = Path.join(test_root, "missing-id.projects.yaml")

    File.write!(
      config_path,
      """
      projects:
        - name: Alpha
          workflow_generated: "/tmp/alpha/WORKFLOW.md"
          workspace_root: "/tmp/alpha/workspace"
          logs_root: "/tmp/alpha/logs"
          enabled: true
          worker_port: 4010
      """
    )

    config_path
  end

  defp project_yaml(project) do
    [
      "  - id: \"#{project.id}\"",
      "    name: \"#{project.name}\"",
      optional_project_yaml_line("workflow_source", project[:workflow_source]),
      "    workflow_generated: \"#{project.workflow_generated}\"",
      "    workspace_root: \"#{project.workspace_root}\"",
      "    logs_root: \"#{project.logs_root}\"",
      optional_project_yaml_line("project_slug", project[:project_slug]),
      optional_project_yaml_line("repo_url", project[:repo_url]),
      "    enabled: #{if(project.enabled, do: "true", else: "false")}",
      "    worker_port: #{project.worker_port}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp optional_project_yaml_line(_field, nil), do: nil
  defp optional_project_yaml_line(field, value), do: "    #{field}: \"#{value}\""

  defp control_plane_runtime_dir(test_root, project_id) do
    Path.join([test_root, project_id, "logs", "control-plane"])
  end

  defp write_runtime_json!(test_root, project_id, payload) do
    runtime_dir = control_plane_runtime_dir(test_root, project_id)
    File.mkdir_p!(runtime_dir)
    File.write!(Path.join(runtime_dir, "runtime.json"), Jason.encode!(payload))
  end

  defp request_ok?(port) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, {:active, false}], 1_000) do
      {:ok, socket} ->
        :ok = :gen_tcp.send(socket, "GET / HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n")

        result =
          case :gen_tcp.recv(socket, 0, 1_000) do
            {:ok, response} -> String.contains?(response, "200 OK")
            _other -> false
          end

        :ok = :gen_tcp.close(socket)
        result

      _other ->
        false
    end
  end

  defp process_alive?(pid) when is_integer(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      _other -> false
    end
  end

  defp launch_detached_fake_worker!(port) do
    script_path = Path.expand("../support/project_process_manager_fake_worker.exs", __DIR__)
    stdout_path = Path.join(System.tmp_dir!(), "detached-fake-worker-#{port}.stdout.log")
    stderr_path = Path.join(System.tmp_dir!(), "detached-fake-worker-#{port}.stderr.log")

    port_handle =
      Port.open(
        {:spawn_executable, String.to_charlist(System.find_executable("bash"))},
        [
          :binary,
          :exit_status,
          args: [
            ~c"-c",
            String.to_charlist("exec nohup elixir #{shell_escape(script_path)} --mode normal --port #{port} < /dev/null >> #{shell_escape(stdout_path)} 2>> #{shell_escape(stderr_path)} & echo $!")
          ]
        ]
      )

    pid =
      receive do
        {^port_handle, {:data, output}} ->
          output
          |> IO.iodata_to_binary()
          |> String.trim()
          |> String.to_integer()
      after
        2_000 -> flunk("failed to capture detached worker pid")
      end

    cleanup_ref =
      receive do
        {^port_handle, {:exit_status, status}} ->
          assert status == 0
          make_ref()
      after
        2_000 -> flunk("detached worker launch command did not exit cleanly")
      end

    assert_eventually(fn -> request_ok?(port) end, 80)
    {pid, cleanup_ref}
  end

  defp cleanup_detached_worker(pid, _cleanup_ref) do
    _ = System.cmd("kill", ["-9", Integer.to_string(pid)])
    :ok
  end

  defp open_sleep_port(seconds) do
    Port.open(
      {:spawn_executable, String.to_charlist(System.find_executable("bash"))},
      [
        :binary,
        :exit_status,
        args: [~c"-c", String.to_charlist("sleep #{seconds}")]
      ]
    )
  end

  defp close_port(port) when is_port(port) do
    if Port.info(port) != nil do
      Port.close(port)
    end

    :ok
  end

  defp kill_pid(pid) when is_integer(pid) do
    _ = System.cmd("kill", ["-9", Integer.to_string(pid)])
    :ok
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

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(50)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

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

  defp shell_escape(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
