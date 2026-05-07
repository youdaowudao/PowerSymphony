defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.ProjectProcessManager
  alias SymphonyElixir.Tracker.Memory

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  defmodule StaticProjectRegistry do
    defstruct entries: []
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  setup do
    project_config_path = Application.get_env(:symphony_elixir, :project_config_path_override)

    on_exit(fn ->
      if is_nil(project_config_path) do
        Application.delete_env(:symphony_elixir, :project_config_path_override)
      else
        Application.put_env(:symphony_elixir, :project_config_path_override, project_config_path)
      end
    end)

    :ok
  end

  setup do
    project_process_manager_name = Application.get_env(:symphony_elixir, :project_process_manager_name)

    on_exit(fn ->
      if is_nil(project_process_manager_name) do
        Application.delete_env(:symphony_elixir, :project_process_manager_name)
      else
        Application.put_env(
          :symphony_elixir,
          :project_process_manager_name,
          project_process_manager_name
        )
      end
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Process.exit(manual_pid, :normal)
    restart_result = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    assert match?({:ok, _pid}, restart_result) or
             match?({:error, {:already_started, _pid}}, restart_result)

    Workflow.set_workflow_file_path(existing_path)
    WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.settings!().tracker.kind == "memory"
    assert SymphonyElixir.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issue_states_by_ids(["issue-1"])
    assert :ok = SymphonyElixir.Tracker.create_comment("issue-1", "comment")
    assert :ok = SymphonyElixir.Tracker.update_issue_state("issue-1", "Done")
    assert_receive {:memory_tracker_comment, "issue-1", "comment"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}

    Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    assert :ok = Memory.create_comment("issue-1", "quiet")
    assert :ok = Memory.update_issue_state("issue-1", "Quiet")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert SymphonyElixir.Tracker.adapter() == Adapter
  end

  test "linear adapter delegates reads and validates mutation responses" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.create_comment("issue-1", "hello")
    assert_receive {:graphql_called, create_comment_query, %{body: "hello", issueId: "issue-1"}}
    assert create_comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} =
             Adapter.create_comment("issue-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = Adapter.create_comment("issue-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("issue-1", "Done")
    assert_receive {:graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}
    assert state_lookup_query =~ "states"

    assert_receive {:graphql_called, update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}

    assert update_issue_query =~ "issueUpdate"

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :issue_update_failed} =
             Adapter.update_issue_state("issue-1", "Broken")

    Process.put({FakeLinearClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = Adapter.update_issue_state("issue-1", "Boom")

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :state_not_found} = Adapter.update_issue_state("issue-1", "Missing")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Weird")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        :unexpected
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Odd")
  end

  test "phoenix observability api preserves state, issue, and refresh responses" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "counts" => %{"running" => 1, "retrying" => 1},
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "state" => "In Progress",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "session_id" => "thread-http",
                 "turn_count" => 7,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
               }
             ],
             "retrying" => [
               %{
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "attempt" => 2,
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom",
                 "worker_host" => nil,
                 "workspace_path" => nil
               }
             ],
             "codex_totals" => %{
               "input_tokens" => 4,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5
             },
             "rate_limits" => %{"primary" => %{"remaining" => 11}}
           }

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "status" => "running",
             "workspace" => %{
               "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
               "host" => nil
             },
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "worker_host" => nil,
               "workspace_path" => nil,
               "session_id" => "thread-http",
               "turn_count" => 7,
               "state" => "In Progress",
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "last_event_at" => nil,
               "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
             },
             "retry" => nil,
             "logs" => %{"codex_session_logs" => []},
             "recent_events" => [],
             "last_error" => nil,
             "tracked" => %{}
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{"status" => "retrying", "retry" => %{"attempt" => 2, "error" => "boom"}} =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn = post(build_conn(), "/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
             json_response(conn, 202)
  end

  test "phoenix control-plane api exposes project registry summaries" do
    start_test_endpoint(
      project_registry: %StaticProjectRegistry{
        entries: [
          %{
            project_id: "alpha",
            project_name: "Alpha",
            validation_result: :valid,
            validation_errors: [],
            runtime_state: %{status: :not_started}
          },
          %{
            project_id: "Beta",
            project_name: "Beta",
            validation_result: :invalid,
            validation_errors: [%{field: "id", message: "id must match ..."}],
            runtime_state: %{status: :not_started}
          }
        ]
      },
      snapshot_timeout_ms: 50
    )

    payload = json_response(get(build_conn(), "/api/v1/projects"), 200)
    assert Enum.map(payload["projects"], & &1["project_id"]) == ["alpha", "Beta"]

    detail = json_response(get(build_conn(), "/api/v1/projects/alpha/summary"), 200)
    assert detail["project"]["runtime_state"]["status"] == "not_started"
    assert detail["project"]["validation_result"] == "valid"

    assert json_response(post(build_conn(), "/api/v1/projects", %{}), 405) == %{
             "error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}
           }

    assert json_response(post(build_conn(), "/api/v1/projects/alpha/summary", %{}), 405) == %{
             "error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}
           }

    assert json_response(get(build_conn(), "/api/v1/projects/missing/summary"), 404) == %{
             "error" => %{"code" => "project_not_found", "message" => "Project not found"}
           }
  end

  test "projects api reads dynamic runtime state from project process manager" do
    test_root = temp_root!("projects-api-dynamic-runtime")
    manager_name = Module.concat(__MODULE__, DynamicProjectsManager)
    port = reserve_tcp_port!()
    config_path = write_projects_config!(test_root, [project_fixture(test_root, "alpha", port)])

    on_exit(fn -> File.rm_rf!(test_root) end)
    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{"alpha" => "normal"})})

    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer
    )

    payload = json_response(get(build_conn(), "/api/v1/projects"), 200)

    assert [
             %{
               "project_id" => "alpha",
               "runtime_state" => %{
                 "status" => "not_started",
                 "pid" => nil,
                 "worker_port" => ^port,
                 "started_at" => nil,
                 "exit_code" => nil,
                 "exit_reason" => nil,
                 "stdout_path" => nil,
                 "stderr_path" => nil,
                 "error_summary" => nil
               }
             }
           ] = payload["projects"]

    assert {:ok, running_state} = ProjectProcessManager.start_project(manager_name, "alpha")
    assert running_state.status == :running

    payload = json_response(get(build_conn(), "/api/v1/projects"), 200)
    [project] = payload["projects"]
    assert project["runtime_state"]["status"] == "running"
    assert project["runtime_state"]["pid"] == running_state.pid
    assert project["runtime_state"]["worker_port"] == port
    assert is_binary(project["runtime_state"]["started_at"])
    assert project["runtime_state"]["stdout_path"] == running_state.stdout_path
    assert project["runtime_state"]["stderr_path"] == running_state.stderr_path

    detail = json_response(get(build_conn(), "/api/v1/projects/alpha/summary"), 200)
    assert detail["project"]["runtime_state"]["status"] == "running"
    assert detail["project"]["runtime_state"]["pid"] == running_state.pid

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Alpha"
    assert html =~ "running"
    assert render(view) =~ "running"
  end

  test "project summary projects config_invalid when workflow file is missing" do
    test_root = temp_root!("project-summary-config-invalid")
    manager_name = Module.concat(__MODULE__, MissingWorkflowProjectsManager)
    port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [project_fixture(test_root, "alpha", port, workflow?: false)])

    on_exit(fn -> File.rm_rf!(test_root) end)
    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{})})

    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer
    )

    detail = json_response(get(build_conn(), "/api/v1/projects/alpha/summary"), 200)
    assert detail["project"]["project_id"] == "alpha"
    assert detail["project"]["validation_result"] == "valid"
    assert detail["project"]["runtime_state"]["status"] == "config_invalid"
    assert detail["project"]["runtime_state"]["worker_port"] == port
  end

  test "project control api starts stops and restarts a fake worker" do
    test_root = temp_root!("project-control-api")
    manager_name = Module.concat(__MODULE__, ProjectControlApiManager)
    port = reserve_tcp_port!()
    config_path = write_projects_config!(test_root, [project_fixture(test_root, "alpha", port)])

    on_exit(fn -> File.rm_rf!(test_root) end)
    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{"alpha" => "normal"})})

    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer
    )

    assert json_response(post(build_conn(), "/api/v1/projects/missing/start", %{}), 404) == %{
             "error" => %{"code" => "project_not_found", "message" => "Project not found"}
           }

    start_payload = json_response(post(build_conn(), "/api/v1/projects/alpha/start", %{}), 202)
    assert start_payload["project"]["runtime_state"]["status"] == "running"
    first_pid = start_payload["project"]["runtime_state"]["pid"]
    assert is_integer(first_pid)

    assert json_response(post(build_conn(), "/api/v1/projects/alpha/start", %{}), 409) == %{
             "error" => %{"code" => "already_running", "message" => "Project action is not allowed"}
           }

    stop_payload = json_response(post(build_conn(), "/api/v1/projects/alpha/stop", %{}), 202)
    assert stop_payload["project"]["runtime_state"]["status"] == "stopped"
    assert stop_payload["project"]["runtime_state"]["pid"] == nil
    assert stop_payload["project"]["runtime_state"]["exit_code"] == 0
    assert stop_payload["project"]["runtime_state"]["exit_reason"] == "stopped"

    restart_payload = json_response(post(build_conn(), "/api/v1/projects/alpha/restart", %{}), 202)
    assert restart_payload["project"]["runtime_state"]["status"] == "running"
    assert is_integer(restart_payload["project"]["runtime_state"]["pid"])
    refute restart_payload["project"]["runtime_state"]["pid"] == first_pid
  end

  test "project control api returns 409 when manager reports start_failed" do
    test_root = temp_root!("project-control-start-failed")
    manager_name = Module.concat(__MODULE__, ProjectControlStartFailedManager)
    port = reserve_tcp_port!()
    config_path = write_projects_config!(test_root, [project_fixture(test_root, "alpha", port)])

    on_exit(fn -> File.rm_rf!(test_root) end)
    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{"alpha" => "crash"})})

    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer
    )

    assert json_response(post(build_conn(), "/api/v1/projects/alpha/start", %{}), 409) == %{
             "error" => %{"code" => "start_failed", "message" => "Project action is not allowed"}
           }
  end

  test "project control api is not available in workflow mode" do
    start_test_endpoint(orchestrator: Module.concat(__MODULE__, :WorkflowOnlyControlApiOrchestrator))

    assert json_response(post(build_conn(), "/api/v1/projects/alpha/start", %{}), 404) == %{
             "error" => %{
               "code" => "not_available_in_control_plane",
               "message" => "Route not available in control-plane mode"
             }
           }

    assert json_response(post(build_conn(), "/api/v1/projects/alpha/stop", %{}), 404) == %{
             "error" => %{
               "code" => "not_available_in_control_plane",
               "message" => "Route not available in control-plane mode"
             }
           }

    assert json_response(post(build_conn(), "/api/v1/projects/alpha/restart", %{}), 404) == %{
             "error" => %{
               "code" => "not_available_in_control_plane",
               "message" => "Route not available in control-plane mode"
             }
           }
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }

    assert json_response(post(build_conn(), "/api/v1/refresh", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert timeout_payload ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ "/dashboard.css"
    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css = response(get(build_conn(), "/dashboard.css"), 200)
    assert dashboard_css =~ ":root {"
    assert dashboard_css =~ ".status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-offline"

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"
  end

  test "dashboard liveview renders and refreshes over pubsub" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(
      orchestrator: orchestrator_name,
      project_registry: %StaticProjectRegistry{
        entries: [
          %{
            project_id: "alpha",
            project_name: "Alpha",
            validation_result: :valid,
            validation_errors: [],
            runtime_state: %{status: :not_started}
          },
          %{
            project_id: "Beta",
            project_name: "Beta",
            validation_result: :invalid,
            validation_errors: [%{field: "id", message: "id must match ..."}],
            runtime_state: %{status: :not_started}
          }
        ]
      },
      snapshot_timeout_ms: 50
    )

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Operations Dashboard"
    assert html =~ "Projects"
    assert html =~ "Alpha"
    assert html =~ "Beta"
    assert html =~ "not_started"
    assert html =~ "invalid"
    assert html =~ "MT-HTTP"
    assert html =~ "MT-RETRY"
    assert html =~ "rendered"
    assert html =~ "Runtime"
    assert html =~ "Live"
    assert html =~ "Offline"
    assert html =~ "Copy ID"
    assert html =~ "Codex update"
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"
    assert html =~ "status-badge-live"
    assert html =~ "status-badge-offline"

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 8,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "codex/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_codex_timestamp: DateTime.utc_now(),
          codex_input_tokens: 10,
          codex_output_tokens: 12,
          codex_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn ->
      render(view) =~ "agent message content streaming: structured update"
    end)
  end

  test "dashboard omits project summary links for invalid entries without project_id" do
    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer,
      project_registry: %StaticProjectRegistry{
        entries: [
          %{
            project_id: "alpha",
            project_name: "Alpha",
            validation_result: :valid,
            validation_errors: [],
            runtime_state: %{status: :not_started}
          },
          %{
            project_id: nil,
            project_name: nil,
            validation_result: :invalid,
            validation_errors: [%{field: "config_path", message: "invalid yaml"}],
            runtime_state: %{status: :not_started}
          }
        ]
      }
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "/api/v1/projects/alpha/summary"
    refute html =~ "/api/v1/projects//summary"
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
  end

  test "control-plane dashboard stays lightweight and only shows static project snapshot" do
    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer,
      project_registry: %StaticProjectRegistry{
        entries: [
          %{
            project_id: "alpha",
            project_name: "Alpha",
            validation_result: :valid,
            validation_errors: [],
            runtime_state: %{status: :not_started}
          },
          %{
            project_id: "beta",
            project_name: "Beta",
            validation_result: :invalid,
            validation_errors: [%{field: "workspace_root", message: "workspace_root is required"}],
            runtime_state: %{status: :not_started}
          }
        ]
      }
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Projects"
    assert html =~ "Alpha"
    assert html =~ "Beta"
    assert html =~ "not_started"
    assert html =~ "invalid"
    refute html =~ "Running sessions"
    refute html =~ "Retry queue"
    refute html =~ "Rate limits"
    refute html =~ "Copy ID"
    refute html =~ "MT-HTTP"
  end

  test "control-plane startup loads invalid project registry as visible validation error instead of an empty list" do
    config_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-invalid-project-registry-http-#{System.unique_integer([:positive])}"
      )

    config_path = Path.join(config_root, "symphony.projects.yaml")

    on_exit(fn -> File.rm_rf!(config_root) end)
    File.mkdir_p!(config_root)
    File.write!(config_path, "projects: [\n")
    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)

    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer,
      project_registry: SymphonyElixir.ProjectRegistryLoader.load()
    )

    payload = json_response(get(build_conn(), "/api/v1/projects"), 200)

    assert [
             %{
               "project_id" => nil,
               "project_name" => nil,
               "validation_result" => "invalid",
               "runtime_state" => %{"status" => "not_started"},
               "validation_errors" => [
                 %{"field" => field, "message" => message}
               ]
             }
           ] = payload["projects"]

    assert field == "projects"
    assert message =~ "yaml"

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Projects"
    assert html =~ "invalid"
    assert html =~ "projects: "
    refute html =~ "No projects registered."
  end

  test "control-plane dashboard does not refresh from observability pubsub updates" do
    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer,
      project_registry: %StaticProjectRegistry{
        entries: [
          %{
            project_id: "alpha",
            project_name: "Alpha",
            validation_result: :valid,
            validation_errors: [],
            runtime_state: %{status: :not_started}
          }
        ]
      }
    )

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Alpha"
    refute render(view) =~ "Gamma"

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Keyword.merge(
        Application.fetch_env!(:symphony_elixir, SymphonyElixirWeb.Endpoint),
        project_registry: %StaticProjectRegistry{
          entries: [
            %{
              project_id: "gamma",
              project_name: "Gamma",
              validation_result: :valid,
              validation_errors: [],
              runtime_state: %{status: :not_started}
            }
          ]
        }
      )
    )

    StatusDashboard.notify_update()
    Process.sleep(50)

    refute render(view) =~ "Gamma"
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200
    assert response.body["counts"] == %{"running" => 1, "retrying" => 1}

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css")
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ ":root {"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js")
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
  end

  test "http server auto-loads project registry from static project config path" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :AutoLoadedProjectRegistryOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    config_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-project-registry-http-server-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(config_root) end)
    File.mkdir_p!(config_root)

    config_path = Path.join(config_root, "symphony.projects.yaml")

    File.write!(config_path, """
    projects:
      - id: alpha
        name: Alpha
        workflow_generated: /tmp/alpha/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/alpha
        logs_root: /tmp/logs/alpha
      - id: Beta
        name: Beta
        workflow_generated: /tmp/beta/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/beta
        logs_root: /tmp/logs/beta
    """)

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})
    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()

    projects_response = Req.get!("http://127.0.0.1:#{port}/api/v1/projects")
    assert projects_response.status == 200

    assert Enum.map(projects_response.body["projects"], & &1["project_id"]) == ["alpha", "Beta"]
    assert Enum.map(projects_response.body["projects"], & &1["runtime_state"]["status"]) == ["not_started", "not_started"]
    assert Enum.map(projects_response.body["projects"], & &1["validation_result"]) == ["valid", "invalid"]

    dashboard_response = Req.get!("http://127.0.0.1:#{port}/")
    assert dashboard_response.status == 200
    assert dashboard_response.body =~ "Projects"
    assert dashboard_response.body =~ "Alpha"
    assert dashboard_response.body =~ "Beta"
    assert dashboard_response.body =~ "not_started"
    assert dashboard_response.body =~ "invalid"
  end

  test "http server boots in control-plane mode without reading WORKFLOW.md" do
    previous_mode = Application.get_env(:symphony_elixir, :runtime_mode)
    previous_host = Application.get_env(:symphony_elixir, :control_plane_host_override)
    previous_port = Application.get_env(:symphony_elixir, :server_port_override)

    on_exit(fn ->
      restore_app_env(:runtime_mode, previous_mode)
      restore_app_env(:control_plane_host_override, previous_host)
      restore_app_env(:server_port_override, previous_port)
    end)

    config_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-control-plane-http-server-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(config_root) end)
    File.mkdir_p!(config_root)

    config_path = Path.join(config_root, "symphony.projects.yaml")

    File.write!(config_path, """
    projects:
      - id: alpha
        name: Alpha
        workflow_generated: /tmp/alpha/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/alpha
        logs_root: /tmp/logs/alpha
    """)

    Workflow.set_workflow_file_path(Path.join(config_root, "MISSING_WORKFLOW.md"))
    Application.put_env(:symphony_elixir, :runtime_mode, :control_plane)
    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    Application.put_env(:symphony_elixir, :control_plane_host_override, "127.0.0.1")
    Application.put_env(:symphony_elixir, :server_port_override, 0)

    start_supervised!({SymphonyElixir.ControlPlaneSnapshotServer, name: SymphonyElixir.ControlPlaneSnapshotServer})
    start_supervised!({HttpServer, []})

    port = wait_for_bound_port()

    projects_response = Req.get!("http://127.0.0.1:#{port}/api/v1/projects")
    assert projects_response.status == 200
    assert Enum.map(projects_response.body["projects"], & &1["project_id"]) == ["alpha"]

    state_response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert state_response.status == 404
    assert state_response.body["error"]["code"] == "not_available_in_control_plane"

    issue_response = Req.get!("http://127.0.0.1:#{port}/api/v1/alpha")
    assert issue_response.status == 404
    assert issue_response.body["error"]["code"] == "not_available_in_control_plane"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 404
    assert refresh_response.body["error"]["code"] == "not_available_in_control_plane"
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp static_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      codex_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp fake_worker_builder(modes) do
    fake_worker_path = Path.expand("../support/project_process_manager_fake_worker.exs", __DIR__)

    fn entry ->
      mode = Map.get(modes, entry.project_id, "normal")

      "elixir #{shell_escape(fake_worker_path)} --mode #{mode} --port #{entry.normalized_config.worker_port}"
    end
  end

  defp temp_root!(label) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-extensions-#{label}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    root
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

  defp reserve_tcp_port! do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp shell_escape(value) do
    escaped = value |> to_string() |> String.replace("'", "'\"'\"'")
    "'#{escaped}'"
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
