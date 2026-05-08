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
    File.rm(manual_path)
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
            normalized_config: %{enabled: true, worker_port: 4101},
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
          },
          %{
            project_id: "gamma",
            project_name: "Gamma",
            normalized_config: %{enabled: true, worker_port: 4202},
            validation_result: :valid,
            validation_errors: [],
            runtime_state: %{status: :running, worker_port: 5202}
          },
          %{
            project_id: "delta",
            project_name: "Delta",
            normalized_config: %{enabled: true, worker_port: 4303},
            validation_result: :valid,
            validation_errors: [],
            error_summary: "heavy entry error should not leak",
            runtime_state: %{status: :not_started}
          }
        ]
      },
      snapshot_timeout_ms: 50
    )

    payload = json_response(get(build_conn(), "/api/v1/projects"), 200)
    assert Enum.map(payload["projects"], & &1["project_id"]) == ["alpha", "Beta", "gamma", "delta"]

    assert_project_summary_shape(Enum.at(payload["projects"], 0),
      project_id: "alpha",
      project_name: "Alpha",
      enabled: true,
      validation_result: "valid",
      validation_errors: [],
      worker_status: "not_started",
      worker_port: 4101,
      last_seen_at: nil,
      last_health_check_at: nil,
      last_error: nil
    )

    assert_project_summary_shape(Enum.at(payload["projects"], 1),
      project_id: "Beta",
      project_name: "Beta",
      enabled: true,
      validation_result: "invalid",
      validation_errors: [%{"field" => "id", "message" => "id must match ..."}],
      worker_status: "not_started",
      worker_port: nil,
      last_seen_at: nil,
      last_health_check_at: nil,
      last_error: nil
    )

    assert_project_summary_shape(Enum.at(payload["projects"], 2),
      project_id: "gamma",
      project_name: "Gamma",
      enabled: true,
      validation_result: "valid",
      validation_errors: [],
      worker_status: "running",
      worker_port: 5202,
      last_seen_at: nil,
      last_health_check_at: nil,
      last_error: nil
    )

    assert_project_summary_shape(Enum.at(payload["projects"], 3),
      project_id: "delta",
      project_name: "Delta",
      enabled: true,
      validation_result: "valid",
      validation_errors: [],
      worker_status: "not_started",
      worker_port: 4303,
      last_seen_at: nil,
      last_health_check_at: nil,
      last_error: nil
    )

    detail = json_response(get(build_conn(), "/api/v1/projects/alpha/summary"), 200)

    assert_project_summary_shape(detail["project"],
      project_id: "alpha",
      project_name: "Alpha",
      enabled: true,
      validation_result: "valid",
      validation_errors: [],
      worker_status: "not_started",
      worker_port: 4101,
      last_seen_at: nil,
      last_health_check_at: nil,
      last_error: nil
    )

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
    register_project_cleanup(manager_name, ["alpha"], [port])

    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer
    )

    payload = json_response(get(build_conn(), "/api/v1/projects"), 200)

    assert [project] = payload["projects"]

    assert_project_summary_shape(project,
      project_id: "alpha",
      project_name: "Alpha",
      enabled: true,
      validation_result: "valid",
      validation_errors: [],
      worker_status: "not_started",
      worker_port: port,
      last_seen_at: nil,
      last_health_check_at: nil,
      last_error: nil
    )

    assert {:ok, running_state} = ProjectProcessManager.start_project(manager_name, "alpha")
    assert running_state.status == :running

    payload = json_response(get(build_conn(), "/api/v1/projects"), 200)
    [project] = payload["projects"]

    assert_project_summary_shape(project,
      project_id: "alpha",
      project_name: "Alpha",
      enabled: true,
      validation_result: "valid",
      validation_errors: [],
      worker_status: "running",
      worker_port: port,
      last_seen_at: nil,
      last_health_check_at: nil,
      last_error: nil
    )

    detail = json_response(get(build_conn(), "/api/v1/projects/alpha/summary"), 200)

    assert_project_summary_shape(detail["project"],
      project_id: "alpha",
      project_name: "Alpha",
      enabled: true,
      validation_result: "valid",
      validation_errors: [],
      worker_status: "running",
      worker_port: port,
      last_seen_at: nil,
      last_health_check_at: nil,
      last_error: nil
    )

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Alpha"
    assert html =~ "running"
    assert render(view) =~ "running"
  end

  test "projects api projects unreachable when running worker times out and recovers after health resumes" do
    test_root = temp_root!("projects-api-unreachable")
    manager_name = Module.concat(__MODULE__, ProjectsApiUnreachableManager)
    port = reserve_tcp_port!()
    request_log = Path.join(test_root, "requests.log")
    config_path = write_projects_config!(test_root, [project_fixture(test_root, "alpha", port)])

    on_exit(fn -> File.rm_rf!(test_root) end)
    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

    write_workflow_file!(Workflow.workflow_file_path(),
      control_plane: %{health_poll_interval_ms: 10, health_check_timeout_ms: 50}
    )

    start_supervised!(
      {ProjectProcessManager,
       [
         name: manager_name,
         command_builder: fake_worker_builder(%{"alpha" => {"hang_once", request_log}})
       ]}
    )

    register_project_cleanup(manager_name, ["alpha"], [port])

    start_supervised!({SymphonyElixir.WorkerHealthPoller, manager: manager_name, poll_interval_ms: 100})

    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer
    )

    assert {:ok, _running_state} = ProjectProcessManager.start_project(manager_name, "alpha")

    assert_runtime_eventually_reaches_status_with_details(
      manager_name,
      "alpha",
      :unreachable,
      require_last_error?: true,
      extra_check: fn -> project_api_state_visible_with_burst?("alpha", :unreachable) end,
      attempts: 80
    )

    assert_eventually(
      fn ->
        fetch_project_entry!(manager_name, "alpha").runtime_state.status == :running
      end,
      40
    )

    saw_running_api_key = {:saw_project_api_state, manager_name, :running}
    Process.put(saw_running_api_key, false)

    assert_eventually(
      fn ->
        payload = json_response(get(build_conn(), "/api/v1/projects"), 200)
        detail = json_response(get(build_conn(), "/api/v1/projects/alpha/summary"), 200)
        [project] = payload["projects"]

        saw_running_api? =
          project["worker_status"] == "running" and
            detail["project"]["worker_status"] == "running" and
            iso8601_timestamp?(project["last_seen_at"]) and
            iso8601_timestamp?(detail["project"]["last_seen_at"]) and
            iso8601_timestamp?(project["last_health_check_at"]) and
            iso8601_timestamp?(detail["project"]["last_health_check_at"]) and
            is_nil(project["last_error"]) and
            is_nil(detail["project"]["last_error"])

        if saw_running_api? do
          Process.put(saw_running_api_key, true)
        end

        Process.get(saw_running_api_key)
      end,
      120
    )
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

    assert_project_summary_shape(detail["project"],
      project_id: "alpha",
      project_name: "Alpha",
      enabled: true,
      validation_result: "valid",
      validation_errors: [],
      worker_status: "config_invalid",
      worker_port: port,
      last_seen_at: nil,
      last_health_check_at: nil,
      last_error: nil
    )
  end

  test "project control api starts stops and restarts a fake worker" do
    test_root = temp_root!("project-control-api")
    manager_name = Module.concat(__MODULE__, ProjectControlApiManager)
    alpha_port = reserve_tcp_port!()
    beta_port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", alpha_port),
        project_fixture(test_root, "beta", beta_port, enabled: false)
      ])

    on_exit(fn -> File.rm_rf!(test_root) end)
    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{"alpha" => "normal"})})
    register_project_cleanup(manager_name, ["alpha", "beta"], [alpha_port, beta_port])

    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer
    )

    assert json_response(post(build_conn(), "/api/v1/projects/missing/start", %{}), 404) == %{
             "error" => %{"code" => "project_not_found", "message" => "Project not found"}
           }

    start_payload = json_response(post(build_conn(), "/api/v1/projects/alpha/start", %{}), 202)

    assert_project_summary_shape(start_payload["project"],
      project_id: "alpha",
      project_name: "Alpha",
      enabled: true,
      validation_result: "valid",
      validation_errors: [],
      worker_status: "running",
      worker_port: alpha_port,
      last_seen_at: nil,
      last_health_check_at: nil,
      last_error: nil
    )

    beta_detail = json_response(get(build_conn(), "/api/v1/projects/beta/summary"), 200)

    assert_project_summary_shape(beta_detail["project"],
      project_id: "beta",
      project_name: "Beta",
      enabled: false,
      validation_result: "valid",
      validation_errors: [],
      worker_status: "disabled",
      worker_port: beta_port,
      last_seen_at: nil,
      last_health_check_at: nil,
      last_error: nil
    )

    assert json_response(post(build_conn(), "/api/v1/projects/beta/start", %{}), 409) == %{
             "error" => %{"code" => "disabled", "message" => "Project action is not allowed"}
           }

    assert json_response(post(build_conn(), "/api/v1/projects/alpha/start", %{}), 409) == %{
             "error" => %{"code" => "already_running", "message" => "Project action is not allowed"}
           }

    stop_payload = json_response(post(build_conn(), "/api/v1/projects/alpha/stop", %{}), 202)

    assert_project_summary_shape(stop_payload["project"],
      project_id: "alpha",
      project_name: "Alpha",
      enabled: true,
      validation_result: "valid",
      validation_errors: [],
      worker_status: "stopped",
      worker_port: alpha_port,
      last_seen_at: nil,
      last_health_check_at: nil,
      last_error: nil
    )

    restart_payload = json_response(post(build_conn(), "/api/v1/projects/alpha/restart", %{}), 202)

    assert_project_summary_shape(restart_payload["project"],
      project_id: "alpha",
      project_name: "Alpha",
      enabled: true,
      validation_result: "valid",
      validation_errors: [],
      worker_status: "running",
      worker_port: alpha_port,
      last_seen_at: nil,
      last_health_check_at: nil,
      last_error: nil
    )
  end

  test "project control api returns 409 when manager reports start_failed" do
    test_root = temp_root!("project-control-start-failed")
    manager_name = Module.concat(__MODULE__, ProjectControlStartFailedManager)
    port = reserve_tcp_port!()
    config_path = write_projects_config!(test_root, [project_fixture(test_root, "alpha", port)])

    on_exit(fn -> File.rm_rf!(test_root) end)
    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fn _entry -> "printf boom" end})

    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer
    )

    assert json_response(post(build_conn(), "/api/v1/projects/alpha/start", %{}), 409) == %{
             "error" => %{"code" => "start_failed", "message" => "Project action is not allowed"}
           }

    payload = json_response(get(build_conn(), "/api/v1/projects"), 200)
    [project] = payload["projects"]

    assert_project_summary_shape(project,
      project_id: "alpha",
      project_name: "Alpha",
      enabled: true,
      validation_result: "valid",
      validation_errors: [],
      worker_status: "start_failed",
      worker_port: port,
      last_seen_at: nil,
      last_health_check_at: nil,
      last_error: "worker command exited during startup"
    )

    detail = json_response(get(build_conn(), "/api/v1/projects/alpha/summary"), 200)

    assert_project_summary_shape(detail["project"],
      project_id: "alpha",
      project_name: "Alpha",
      enabled: true,
      validation_result: "valid",
      validation_errors: [],
      worker_status: "start_failed",
      worker_port: port,
      last_seen_at: nil,
      last_health_check_at: nil,
      last_error: "worker command exited during startup"
    )
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

  test "phoenix observability api exposes a lightweight health endpoint" do
    start_test_endpoint(orchestrator: Module.concat(__MODULE__, :HealthOnlyOrchestrator))

    payload = json_response(get(build_conn(), "/api/v1/health"), 200)

    assert payload["status"] == "ok"
    assert payload["runtime_mode"] == "workflow"
    assert is_binary(payload["generated_at"])
  end

  test "phoenix observability api rejects non-get health requests" do
    start_test_endpoint(orchestrator: Module.concat(__MODULE__, :HealthMethodOrchestrator))

    assert json_response(post(build_conn(), "/api/v1/health", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}
  end

  test "phoenix observability api exposes health runtime mode in control-plane mode" do
    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer
    )

    payload = json_response(get(build_conn(), "/api/v1/health"), 200)

    assert payload["status"] == "ok"
    assert payload["runtime_mode"] == "control_plane"
    assert is_binary(payload["generated_at"])
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

  test "control-plane dashboard stays lightweight and shows runtime overview columns" do
    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer,
      project_registry: %StaticProjectRegistry{
        entries: [
          %{
            project_id: "alpha",
            project_name: "Alpha",
            normalized_config: %{enabled: true, worker_port: 4101},
            validation_result: :valid,
            validation_errors: [],
            runtime_state: %{status: :running, worker_port: 5101, last_seen_at: ~U[2026-05-07 01:02:03Z]}
          },
          %{
            project_id: "beta",
            project_name: "Beta",
            normalized_config: %{enabled: false, worker_port: 4202},
            validation_result: :invalid,
            validation_errors: [%{field: "workspace_root", message: "workspace_root is required"}],
            runtime_state: %{status: :disabled}
          },
          %{
            project_id: "gamma",
            project_name: "Beta",
            normalized_config: %{enabled: true, worker_port: 4303},
            validation_result: :invalid,
            validation_errors: [%{field: "workspace_root", message: "workspace_root is required"}],
            runtime_state: %{status: :unreachable, last_error: "request timed out"}
          }
        ]
      }
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Projects"
    assert html =~ "Alpha"
    assert html =~ "Beta"
    assert html =~ "gamma"
    assert html =~ "project_id: alpha"
    assert html =~ "project_id: beta"
    assert html =~ "validation: valid"
    assert html =~ "validation: invalid"
    assert html =~ "Enabled"
    assert html =~ "Worker status"
    assert html =~ "Worker port"
    assert html =~ "Last seen"
    assert html =~ "Last error"
    assert html =~ "Actions"
    assert html =~ "running"
    assert html =~ "disabled"
    assert html =~ "unreachable"
    assert html =~ "5101"
    assert html =~ "2026-05-07T01:02:03Z"
    assert html =~ "workspace_root: workspace_root is required"
    assert html =~ "request timed out"
    assert html =~ "/api/v1/projects/alpha/summary"
    assert html =~ "true"
    assert html =~ "false"
    refute html =~ "Validation"
    refute html =~ "Runtime"
    refute html =~ "Errors"
    refute html =~ "Running sessions"
    refute html =~ "Retry queue"
    refute html =~ "Rate limits"
    refute html =~ "Copy ID"
    refute html =~ "MT-HTTP"
  end

  test "control-plane dashboard falls back to validation errors in UI and disables invalid actions" do
    test_root = temp_root!("control-plane-dashboard-disabled-actions")
    manager_name = Module.concat(__MODULE__, DashboardDisabledActionsManager)
    invalid_port = reserve_tcp_port!()
    disabled_port = reserve_tcp_port!()
    running_port = reserve_tcp_port!()
    stopped_port = reserve_tcp_port!()
    unreachable_port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "invalid-config", invalid_port, omit_workspace_root?: true),
        project_fixture(test_root, "disabled-project", disabled_port, enabled: false),
        project_fixture(test_root, "running-project", running_port),
        project_fixture(test_root, "stopped-project", stopped_port),
        project_fixture(test_root, "unreachable-project", unreachable_port)
      ])

    on_exit(fn -> File.rm_rf!(test_root) end)
    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

    write_workflow_file!(Workflow.workflow_file_path(),
      control_plane: %{health_poll_interval_ms: 10, health_check_timeout_ms: 50}
    )

    start_supervised!(
      {ProjectProcessManager,
       name: manager_name,
       command_builder:
         fake_worker_builder(%{
           "running-project" => "normal",
           "stopped-project" => "normal",
           "unreachable-project" => "hang_once"
         })}
    )

    register_project_cleanup(manager_name, ["running-project", "stopped-project", "unreachable-project"], [
      running_port,
      stopped_port,
      unreachable_port
    ])

    start_supervised!({SymphonyElixir.WorkerHealthPoller, manager: manager_name, poll_interval_ms: 100})

    assert {:ok, _running_state} = ProjectProcessManager.start_project(manager_name, "running-project")
    assert {:ok, _running_state} = ProjectProcessManager.start_project(manager_name, "unreachable-project")

    assert_runtime_eventually_reaches_status_with_details(
      manager_name,
      "unreachable-project",
      :unreachable,
      attempts: 20
    )

    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer,
      project_registry: ProjectProcessManager.project_registry(manager_name)
    )

    {:ok, view, html} = live(build_conn(), "/")

    assert html =~ "Projects"

    assert_eventually(fn ->
      rendered_html = render(view)

      rendered_html =~ "workspace_root: workspace_root is required" and
        rendered_html =~ "button" and
        rendered_html =~ "phx-value-project_id=\"invalid-config\"" and
        rendered_html =~ "phx-value-project_id=\"disabled-project\"" and
        rendered_html =~ "phx-value-project_id=\"running-project\"" and
        rendered_html =~ "phx-value-project_id=\"stopped-project\"" and
        rendered_html =~ "phx-value-project_id=\"unreachable-project\"" and
        rendered_html =~ "phx-value-project_id=\"invalid-config\" phx-value-action=\"start\" disabled" and
        rendered_html =~ "phx-value-project_id=\"invalid-config\" phx-value-action=\"stop\" disabled" and
        rendered_html =~ "phx-value-project_id=\"invalid-config\" phx-value-action=\"restart\" disabled" and
        rendered_html =~ "phx-value-project_id=\"disabled-project\" phx-value-action=\"start\" disabled" and
        rendered_html =~ "phx-value-project_id=\"disabled-project\" phx-value-action=\"stop\" disabled" and
        rendered_html =~ "phx-value-project_id=\"disabled-project\" phx-value-action=\"restart\" disabled" and
        rendered_html =~ "phx-value-project_id=\"running-project\" phx-value-action=\"start\" disabled" and
        rendered_html =~ "phx-value-project_id=\"stopped-project\" phx-value-action=\"stop\" disabled" and
        rendered_html =~ "unreachable" and
        rendered_html =~ "phx-value-project_id=\"unreachable-project\" phx-value-action=\"start\" disabled"
    end)

    feedback_html =
      render_click(view, "project_action", %{"project_id" => "disabled-project", "action" => "start"})

    assert feedback_html =~ "Project action failed"
    assert feedback_html =~ "disabled"
  end

  test "control-plane dashboard project actions refresh only the targeted row" do
    test_root = temp_root!("control-plane-dashboard-project-actions")
    manager_name = Module.concat(__MODULE__, DashboardProjectActionsManager)
    alpha_port = reserve_tcp_port!()
    beta_port = reserve_tcp_port!()

    config_path =
      write_projects_config!(test_root, [
        project_fixture(test_root, "alpha", alpha_port),
        project_fixture(test_root, "beta", beta_port)
      ])

    on_exit(fn -> File.rm_rf!(test_root) end)
    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

    start_supervised!(
      {ProjectProcessManager,
       name: manager_name,
       command_builder: fake_worker_builder(%{"alpha" => "normal", "beta" => "normal"})}
    )
    register_project_cleanup(manager_name, ["alpha", "beta"], [alpha_port, beta_port])

    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer
    )

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "alpha"
    assert html =~ "beta"
    assert html =~ "not_started"

    view
    |> element("button[phx-click='project_action'][phx-value-project_id='alpha'][phx-value-action='start']")
    |> render_click()

    assert_eventually(fn ->
      alpha = fetch_project_entry!(manager_name, "alpha")
      beta = fetch_project_entry!(manager_name, "beta")

      alpha.runtime_state.status == :running and
        alpha.runtime_state.worker_port == alpha_port and
        beta.runtime_state.status == :not_started and
        beta.runtime_state.worker_port == beta_port
    end)

    running_html = render(view)
    assert running_html =~ "running"
    assert running_html =~ "not_started"
    assert running_html =~ "#{alpha_port}"
    assert running_html =~ "#{beta_port}"

    view
    |> element("button[phx-click='project_action'][phx-value-project_id='alpha'][phx-value-action='restart']")
    |> render_click()

    assert_eventually(fn ->
      alpha = fetch_project_entry!(manager_name, "alpha")
      beta = fetch_project_entry!(manager_name, "beta")

      alpha.runtime_state.status == :running and
        beta.runtime_state.status == :not_started
    end)

    restarted_html = render(view)
    assert restarted_html =~ "running"
    assert restarted_html =~ "not_started"

    view
    |> element("button[phx-click='project_action'][phx-value-project_id='alpha'][phx-value-action='stop']")
    |> render_click()

    assert_eventually(fn ->
      alpha = fetch_project_entry!(manager_name, "alpha")
      beta = fetch_project_entry!(manager_name, "beta")

      alpha.runtime_state.status == :stopped and
        alpha.runtime_state.worker_port == alpha_port and
        beta.runtime_state.status == :not_started and
        beta.runtime_state.worker_port == beta_port
    end)

    stopped_html = render(view)
    assert stopped_html =~ "stopped"
    assert stopped_html =~ "not_started"
    assert stopped_html =~ "#{alpha_port}"
    assert stopped_html =~ "#{beta_port}"
  end

  test "control-plane dashboard shows feedback instead of crashing when project manager is unavailable" do
    missing_manager = Module.concat(__MODULE__, MissingDashboardProjectManager)

    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer,
      project_registry: %StaticProjectRegistry{
        entries: [
          %{
            project_id: "alpha",
            project_name: "Alpha",
            normalized_config: %{enabled: true, worker_port: 4101},
            validation_result: :valid,
            validation_errors: [],
            runtime_state: %{status: :not_started, worker_port: 4101}
          }
        ]
      }
    )

    Application.put_env(:symphony_elixir, :project_process_manager_name, missing_manager)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Alpha"

    feedback_html =
      render_click(view, "project_action", %{"project_id" => "alpha", "action" => "start"})

    assert feedback_html =~ "Project action failed"
    assert feedback_html =~ "project manager unavailable"
    assert Process.alive?(view.pid)
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

    assert [project] = payload["projects"]
    [error] = project["validation_errors"]

    assert_project_summary_shape(project,
      project_id: nil,
      project_name: nil,
      enabled: true,
      validation_result: "invalid",
      validation_errors: [error],
      worker_status: "not_started",
      worker_port: nil,
      last_seen_at: nil,
      last_health_check_at: nil,
      last_error: nil
    )

    assert error["field"] == "projects"
    assert error["message"] =~ "yaml"

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Projects"
    assert html =~ "projects: "
    assert html =~ "malformed yaml"
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

  test "control-plane dashboard tick refreshes project payload automatically" do
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

    endpoint_config =
      Keyword.merge(
        Application.fetch_env!(:symphony_elixir, SymphonyElixirWeb.Endpoint),
        project_registry: %StaticProjectRegistry{
          entries: [
            %{
              project_id: "gamma",
              project_name: "Gamma",
              validation_result: :valid,
              validation_errors: [],
              runtime_state: %{status: :running}
            }
          ]
        }
      )

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      endpoint_config
    )
    :ok = SymphonyElixirWeb.Endpoint.config_change(%{SymphonyElixirWeb.Endpoint => endpoint_config}, [])

    send(view.pid, :runtime_tick)

    assert_eventually(fn ->
      rendered = render(view)
      rendered =~ "Gamma" and rendered =~ "running"
    end)
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
    assert Enum.map(projects_response.body["projects"], & &1["validation_result"]) == ["valid", "invalid"]

    assert_project_summary_shape(Enum.at(projects_response.body["projects"], 0),
      project_id: "alpha",
      project_name: "Alpha",
      enabled: true,
      validation_result: "valid",
      validation_errors: [],
      worker_status: "not_started",
      worker_port: 4101,
      last_seen_at: nil,
      last_health_check_at: nil,
      last_error: nil
    )

    assert_project_summary_shape(Enum.at(projects_response.body["projects"], 1),
      project_id: "Beta",
      project_name: "Beta",
      enabled: true,
      validation_result: "invalid",
      validation_errors: [%{"field" => "id", "message" => "id must match"}],
      worker_status: "not_started",
      worker_port: nil,
      last_seen_at: nil,
      last_health_check_at: nil,
      last_error: nil
    )

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

  defp fetch_project_entry!(manager_name, project_id) do
    registry = ProjectProcessManager.project_registry(manager_name)
    entry = Enum.find(registry.entries, &(&1.project_id == project_id))
    assert entry != nil
    entry
  end

  defp register_project_cleanup(manager_name, project_ids, worker_ports)
       when is_list(project_ids) and is_list(worker_ports) do
    on_exit(fn ->
      if GenServer.whereis(manager_name) do
        Enum.each(project_ids, &stop_project_for_cleanup(manager_name, &1))
      end

      Enum.each(worker_ports, &kill_fake_worker_port/1)
    end)
  end

  defp stop_project_for_cleanup(manager_name, project_id) do
    case ProjectProcessManager.stop_project(manager_name, project_id) do
      {:ok, _runtime_state} ->
        :ok

      {:error, :not_running} ->
        manager_name
        |> project_runtime_pid(project_id)
        |> kill_pid_if_alive()

      {:error, reason} when reason in [:not_found, :disabled, :config_invalid] ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp project_runtime_pid(manager_name, project_id) do
    registry = ProjectProcessManager.project_registry(manager_name)

    case Enum.find(registry.entries, &(&1.project_id == project_id)) do
      %{runtime_state: %{pid: pid}} when is_integer(pid) -> pid
      _entry -> nil
    end
  end

  defp kill_pid_if_alive(pid) when is_integer(pid) do
    if process_alive?(pid) do
      _ = System.cmd("kill", ["-TERM", Integer.to_string(pid)])
      Process.sleep(100)

      if process_alive?(pid) do
        _ = System.cmd("kill", ["-KILL", Integer.to_string(pid)])
        Process.sleep(100)
      end
    end

    :ok
  end

  defp kill_pid_if_alive(_pid), do: :ok

  defp process_alive?(pid) when is_integer(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      _other -> false
    end
  end

  defp process_alive?(_pid), do: false

  defp kill_fake_worker_port(port) when is_integer(port) do
    kill_fake_worker_port(port, 3)
    wait_for_fake_worker_port_exit(port, 10)
  end

  defp kill_fake_worker_port(_port), do: :ok

  defp kill_fake_worker_port(port, attempts_left) when is_integer(port) and attempts_left > 0 do
    case fake_worker_pids_for_port(port) do
      [] ->
        :ok

      pids ->
        Enum.each(pids, fn pid ->
          _ = System.cmd("kill", ["-TERM", Integer.to_string(pid)])
        end)

        Process.sleep(100)

        remaining_pids = fake_worker_pids_for_port(port)

        Enum.each(remaining_pids, fn pid ->
          _ = System.cmd("kill", ["-KILL", Integer.to_string(pid)])
        end)

        Process.sleep(100)
        kill_fake_worker_port(port, attempts_left - 1)
    end
  end

  defp kill_fake_worker_port(_port, _attempts_left), do: :ok

  defp wait_for_fake_worker_port_exit(port, attempts_left) when is_integer(port) and attempts_left > 0 do
    case fake_worker_pids_for_port(port) do
      [] ->
        :ok

      _pids ->
        Process.sleep(100)
        wait_for_fake_worker_port_exit(port, attempts_left - 1)
    end
  end

  defp wait_for_fake_worker_port_exit(_port, _attempts_left), do: :ok

  defp fake_worker_pids_for_port(port) do
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

      _other ->
        []
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
      workspace_root: if(Keyword.get(opts, :omit_workspace_root?, false), do: nil, else: workspace_root),
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
    """ <>
      if(project.workspace_root, do: "    workspace_root: \"#{project.workspace_root}\"\n", else: "") <>
      """
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

  defp assert_project_summary_shape(project, expected) do
    expected_validation_errors = Keyword.fetch!(expected, :validation_errors)

    expected_keys = [
      "project_id",
      "project_name",
      "enabled",
      "validation_result",
      "validation_errors",
      "worker_status",
      "worker_port",
      "last_seen_at",
      "last_health_check_at",
      "last_error",
      "runtime_state"
    ]

    assert Map.keys(project) |> Enum.sort() == Enum.sort(expected_keys)

    assert Map.take(project, [
             "project_id",
             "project_name",
             "enabled",
             "validation_result",
             "worker_status",
             "worker_port",
             "last_seen_at",
             "last_health_check_at",
             "last_error"
           ]) == %{
             "project_id" => Keyword.fetch!(expected, :project_id),
             "project_name" => Keyword.fetch!(expected, :project_name),
             "enabled" => Keyword.fetch!(expected, :enabled),
             "validation_result" => Keyword.fetch!(expected, :validation_result),
             "worker_status" => Keyword.fetch!(expected, :worker_status),
             "worker_port" => Keyword.fetch!(expected, :worker_port),
             "last_seen_at" => Keyword.fetch!(expected, :last_seen_at),
             "last_health_check_at" => Keyword.fetch!(expected, :last_health_check_at),
             "last_error" => Keyword.fetch!(expected, :last_error)
           }

    assert_validation_errors_shape(project["validation_errors"], expected_validation_errors)
    assert project["runtime_state"] == %{"status" => Keyword.fetch!(expected, :worker_status)}
    assert_optional_iso8601(project["last_seen_at"], Keyword.fetch!(expected, :last_seen_at))

    assert_optional_iso8601(
      project["last_health_check_at"],
      Keyword.fetch!(expected, :last_health_check_at)
    )

    refute Map.has_key?(project, "pid")
    refute Map.has_key?(project, "started_at")
    refute Map.has_key?(project, "exit_code")
    refute Map.has_key?(project, "exit_reason")
    refute Map.has_key?(project, "stdout_path")
    refute Map.has_key?(project, "stderr_path")
    refute Map.has_key?(project, "error_summary")
    refute Map.has_key?(project, "prompt_body")
    refute Map.has_key?(project, "shell_output")
  end

  defp assert_validation_errors_shape(actual, expected) do
    assert length(actual) == length(expected)

    Enum.zip(actual, expected)
    |> Enum.each(fn {actual_error, expected_error} ->
      assert actual_error["field"] == expected_error["field"]
      assert_error_message(actual_error["message"], expected_error["message"])
    end)
  end

  defp assert_error_message(actual, expected) when is_binary(expected) do
    if String.ends_with?(expected, "...") do
      prefix = String.trim_trailing(expected, "...")
      assert String.starts_with?(actual, prefix)
    else
      assert String.contains?(actual, expected)
    end
  end

  defp assert_optional_iso8601(actual, nil) do
    assert is_nil(actual)
  end

  defp assert_optional_iso8601(actual, expected) when is_binary(expected) do
    assert actual == expected
    assert iso8601_timestamp?(actual)
  end

  defp iso8601_timestamp?(value) when is_binary(value) do
    match?({:ok, _datetime, 0}, DateTime.from_iso8601(value))
  end

  defp iso8601_timestamp?(_value), do: false

  defp project_api_state_visible?(project_id, :unreachable) do
    payload = json_response(get(build_conn(), "/api/v1/projects"), 200)
    detail = json_response(get(build_conn(), "/api/v1/projects/#{project_id}/summary"), 200)
    [project] = Enum.filter(payload["projects"], &(&1["project_id"] == project_id))

    project["worker_status"] == "unreachable" and
      detail["project"]["worker_status"] == "unreachable" and
      iso8601_timestamp?(project["last_health_check_at"]) and
      iso8601_timestamp?(detail["project"]["last_health_check_at"]) and
      is_binary(project["last_error"]) and
      is_binary(detail["project"]["last_error"])
  rescue
    _error -> false
  end

  defp project_api_state_visible?(_project_id, _expected_state), do: false

  defp project_api_state_visible_with_burst?(project_id, expected_state, attempts \\ 12)

  defp project_api_state_visible_with_burst?(project_id, expected_state, attempts)
       when attempts > 0 do
    if project_api_state_visible?(project_id, expected_state) do
      true
    else
      Process.sleep(10)
      project_api_state_visible_with_burst?(project_id, expected_state, attempts - 1)
    end
  end

  defp project_api_state_visible_with_burst?(_project_id, _expected_state, 0), do: false

  defp assert_runtime_eventually_reaches_status_with_details(manager_name, project_id, expected_status, opts) do
    saw_status_key = {:saw_project_runtime_state, manager_name, project_id, expected_status}
    saw_details_key = {:saw_project_runtime_details, manager_name, project_id, expected_status}
    require_last_error? = Keyword.get(opts, :require_last_error?, false)
    extra_check = Keyword.get(opts, :extra_check, fn -> true end)
    attempts = Keyword.get(opts, :attempts, 20)
    extra_attempts = Keyword.get(opts, :extra_attempts, attempts)

    Process.put(saw_status_key, false)
    Process.put(saw_details_key, false)

    assert_eventually(
      fn ->
        runtime_state = fetch_project_entry!(manager_name, project_id).runtime_state

        if runtime_state.status == expected_status do
          Process.put(saw_status_key, true)
        end

        details_ready? =
          not is_nil(runtime_state.last_health_check_at) and
            (not require_last_error? or is_binary(runtime_state.last_error))

        if details_ready? do
          Process.put(saw_details_key, true)
        end

        Process.get(saw_status_key) and
          Process.get(saw_details_key)
      end,
      attempts
    )

    assert_eventually(extra_check, extra_attempts)
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
