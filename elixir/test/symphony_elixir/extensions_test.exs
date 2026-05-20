defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Floki
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

    def handle_call({:run_timeline, _issue_identifier, _cursor}, _from, state) do
      Process.sleep(25)
      {:reply, {:ok, %{items: [], next_cursor: nil}}, state}
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

    def handle_call({:run_timeline, issue_identifier, cursor}, _from, state) do
      results = Keyword.get(state, :run_timeline_results, %{})
      {:reply, Map.get(results, {issue_identifier, cursor}, {:error, :run_not_found}), state}
    end

    def handle_call({:run_event_detail, issue_identifier, event_id}, _from, state) do
      results = Keyword.get(state, :run_event_detail_results, %{})
      {:reply, Map.get(results, {issue_identifier, event_id}, {:error, :run_not_found}), state}
    end

    def handle_call({:run_event_surface, issue_identifier, event_id, surface}, _from, state) do
      results = Keyword.get(state, :run_event_surface_results, %{})
      {:reply, Map.get(results, {issue_identifier, event_id, surface}, {:error, :run_not_found}), state}
    end

    def handle_call({:run_context_summary, issue_identifier}, _from, state) do
      results = Keyword.get(state, :run_context_results, %{})
      {:reply, Map.get(results, issue_identifier, {:error, :run_not_found}), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  defmodule GatedSnapshotOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts) do
      {:ok,
       %{
         test_pid: Keyword.fetch!(opts, :test_pid),
         next_call_id: 0,
         pending_calls: %{}
       }}
    end

    def handle_call(:snapshot, from, state) do
      call_id = state.next_call_id + 1
      send(state.test_pid, {:snapshot_requested, call_id})

      {:noreply,
       %{
         state
         | next_call_id: call_id,
           pending_calls: Map.put(state.pending_calls, call_id, from)
       }}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end

    def handle_info({:release_snapshot, call_id, snapshot}, state) do
      case Map.pop(state.pending_calls, call_id) do
        {nil, _pending_calls} ->
          {:noreply, state}

        {from, pending_calls} ->
          GenServer.reply(from, snapshot)
          {:noreply, %{state | pending_calls: pending_calls}}
      end
    end
  end

  defmodule CrashingSnapshotOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start(__MODULE__, opts, name: name)
    end

    def init(opts) do
      {:ok,
       %{
         test_pid: Keyword.fetch!(opts, :test_pid),
         next_call_id: 0,
         pending_calls: %{}
       }}
    end

    def handle_call(:snapshot, from, state) do
      call_id = state.next_call_id + 1
      send(state.test_pid, {:snapshot_requested, call_id})

      case call_id do
        1 ->
          {caller_pid, _tag} = from
          Process.exit(caller_pid, :snapshot_crashed)
          {:noreply, %{state | next_call_id: call_id}}

        _ ->
          {:noreply,
           %{
             state
             | next_call_id: call_id,
               pending_calls: Map.put(state.pending_calls, call_id, from)
           }}
      end
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end

    def handle_info({:release_snapshot, call_id, snapshot}, state) do
      case Map.pop(state.pending_calls, call_id) do
        {nil, _pending_calls} ->
          {:noreply, state}

        {from, pending_calls} ->
          GenServer.reply(from, snapshot)
          {:noreply, %{state | pending_calls: pending_calls}}
      end
    end
  end

  defmodule M3PrecheckOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts) do
      running = Keyword.get(opts, :running, %{})

      state = %SymphonyElixir.Orchestrator.State{
        running: running,
        claimed: MapSet.new(),
        blocked_claims: %{},
        retry_attempts: %{},
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        max_concurrent_agents: Keyword.get(opts, :max_concurrent_agents, 10)
      }

      {:ok, state}
    end

    def handle_call(:snapshot, _from, %SymphonyElixir.Orchestrator.State{} = state) do
      snapshot = %{
        running: [],
        retrying: [],
        codex_totals: state.codex_totals || %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        rate_limits: nil
      }

      {:reply, snapshot, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticProjectRegistry do
    defstruct entries: []
  end

  defmodule WorkerPortManagerStub do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts) do
      {:ok,
       %{
         worker_ports: Keyword.get(opts, :worker_ports, %{})
       }}
    end

    def handle_call({:worker_port_for_project, project_id}, _from, state) do
      reply =
        case Map.fetch(state.worker_ports, project_id) do
          {:ok, port} -> {:ok, port}
          :error -> {:error, :not_found}
        end

      {:reply, reply, state}
    end
  end

  defmodule FailingTrackerAdapter do
    def fetch_candidate_issues, do: {:error, :tracker_unavailable}
    def fetch_issues_by_states(_states), do: {:error, :tracker_unavailable}
    def fetch_issue_states_by_ids(_issue_ids), do: {:error, :tracker_unavailable}
    def create_comment(_issue_id, _body), do: {:error, :tracker_unavailable}
    def update_issue_state(_issue_id, _state_name), do: {:error, :tracker_unavailable}
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

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 250)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "counts" => %{"running" => 1, "retrying" => 1},
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "title" => "HTTP issue",
                 "state" => "In Progress",
                 "linear_state" => "In Progress",
                 "current_phase" => "codex_reasoning",
                 "current_action" => "reasoning summary streaming",
                 "health" => "normal",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "session_id" => "thread-http",
                 "thread_id" => "thread-http",
                 "turn_id" => "turn-http",
                 "turn_count" => 7,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => state_payload["running"] |> List.first() |> Map.fetch!("last_event_at"),
                 "run_duration_seconds" => 0,
                 "last_error" => nil,
                 "issue_url" => "https://example.org/issues/MT-HTTP",
                 "blocked_by" => [
                   %{
                     "issue_identifier" => "MT-BLOCKER-1",
                     "title" => "HTTP blocker",
                     "linear_state" => "In Progress",
                     "url" => "https://example.org/issues/MT-BLOCKER-1"
                   }
                 ],
                 "run_status" => "running",
                 "approval_pending" => true,
                 "tool_failure" => false,
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
               "linear_state" => "In Progress",
               "current_phase" => "codex_reasoning",
               "current_action" => "reasoning summary streaming",
               "run_status" => "running",
               "health" => "normal",
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "last_event_at" => issue_payload["running"]["last_event_at"],
               "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
             },
             "retry" => nil,
             "logs" => %{"codex_session_logs" => []},
             "recent_events" => [
               %{
                 "at" => issue_payload["running"]["last_event_at"],
                 "event" => "notification",
                 "message" => "rendered"
               }
             ],
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
            runtime_state: %{
              status: :not_started,
              run_summaries: [
                %{
                  issue_identifier: "MT-ALPHA-1",
                  title: "Alpha task",
                  linear_state: "In Progress",
                  current_phase: "codex_editing_files",
                  current_action: "Codex 正在修改文件",
                  health: "normal",
                  session_id: "thread-alpha-turn-1",
                  thread_id: "thread-alpha",
                  turn_id: "turn-1",
                  turn_count: 3,
                  last_event_at: ~U[2026-05-14 02:00:00Z],
                  run_duration_seconds: 480,
                  last_error: nil
                }
              ]
            }
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
      last_error: nil,
      run_summaries: [
        %{
          "issue_identifier" => "MT-ALPHA-1",
          "title" => "Alpha task",
          "linear_state" => "In Progress",
          "issue_url" => nil,
          "current_phase" => "codex_editing_files",
          "current_action" => "Codex 正在修改文件",
          "health" => "normal",
          "session_id" => "thread-alpha-turn-1",
          "thread_id" => "thread-alpha",
          "turn_id" => "turn-1",
          "turn_count" => 3,
          "last_event_at" => "2026-05-14T02:00:00Z",
          "run_duration_seconds" => 480,
          "last_error" => nil,
          "blocked_by" => [],
          "blocks" => [],
          "attention_items" => []
        }
      ]
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
      last_error: nil,
      run_summaries: [
        %{
          "issue_identifier" => "MT-ALPHA-1",
          "title" => "Alpha task",
          "linear_state" => "In Progress",
          "issue_url" => nil,
          "current_phase" => "codex_editing_files",
          "current_action" => "Codex 正在修改文件",
          "health" => "normal",
          "session_id" => "thread-alpha-turn-1",
          "thread_id" => "thread-alpha",
          "turn_id" => "turn-1",
          "turn_count" => 3,
          "last_event_at" => "2026-05-14T02:00:00Z",
          "run_duration_seconds" => 480,
          "last_error" => nil,
          "blocked_by" => [],
          "blocks" => [],
          "attention_items" => []
        }
      ]
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

  test "project summary preserves string-keyed run summaries and missing numeric fields stay nil" do
    start_test_endpoint(
      project_registry: %StaticProjectRegistry{
        entries: [
          %{
            project_id: "alpha",
            project_name: "Alpha",
            validation_result: :valid,
            validation_errors: [],
            runtime_state: %{
              "status" => "running",
              "run_summaries" => [
                %{
                  "issue_identifier" => "MT-STRING-1",
                  "title" => "String keyed summary",
                  "current_phase" => "codex_reasoning",
                  "current_action" => "thinking",
                  "health" => "normal"
                }
              ]
            }
          }
        ]
      }
    )

    detail = json_response(get(build_conn(), "/api/v1/projects/alpha/summary"), 200)
    assert detail["project"]["runtime_state"]["status"] == "running"
    [summary] = detail["project"]["run_summaries"]

    assert summary["issue_identifier"] == "MT-STRING-1"
    assert summary["title"] == "String keyed summary"
    assert summary["turn_count"] == nil
    assert summary["run_duration_seconds"] == nil
  end

  test "project summary preserves dependency and attention fields on run summaries" do
    start_test_endpoint(
      project_registry: %StaticProjectRegistry{
        entries: [
          %{
            project_id: "alpha",
            project_name: "Alpha",
            validation_result: :valid,
            validation_errors: [],
            runtime_state: %{
              status: :running,
              run_summaries: [
                %{
                  issue_identifier: "MT-DEP-1",
                  title: "Dependency summary",
                  linear_state: "In Progress",
                  current_phase: "codex_waiting_next_event",
                  current_action: "waiting for dependency",
                  health: "needs_attention",
                  blocked_by: [
                    %{issue_identifier: "MT-BLOCKER-1", title: "Blocker one", linear_state: "In Progress"}
                  ],
                  blocks: [
                    %{issue_identifier: "MT-BLOCKED-1", title: "Blocked child", linear_state: "Todo"}
                  ],
                  attention_items: [
                    %{kind: "needs_attention", message: "Run requires manual follow-up."}
                  ]
                }
              ]
            }
          }
        ]
      }
    )

    detail = json_response(get(build_conn(), "/api/v1/projects/alpha/summary"), 200)
    [summary] = detail["project"]["run_summaries"]

    assert summary["blocked_by"] == [
             %{
               "issue_identifier" => "MT-BLOCKER-1",
               "title" => "Blocker one",
               "linear_state" => "In Progress"
             }
           ]

    assert summary["blocks"] == [
             %{
               "issue_identifier" => "MT-BLOCKED-1",
               "title" => "Blocked child",
               "linear_state" => "Todo"
             }
           ]

    assert summary["attention_items"] == [
             %{
               "kind" => "needs_attention",
               "message" => "Run requires manual follow-up."
             }
           ]
  end

  test "project summary keeps blocker attention even when health is normal" do
    test_root = temp_root!("project-summary-blocker-attention-normal-health")
    manager_name = Module.concat(__MODULE__, BlockerAttentionNormalHealthManager)
    port = reserve_tcp_port!()

    alpha_project = project_fixture(test_root, "alpha", port)
    config_path = write_projects_config!(test_root, [alpha_project])

    on_exit(fn -> File.rm_rf!(test_root) end)
    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

    {:ok, stub_port} =
      start_stub_http_server(fn
        "GET", "/api/v1/state" ->
          {200,
           %{
             running: [
               %{
                 issue_identifier: "MT-BLOCKED-NORMAL-1",
                 title: "Blocked but healthy-looking summary",
                 linear_state: "In Progress",
                 current_phase: "codex_reasoning",
                 current_action: "working",
                 health: "normal",
                 blocked_by: [
                   %{issue_identifier: "MT-BLOCKER-1", title: "Blocker one", linear_state: "In Progress"}
                 ]
               }
             ]
           }}
      end)

    File.write!(
      config_path,
      """
      projects:
        - id: "alpha"
          name: "Alpha"
          workflow_source: "#{alpha_project.workflow_source}"
          workflow_generated: "#{alpha_project.workflow_generated}"
          workspace_root: "#{alpha_project.workspace_root}"
          logs_root: "#{alpha_project.logs_root}"
          project_slug: "#{alpha_project.project_slug}"
          repo_url: "#{alpha_project.repo_url}"
          enabled: true
          worker_port: #{stub_port}
      """
    )

    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{})})

    :sys.replace_state(manager_name, fn state ->
      runtime_state =
        state.runtimes
        |> Map.fetch!("alpha")
        |> Map.merge(%{status: :running, worker_port: stub_port})

      %{state | runtimes: Map.put(state.runtimes, "alpha", runtime_state)}
    end)

    start_test_endpoint(runtime_mode: :control_plane, orchestrator: SymphonyElixir.ControlPlaneSnapshotServer)

    detail = json_response(get(build_conn(), "/api/v1/projects/alpha/summary"), 200)
    [summary] = detail["project"]["run_summaries"]

    assert Enum.any?(summary["attention_items"], &String.contains?(&1["message"], "MT-BLOCKER-1"))
  end

  test "project summary ignores terminal blockers for blocker attention" do
    test_root = temp_root!("project-summary-terminal-blocker-attention")
    manager_name = Module.concat(__MODULE__, TerminalBlockerAttentionManager)
    port = reserve_tcp_port!()

    alpha_project = project_fixture(test_root, "alpha", port)
    config_path = write_projects_config!(test_root, [alpha_project])

    on_exit(fn -> File.rm_rf!(test_root) end)
    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

    {:ok, stub_port} =
      start_stub_http_server(fn
        "GET", "/api/v1/state" ->
          {200,
           %{
             running: [
               %{
                 issue_identifier: "MT-BLOCKED-DONE-1",
                 title: "Blocked by done summary",
                 linear_state: "In Progress",
                 current_phase: "codex_reasoning",
                 current_action: "working",
                 health: "normal",
                 blocked_by: [
                   %{issue_identifier: "MT-DONE-1", title: "Done blocker", linear_state: "Done"}
                 ]
               }
             ]
           }}
      end)

    File.write!(
      config_path,
      """
      projects:
        - id: "alpha"
          name: "Alpha"
          workflow_source: "#{alpha_project.workflow_source}"
          workflow_generated: "#{alpha_project.workflow_generated}"
          workspace_root: "#{alpha_project.workspace_root}"
          logs_root: "#{alpha_project.logs_root}"
          project_slug: "#{alpha_project.project_slug}"
          repo_url: "#{alpha_project.repo_url}"
          enabled: true
          worker_port: #{stub_port}
      """
    )

    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{})})

    :sys.replace_state(manager_name, fn state ->
      runtime_state =
        state.runtimes
        |> Map.fetch!("alpha")
        |> Map.merge(%{status: :running, worker_port: stub_port})

      %{state | runtimes: Map.put(state.runtimes, "alpha", runtime_state)}
    end)

    start_test_endpoint(runtime_mode: :control_plane, orchestrator: SymphonyElixir.ControlPlaneSnapshotServer)

    detail = json_response(get(build_conn(), "/api/v1/projects/alpha/summary"), 200)
    [summary] = detail["project"]["run_summaries"]

    refute Enum.any?(summary["attention_items"], &String.contains?(&1["message"], "MT-DONE-1"))
  end

  test "project summary does not promote slow health into attention" do
    start_test_endpoint(
      project_registry: %StaticProjectRegistry{
        entries: [
          %{
            project_id: "alpha",
            project_name: "Alpha",
            validation_result: :valid,
            validation_errors: [],
            runtime_state: %{
              status: :running,
              run_summaries: [
                %{
                  issue_identifier: "MT-SLOW-1",
                  title: "Slow but not attention-worthy summary",
                  linear_state: "In Progress",
                  current_phase: "codex_reasoning",
                  current_action: "still thinking",
                  health: "slow",
                  blocked_by: [],
                  blocks: []
                }
              ]
            }
          }
        ]
      }
    )

    detail = json_response(get(build_conn(), "/api/v1/projects/alpha/summary"), 200)
    [summary] = detail["project"]["run_summaries"]

    assert summary["attention_items"] == []
  end

  test "project summary derives dependency and attention fields from project process manager worker state" do
    test_root = temp_root!("project-summary-derived-run-relationships")
    manager_name = Module.concat(__MODULE__, DerivedRunRelationshipsManager)
    port = reserve_tcp_port!()

    alpha_project = project_fixture(test_root, "alpha", port)
    config_path = write_projects_config!(test_root, [alpha_project])

    on_exit(fn -> File.rm_rf!(test_root) end)
    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

    {:ok, stub_port} =
      start_stub_http_server(fn
        "GET", "/api/v1/state" ->
          {200,
           %{
             running: [
               %{
                 issue_identifier: "MT-ROOT-1",
                 title: "Root run",
                 issue_url: "https://linear.app/example/issue/MT-ROOT-1",
                 linear_state: "In Progress",
                 current_phase: "codex_waiting_next_event",
                 current_action: "waiting for blocker",
                 health: "needs_attention",
                 blocked_by: [
                   %{
                     issue_identifier: "MT-BLOCKER-1",
                     title: "Blocker one",
                     linear_state: "In Progress",
                     url: "https://linear.app/example/issue/MT-BLOCKER-1"
                   }
                 ]
               },
               %{
                 issue_identifier: "MT-CHILD-1",
                 title: "Child run",
                 issue_url: "https://linear.app/example/issue/MT-CHILD-1",
                 linear_state: "Todo",
                 current_phase: "retry_scheduled",
                 current_action: "queued behind root",
                 health: "normal",
                 blocked_by: [
                   %{
                     issue_identifier: "MT-ROOT-1",
                     title: "Root run",
                     linear_state: "In Progress",
                     url: "https://linear.app/example/issue/MT-ROOT-1"
                   }
                 ]
               }
             ]
           }}
      end)

    File.write!(
      config_path,
      """
      projects:
        - id: "alpha"
          name: "Alpha"
          workflow_source: "#{alpha_project.workflow_source}"
          workflow_generated: "#{alpha_project.workflow_generated}"
          workspace_root: "#{alpha_project.workspace_root}"
          logs_root: "#{alpha_project.logs_root}"
          project_slug: "#{alpha_project.project_slug}"
          repo_url: "#{alpha_project.repo_url}"
          enabled: true
          worker_port: #{stub_port}
      """
    )

    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{})})

    :sys.replace_state(manager_name, fn state ->
      runtime_state =
        state.runtimes
        |> Map.fetch!("alpha")
        |> Map.merge(%{status: :running, worker_port: stub_port})

      %{state | runtimes: Map.put(state.runtimes, "alpha", runtime_state)}
    end)

    start_test_endpoint(runtime_mode: :control_plane, orchestrator: SymphonyElixir.ControlPlaneSnapshotServer)

    detail = json_response(get(build_conn(), "/api/v1/projects/alpha/summary"), 200)
    [root_summary, child_summary] = detail["project"]["run_summaries"]

    assert root_summary["issue_identifier"] == "MT-ROOT-1"

    assert root_summary["blocked_by"] == [
             %{
               "issue_identifier" => "MT-BLOCKER-1",
               "title" => "Blocker one",
               "linear_state" => "In Progress",
               "url" => "https://linear.app/example/issue/MT-BLOCKER-1"
             }
           ]

    assert root_summary["blocks"] == [
             %{
               "issue_identifier" => "MT-CHILD-1",
               "title" => "Child run",
               "linear_state" => "Todo",
               "url" => "https://linear.app/example/issue/MT-CHILD-1"
             }
           ]

    assert Enum.any?(root_summary["attention_items"], &(&1["message"] == "Run requires manual follow-up."))
    assert Enum.any?(root_summary["attention_items"], &String.contains?(&1["message"], "MT-BLOCKER-1"))

    assert child_summary["issue_identifier"] == "MT-CHILD-1"
    assert child_summary["blocks"] == []
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

    assert_eventually(
      fn ->
        payload = json_response(get(build_conn(), "/api/v1/projects"), 200)
        [project] = payload["projects"]

        if project["run_summaries"] == [] do
          false
        else
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
            last_error: nil,
            run_summaries: [
              %{
                "issue_identifier" => "MT-CP-RUN-1",
                "title" => "Fake worker summary",
                "linear_state" => "In Progress",
                "issue_url" => nil,
                "current_phase" => "codex_reasoning",
                "current_action" => "reasoning summary streaming",
                "health" => "normal",
                "session_id" => "thread-cp-turn-7",
                "thread_id" => "thread-cp",
                "turn_id" => "turn-7",
                "turn_count" => 7,
                "last_event_at" => "2026-05-12T00:08:00Z",
                "run_duration_seconds" => 480,
                "last_error" => nil,
                "blocked_by" => [],
                "blocks" => [],
                "attention_items" => []
              }
            ]
          )

          true
        end
      end,
      160
    )

    assert_eventually(
      fn ->
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
          last_error: nil,
          run_summaries: [
            %{
              "issue_identifier" => "MT-CP-RUN-1",
              "title" => "Fake worker summary",
              "linear_state" => "In Progress",
              "issue_url" => nil,
              "current_phase" => "codex_reasoning",
              "current_action" => "reasoning summary streaming",
              "health" => "normal",
              "session_id" => "thread-cp-turn-7",
              "thread_id" => "thread-cp",
              "turn_id" => "turn-7",
              "turn_count" => 7,
              "last_event_at" => "2026-05-12T00:08:00Z",
              "run_duration_seconds" => 480,
              "last_error" => nil,
              "blocked_by" => [],
              "blocks" => [],
              "attention_items" => []
            }
          ]
        )

        true
      end,
      160
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
      control_plane: %{health_poll_interval_ms: 10, health_check_timeout_ms: 10}
    )

    start_supervised!(
      {ProjectProcessManager,
       [
         name: manager_name,
         command_builder: fake_worker_builder(%{"alpha" => {"hang_once", request_log}})
       ]}
    )

    register_project_cleanup(manager_name, ["alpha"], [port])

    start_supervised!({SymphonyElixir.WorkerHealthPoller, manager: manager_name, poll_interval_ms: 250})

    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer
    )

    assert {:ok, _running_state} = ProjectProcessManager.start_project(manager_name, "alpha")

    saw_unreachable_status_key = {:saw_project_runtime_state, manager_name, "alpha", :unreachable}
    saw_unreachable_details_key = {:saw_project_runtime_details, manager_name, "alpha", :unreachable}
    saw_unreachable_api_key = {:saw_project_api_state, manager_name, "alpha", :unreachable}

    Process.put(saw_unreachable_status_key, false)
    Process.put(saw_unreachable_details_key, false)
    Process.put(saw_unreachable_api_key, false)

    assert_eventually(
      fn ->
        runtime_state = fetch_project_entry!(manager_name, "alpha").runtime_state

        if runtime_state.status == :unreachable do
          Process.put(saw_unreachable_status_key, true)
        end

        if not is_nil(runtime_state.last_health_check_at) and is_binary(runtime_state.last_error) do
          Process.put(saw_unreachable_details_key, true)
        end

        if project_api_state_visible_with_burst?("alpha", :unreachable) do
          Process.put(saw_unreachable_api_key, true)
        end

        Process.get(saw_unreachable_status_key) and
          Process.get(saw_unreachable_details_key) and
          Process.get(saw_unreachable_api_key)
      end,
      80
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

  test "project summary keeps a project valid when generated workflow is missing but can be rebuilt" do
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
      worker_status: "not_started",
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
      last_error: nil,
      run_summaries: [
        %{
          "issue_identifier" => "MT-CP-RUN-1",
          "title" => "Fake worker summary",
          "linear_state" => "In Progress",
          "issue_url" => nil,
          "current_phase" => "codex_reasoning",
          "current_action" => "reasoning summary streaming",
          "health" => "normal",
          "session_id" => "thread-cp-turn-7",
          "thread_id" => "thread-cp",
          "turn_id" => "turn-7",
          "turn_count" => 7,
          "last_event_at" => "2026-05-12T00:08:00Z",
          "run_duration_seconds" => 480,
          "last_error" => nil,
          "blocked_by" => [],
          "blocks" => [],
          "attention_items" => []
        }
      ]
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
      last_error: nil,
      run_summaries: [
        %{
          "issue_identifier" => "MT-CP-RUN-1",
          "title" => "Fake worker summary",
          "linear_state" => "In Progress",
          "issue_url" => nil,
          "current_phase" => "codex_reasoning",
          "current_action" => "reasoning summary streaming",
          "health" => "normal",
          "session_id" => "thread-cp-turn-7",
          "thread_id" => "thread-cp",
          "turn_id" => "turn-7",
          "turn_count" => 7,
          "last_event_at" => "2026-05-12T00:08:00Z",
          "run_duration_seconds" => 480,
          "last_error" => nil,
          "blocked_by" => [],
          "blocks" => [],
          "attention_items" => []
        }
      ]
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

  test "project control api returns 422 when workflow generation fails before startup" do
    test_root = temp_root!("project-control-workflow-generation-failed")
    manager_name = Module.concat(__MODULE__, ProjectControlWorkflowGenerationFailedManager)
    port = reserve_tcp_port!()

    project =
      project_fixture(test_root, "alpha", port,
        workflow?: false,
        project_slug: "slug-alpha",
        repo_url: "https://example.com/alpha.git"
      )

    File.write!(project.workflow_source, "---\n[]\n---\nPrompt body\n")
    config_path = write_projects_config!(test_root, [project])

    on_exit(fn -> File.rm_rf!(test_root) end)
    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{})})

    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer
    )

    assert json_response(post(build_conn(), "/api/v1/projects/alpha/start", %{}), 422) == %{
             "error" => %{
               "code" => "workflow_generation_failed",
               "message" => "Project workflow generation failed"
             }
           }

    payload = json_response(get(build_conn(), "/api/v1/projects"), 200)
    [project_payload] = payload["projects"]

    assert_project_summary_shape(project_payload,
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

  test "workflow timeline api maps orchestrator timeline payload and errors" do
    orchestrator_name = Module.concat(__MODULE__, :TimelineWorkflowOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        run_timeline_results: %{
          {"MT-HTTP", nil} => {:ok, %{items: [%{event_id: "evt-1", summary: "recent"}], next_cursor: "cur-1"}},
          {"MT-HTTP", "bad-cursor"} => {:error, :invalid_cursor},
          {"MT-MISSING-RUN", nil} => {:error, :run_not_found},
          {"MT-DUP", nil} => {:error, :duplicate_run},
          {"MT-BROKEN", nil} => {:error, :timeline_unavailable}
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload = json_response(get(build_conn(), "/api/v1/runs/MT-HTTP/timeline"), 200)

    assert payload == %{
             "items" => [
               %{
                 "event_group" => nil,
                 "event_id" => "evt-1",
                 "event_type" => nil,
                 "source" => nil,
                 "status_markers" => [],
                 "summary" => "recent",
                 "timestamp" => nil
               }
             ],
             "next_cursor" => "cur-1"
           }

    assert json_response(get(build_conn(), "/api/v1/runs/MT-HTTP/timeline?cursor=bad-cursor"), 400) == %{
             "error" => %{"code" => "invalid_cursor", "message" => "Timeline cursor is invalid"}
           }

    assert json_response(get(build_conn(), "/api/v1/runs/MT-MISSING-RUN/timeline"), 404) == %{
             "error" => %{"code" => "run_not_found", "message" => "Run timeline not found"}
           }

    assert json_response(get(build_conn(), "/api/v1/runs/MT-DUP/timeline"), 409) == %{
             "error" => %{"code" => "duplicate_run", "message" => "Multiple running entries matched this run"}
           }

    assert json_response(get(build_conn(), "/api/v1/runs/MT-BROKEN/timeline"), 503) == %{
             "error" => %{"code" => "timeline_unavailable", "message" => "Run timeline is unavailable"}
           }
  end

  test "workflow event detail and surface api maps orchestrator payload and errors" do
    orchestrator_name = Module.concat(__MODULE__, :EventWorkflowOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        run_event_detail_results: %{
          {"MT-HTTP", "evt-1"} =>
            {:ok,
             %{
               event: %{event_id: "evt-1", timestamp: "2026-05-17T01:02:03Z", source: "codex", event_type: "turn_completed", event_group: "codex_activity", summary: "done"},
               run: %{issue_identifier: "MT-HTTP", run_id: "run-1"},
               context: %{session_id: "session-1", thread_id: "thread-1", turn_id: "turn-1"},
               summaries: %{tool_call: "shell", payload: "JSON object with 2 top-level keys", prompt: "Continue?", shell: "git status"},
               surfaces: %{
                 raw: %{available: false, byte_size: 0, preview: nil, truncated: false},
                 payload: %{available: true, byte_size: 32, preview: "{\"tool\":\"shell\"}", truncated: false},
                 prompt: %{available: true, byte_size: 9, preview: "Continue?", truncated: false},
                 shell: %{available: true, byte_size: 10, preview: "git status", truncated: false}
               }
             }},
          {"MT-MISSING-RUN-EVENT", "evt-run-404"} => {:error, :run_not_found},
          {"MT-MISSING-EVENT", "evt-404"} => {:error, :event_not_found},
          {"MT-DUP-EVENT", "evt-dup"} => {:error, :duplicate_run},
          {"MT-DOWN-EVENT", "evt-down"} => {:error, :event_detail_unavailable}
        },
        run_event_surface_results: %{
          {"MT-HTTP", "evt-1", "shell"} => {:ok, %{surface: "shell", available: true, content: "git status", byte_size: 10, truncated: false}},
          {"MT-HTTP", "evt-1", "bad"} => {:error, :invalid_surface},
          {"MT-MISSING-RUN-EVENT", "evt-run-404", "shell"} => {:error, :run_not_found},
          {"MT-HTTP", "evt-404", "shell"} => {:error, :event_not_found},
          {"MT-HTTP", "evt-1", "prompt"} => {:error, :surface_not_available},
          {"MT-DUP-EVENT", "evt-dup", "shell"} => {:error, :duplicate_run},
          {"MT-DOWN-EVENT", "evt-down", "shell"} => {:error, :event_surface_unavailable}
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert json_response(get(build_conn(), "/api/v1/runs/MT-HTTP/events/evt-1"), 200) == %{
             "event" => %{
               "event_id" => "evt-1",
               "timestamp" => "2026-05-17T01:02:03Z",
               "source" => "codex",
               "event_type" => "turn_completed",
               "event_group" => "codex_activity",
               "summary" => "done"
             },
             "run" => %{"issue_identifier" => "MT-HTTP", "run_id" => "run-1"},
             "context" => %{"session_id" => "session-1", "thread_id" => "thread-1", "turn_id" => "turn-1"},
             "summaries" => %{
               "tool_call" => "shell",
               "payload" => "JSON object with 2 top-level keys",
               "prompt" => "Continue?",
               "shell" => "git status"
             },
             "surfaces" => %{
               "raw" => %{"available" => false, "byte_size" => 0, "preview" => nil, "truncated" => false},
               "payload" => %{"available" => true, "byte_size" => 32, "preview" => "{\"tool\":\"shell\"}", "truncated" => false},
               "prompt" => %{"available" => true, "byte_size" => 9, "preview" => "Continue?", "truncated" => false},
               "shell" => %{"available" => true, "byte_size" => 10, "preview" => "git status", "truncated" => false}
             }
           }

    assert json_response(get(build_conn(), "/api/v1/runs/MT-HTTP/events/evt-1/shell"), 200) == %{
             "surface" => "shell",
             "available" => true,
             "content" => "git status",
             "byte_size" => 10,
             "truncated" => false
           }

    assert json_response(get(build_conn(), "/api/v1/runs/MT-HTTP/events/evt-1/bad"), 400) == %{
             "error" => %{"code" => "invalid_surface", "message" => "Event surface is invalid"}
           }

    assert json_response(get(build_conn(), "/api/v1/runs/MT-MISSING-RUN-EVENT/events/evt-run-404"), 404) == %{
             "error" => %{"code" => "run_not_found", "message" => "Run not found"}
           }

    assert json_response(get(build_conn(), "/api/v1/runs/MT-MISSING-EVENT/events/evt-404"), 404) == %{
             "error" => %{"code" => "event_not_found", "message" => "Event not found"}
           }

    assert json_response(get(build_conn(), "/api/v1/runs/MT-MISSING-RUN-EVENT/events/evt-run-404/shell"), 404) == %{
             "error" => %{"code" => "run_not_found", "message" => "Run not found"}
           }

    assert json_response(get(build_conn(), "/api/v1/runs/MT-HTTP/events/evt-1/prompt"), 404) == %{
             "error" => %{"code" => "surface_not_available", "message" => "Event surface is unavailable"}
           }

    assert json_response(get(build_conn(), "/api/v1/runs/MT-DUP-EVENT/events/evt-dup"), 409) == %{
             "error" => %{"code" => "duplicate_run", "message" => "Multiple running entries matched this run"}
           }

    assert json_response(get(build_conn(), "/api/v1/runs/MT-DOWN-EVENT/events/evt-down/shell"), 503) == %{
             "error" => %{"code" => "event_surface_unavailable", "message" => "Run event surface is unavailable"}
           }
  end

  test "control-plane timeline api proxies worker responses and preserves timeline-specific errors" do
    manager_name = Module.concat(__MODULE__, TimelineProxyManager)

    {:ok, port} =
      start_stub_http_server(fn
        "GET", "/api/v1/runs/MT-ALPHA-1/timeline?cursor=older" ->
          {200,
           %{
             items: [%{event_id: "evt-old", summary: "older event", source: "codex"}],
             next_cursor: nil
           }}

        "GET", "/api/v1/runs/MT-ALPHA-1/timeline" ->
          {200,
           %{
             items: [%{event_id: "evt-new", summary: "recent event", source: "orchestrator"}],
             next_cursor: "older"
           }}

        "GET", "/api/v1/runs/MT-BAD/timeline" ->
          {400, %{error: %{code: "invalid_cursor", message: "worker said bad cursor"}}}

        "GET", "/api/v1/runs/MT-MISSING/timeline" ->
          {404, %{error: %{code: "run_not_found", message: "worker missing"}}}

        "GET", "/api/v1/runs/MT-DUP/timeline" ->
          {409, %{error: %{code: "duplicate_run", message: "worker duplicate"}}}

        "GET", "/api/v1/runs/MT-DOWN/timeline" ->
          {503, %{error: %{code: "timeline_unavailable", message: "worker down"}}}
      end)

    start_supervised!({WorkerPortManagerStub, name: manager_name, worker_ports: %{"alpha" => port}})
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

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
            runtime_state: %{
              status: :running,
              run_summaries: [
                %{issue_identifier: "MT-ALPHA-1", title: "Alpha run"},
                %{issue_identifier: "MT-BAD", title: "Bad cursor run"},
                %{issue_identifier: "MT-MISSING", title: "Missing run"},
                %{issue_identifier: "MT-DUP", title: "Duplicate run"},
                %{issue_identifier: "MT-DOWN", title: "Down run"}
              ]
            }
          }
        ]
      }
    )

    assert json_response(get(build_conn(), "/api/v1/projects/alpha/runs/MT-ALPHA-1/timeline"), 200) == %{
             "items" => [
               %{
                 "event_group" => nil,
                 "event_id" => "evt-new",
                 "event_type" => nil,
                 "source" => "orchestrator",
                 "status_markers" => [],
                 "summary" => "recent event",
                 "timestamp" => nil
               }
             ],
             "next_cursor" => "older"
           }

    assert json_response(get(build_conn(), "/api/v1/projects/alpha/runs/MT-ALPHA-1/timeline?cursor=older"), 200) == %{
             "items" => [
               %{
                 "event_group" => nil,
                 "event_id" => "evt-old",
                 "event_type" => nil,
                 "source" => "codex",
                 "status_markers" => [],
                 "summary" => "older event",
                 "timestamp" => nil
               }
             ],
             "next_cursor" => nil
           }

    assert json_response(get(build_conn(), "/api/v1/projects/alpha/runs/MT-BAD/timeline"), 400) == %{
             "error" => %{"code" => "invalid_cursor", "message" => "Timeline cursor is invalid"}
           }

    assert json_response(get(build_conn(), "/api/v1/projects/alpha/runs/MT-MISSING/timeline"), 404) == %{
             "error" => %{"code" => "run_not_found", "message" => "Run timeline not found"}
           }

    assert json_response(get(build_conn(), "/api/v1/projects/alpha/runs/MT-DUP/timeline"), 409) == %{
             "error" => %{"code" => "duplicate_run", "message" => "Multiple running entries matched this run"}
           }

    assert json_response(get(build_conn(), "/api/v1/projects/alpha/runs/MT-DOWN/timeline"), 503) == %{
             "error" => %{"code" => "timeline_unavailable", "message" => "Run timeline is unavailable"}
           }
  end

  test "control-plane event detail and surface api proxies worker responses and preserves event-specific errors" do
    manager_name = Module.concat(__MODULE__, EventProxyManager)

    {:ok, port} =
      start_stub_http_server(fn
        "GET", "/api/v1/runs/MT-ALPHA-1/events/evt-1" ->
          {200,
           %{
             event: %{event_id: "evt-1", timestamp: "2026-05-17T01:02:03Z", source: "codex", event_type: "turn_completed", event_group: "codex_activity", summary: "done"},
             run: %{issue_identifier: "MT-ALPHA-1", run_id: "run-1"},
             context: %{session_id: "session-1", thread_id: "thread-1", turn_id: "turn-1"},
             summaries: %{tool_call: "shell", payload: "JSON object with 1 top-level keys", prompt: nil, shell: "git status"},
             surfaces: %{
               raw: %{available: false, byte_size: 0, preview: nil, truncated: false},
               payload: %{available: true, byte_size: 14, preview: "{\"tool\":\"shell\"}", truncated: false},
               prompt: %{available: false, byte_size: 0, preview: nil, truncated: false},
               shell: %{available: true, byte_size: 10, preview: "git status", truncated: false}
             }
           }}

        "GET", "/api/v1/runs/MT-ALPHA-1/events/evt-1/shell" ->
          {200, %{surface: "shell", available: true, content: "git status", byte_size: 10, truncated: false}}

        "GET", "/api/v1/runs/MT-ALPHA-1/events/evt-1/bad" ->
          {400, %{error: %{code: "invalid_surface", message: "worker bad surface"}}}

        "GET", "/api/v1/runs/MT-MISSING-RUN/events/evt-run-404" ->
          {404, %{error: %{code: "run_not_found", message: "worker missing run"}}}

        "GET", "/api/v1/runs/MT-ALPHA-1/events/evt-404" ->
          {404, %{error: %{code: "event_not_found", message: "worker missing event"}}}

        "GET", "/api/v1/runs/MT-ALPHA-1/events/evt-1/prompt" ->
          {404, %{error: %{code: "surface_not_available", message: "worker no prompt"}}}

        "GET", "/api/v1/runs/MT-MISSING-RUN/events/evt-run-404/shell" ->
          {404, %{error: %{code: "run_not_found", message: "worker missing run"}}}

        "GET", "/api/v1/runs/MT-DUP/events/evt-dup" ->
          {409, %{error: %{code: "duplicate_run", message: "worker duplicate"}}}

        "GET", "/api/v1/runs/MT-DOWN/events/evt-down/shell" ->
          {503, %{error: %{code: "event_surface_unavailable", message: "worker down"}}}
      end)

    start_supervised!({WorkerPortManagerStub, name: manager_name, worker_ports: %{"alpha" => port}})
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

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
            runtime_state: %{status: :running, run_summaries: [%{issue_identifier: "MT-ALPHA-1", title: "Alpha run"}]}
          }
        ]
      }
    )

    assert json_response(get(build_conn(), "/api/v1/projects/alpha/runs/MT-ALPHA-1/events/evt-1"), 200)["event"]["event_id"] == "evt-1"

    assert json_response(get(build_conn(), "/api/v1/projects/alpha/runs/MT-ALPHA-1/events/evt-1/shell"), 200) == %{
             "surface" => "shell",
             "available" => true,
             "content" => "git status",
             "byte_size" => 10,
             "truncated" => false
           }

    assert json_response(get(build_conn(), "/api/v1/projects/alpha/runs/MT-ALPHA-1/events/evt-1/bad"), 400) == %{
             "error" => %{"code" => "invalid_surface", "message" => "Event surface is invalid"}
           }

    assert json_response(get(build_conn(), "/api/v1/projects/alpha/runs/MT-MISSING-RUN/events/evt-run-404"), 404) == %{
             "error" => %{"code" => "run_not_found", "message" => "Run not found"}
           }

    assert json_response(get(build_conn(), "/api/v1/projects/alpha/runs/MT-ALPHA-1/events/evt-404"), 404) == %{
             "error" => %{"code" => "event_not_found", "message" => "Event not found"}
           }

    assert json_response(get(build_conn(), "/api/v1/projects/alpha/runs/MT-MISSING-RUN/events/evt-run-404/shell"), 404) == %{
             "error" => %{"code" => "run_not_found", "message" => "Run not found"}
           }

    assert json_response(get(build_conn(), "/api/v1/projects/alpha/runs/MT-ALPHA-1/events/evt-1/prompt"), 404) == %{
             "error" => %{"code" => "surface_not_available", "message" => "Event surface is unavailable"}
           }

    assert json_response(get(build_conn(), "/api/v1/projects/alpha/runs/MT-DUP/events/evt-dup"), 409) == %{
             "error" => %{"code" => "duplicate_run", "message" => "Multiple running entries matched this run"}
           }

    assert json_response(get(build_conn(), "/api/v1/projects/alpha/runs/MT-DOWN/events/evt-down/shell"), 503) == %{
             "error" => %{"code" => "event_surface_unavailable", "message" => "Run event surface is unavailable"}
           }
  end

  test "control-plane timeline api encodes issue identifier path segments" do
    manager_name = Module.concat(__MODULE__, TimelinePathEncodingManager)

    {:ok, port} =
      start_stub_http_server(fn
        "GET", "/api/v1/runs/MT%2FALPHA/timeline" ->
          {200,
           %{
             items: [%{event_id: "evt-encoded", summary: "encoded path"}],
             next_cursor: nil
           }}

        other_method, other_path ->
          {503, %{error: %{code: "timeline_unavailable", message: "#{other_method} #{other_path}"}}}
      end)

    start_supervised!({WorkerPortManagerStub, name: manager_name, worker_ports: %{"alpha" => port}})
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

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
            runtime_state: %{
              status: :running,
              run_summaries: [
                %{issue_identifier: "MT/ALPHA", title: "Encoded path run", linear_state: "In Progress"}
              ]
            }
          }
        ]
      }
    )

    assert {:ok,
            %{
              items: [
                %{
                  event_group: nil,
                  event_id: "evt-encoded",
                  event_type: nil,
                  source: nil,
                  status_markers: [],
                  summary: "encoded path",
                  timestamp: nil
                }
              ],
              next_cursor: nil
            }} =
             SymphonyElixirWeb.ObservabilityApiController.project_run_timeline_payload(
               "alpha",
               "MT/ALPHA"
             )
  end

  test "control-plane timeline api proxies when project exists even if run summary is absent" do
    manager_name = Module.concat(__MODULE__, TimelineProjectOnlyManager)

    {:ok, port} =
      start_stub_http_server(fn
        "GET", "/api/v1/runs/MT-MISSING-SUMMARY/timeline" ->
          {200, %{items: [%{event_id: "evt-project-only", summary: "project only"}], next_cursor: nil}}
      end)

    start_supervised!({WorkerPortManagerStub, name: manager_name, worker_ports: %{"alpha" => port}})
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

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
            runtime_state: %{status: :running, run_summaries: []}
          }
        ]
      }
    )

    assert json_response(get(build_conn(), "/api/v1/projects/alpha/runs/MT-MISSING-SUMMARY/timeline"), 200) == %{
             "items" => [
               %{
                 "event_group" => nil,
                 "event_id" => "evt-project-only",
                 "event_type" => nil,
                 "source" => nil,
                 "status_markers" => [],
                 "summary" => "project only",
                 "timestamp" => nil
               }
             ],
             "next_cursor" => nil
           }
  end

  test "control-plane context api maps worker responses and keeps project-only lookup semantics" do
    manager_name = Module.concat(__MODULE__, ContextApiManager)

    {:ok, port} =
      start_stub_http_server(fn
        "GET", "/api/v1/runs/MT-CONTEXT/context" ->
          {200,
           %{
             anchor: %{session_id: "thread-1-turn-2", thread_id: "thread-1", turn_id: "turn-2", turn_count: 2},
             conversation: %{items: [%{event_id: "evt-ctx-1", kind: "reasoning_summary", label: "reasoning", text: "compare options"}], truncated: false},
             continuation: %{status: "continuation_required", label: "continuation required", event_id: "evt-ctx-2"},
             issue_refresh: %{
               status: "issue_snapshot_changed",
               status_text: "issue_snapshot_changed",
               observed_changes: ["- title: \"Before\" -> \"After\""],
               updated_at_changed?: false,
               notes: []
             },
             tools: %{items: [%{event_id: "evt-ctx-3", tool: "shell", status: "completed", summary: "dynamic tool call completed (shell)"}]},
             shell: %{items: [%{event_id: "evt-ctx-4", kind: "exec_command", text: "git status --short"}]},
             subagents: %{items: [], status: "none_observed"}
           }}

        "GET", "/api/v1/runs/MT-CONTEXT-DUP/context" ->
          {409, %{error: %{code: "duplicate_run", message: "duplicate"}}}

        "GET", "/api/v1/runs/MT-CONTEXT-MISSING/context" ->
          {404, %{error: %{code: "run_not_found", message: "missing"}}}

        "GET", "/api/v1/runs/MT-CONTEXT-DOWN/context" ->
          {503, %{error: %{code: "context_unavailable", message: "down"}}}
      end)

    start_supervised!({WorkerPortManagerStub, name: manager_name, worker_ports: %{"alpha" => port}})
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

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
            runtime_state: %{status: :running, run_summaries: []}
          }
        ]
      }
    )

    assert {:ok, payload} =
             SymphonyElixirWeb.ObservabilityApiController.project_run_context_payload(
               "alpha",
               "MT-CONTEXT"
             )

    assert payload.anchor.turn_id == "turn-2"
    assert hd(payload.conversation.items).text == "compare options"
    assert payload.continuation.status == "continuation_required"
    assert payload.issue_refresh.status == "issue_snapshot_changed"
    assert payload.issue_refresh.status_text == "issue_snapshot_changed"
    assert payload.issue_refresh.observed_changes == ["- title: \"Before\" -> \"After\""]
    assert payload.issue_refresh.updated_at_changed? == false
    assert payload.issue_refresh.notes == []

    assert {:error, :duplicate_run} =
             SymphonyElixirWeb.ObservabilityApiController.project_run_context_payload(
               "alpha",
               "MT-CONTEXT-DUP"
             )

    assert {:error, :run_not_found} =
             SymphonyElixirWeb.ObservabilityApiController.project_run_context_payload(
               "alpha",
               "MT-CONTEXT-MISSING"
             )

    assert {:error, :context_unavailable} =
             SymphonyElixirWeb.ObservabilityApiController.project_run_context_payload(
               "alpha",
               "MT-CONTEXT-DOWN"
             )

    assert {:error, :project_not_found} =
             SymphonyElixirWeb.ObservabilityApiController.project_run_context_payload(
               "missing",
               "MT-CONTEXT"
             )

    assert json_response(get(build_conn(), "/api/v1/projects/alpha/runs/MT-CONTEXT/context"), 200)["anchor"]["turn_id"] == "turn-2"

    assert json_response(get(build_conn(), "/api/v1/projects/alpha/runs/MT-CONTEXT-DUP/context"), 409) == %{
             "error" => %{"code" => "duplicate_run", "message" => "Multiple running entries matched this run"}
           }

    assert json_response(get(build_conn(), "/api/v1/projects/alpha/runs/MT-CONTEXT-MISSING/context"), 404) == %{
             "error" => %{"code" => "run_not_found", "message" => "Run context not found"}
           }

    assert json_response(get(build_conn(), "/api/v1/projects/alpha/runs/MT-CONTEXT-DOWN/context"), 503) == %{
             "error" => %{"code" => "context_unavailable", "message" => "Run context is unavailable"}
           }
  end

  test "control-plane timeline api maps manager exit to timeline unavailable" do
    manager_name = Module.concat(__MODULE__, TimelineExitManager)

    {:ok, pid} =
      GenServer.start(WorkerPortManagerStub, [name: manager_name, worker_ports: %{"alpha" => 9_999}], name: manager_name)

    Process.exit(pid, :kill)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

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
            runtime_state: %{status: :running, run_summaries: []}
          }
        ]
      }
    )

    assert json_response(get(build_conn(), "/api/v1/projects/alpha/runs/MT-ALPHA-1/timeline"), 503) == %{
             "error" => %{"code" => "timeline_unavailable", "message" => "Run timeline is unavailable"}
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

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 250)

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

  test "dashboard liveview renders a workflow skeleton before the async snapshot finishes" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()

    {:ok, orchestrator_pid} =
      GatedSnapshotOrchestrator.start_link(
        name: orchestrator_name,
        test_pid: self()
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
    assert html =~ "Todo 池检验"
    assert html =~ "M3-0 预检"
    assert html =~ "Loading workflow snapshot"
    refute html =~ "Snapshot unavailable"
    refute html =~ "MT-HTTP"
    refute html =~ "MT-RETRY"

    assert_receive {:snapshot_requested, 1}

    send(orchestrator_pid, {:release_snapshot, 1, snapshot})

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "Running sessions" and
        rendered =~ "In Progress" and
        rendered =~ "reasoning summary streaming" and
        rendered =~ "codex_reasoning" and
        rendered =~ "normal" and
        rendered =~ "Copy ID" and
        rendered =~ "MT-HTTP" and
        rendered =~ "MT-RETRY" and
        refute_rendered_raw_activity?(rendered)
    end)
  end

  test "workflow dashboard keeps loading distinct from an actual empty snapshot" do
    orchestrator_name = Module.concat(__MODULE__, :EmptyDashboardOrchestrator)

    empty_snapshot = %{
      running: [],
      retrying: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }

    {:ok, orchestrator_pid} =
      GatedSnapshotOrchestrator.start_link(
        name: orchestrator_name,
        test_pid: self()
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 250)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Loading workflow snapshot"
    assert html =~ "Projects"
    assert html =~ "Todo 池检验"

    assert_receive {:snapshot_requested, 1}

    send(orchestrator_pid, {:release_snapshot, 1, empty_snapshot})

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "No active sessions." and
        not String.contains?(rendered, "Loading workflow snapshot")
    end)
  end

  test "workflow dashboard shows the first ready snapshot before draining a pending refresh" do
    orchestrator_name = Module.concat(__MODULE__, :StaleDashboardOrchestrator)

    first_snapshot = %{
      running: [
        %{
          issue_id: "issue-old",
          identifier: "MT-OLD",
          title: "Old snapshot",
          state: "In Progress",
          linear_state: "In Progress",
          current_phase: "codex_reasoning",
          current_action: "old snapshot",
          health: "normal",
          session_id: "thread-old",
          turn_id: "turn-old",
          turn_count: 1,
          started_at: DateTime.utc_now(),
          last_codex_event: nil,
          last_codex_message: nil,
          last_codex_timestamp: nil,
          codex_input_tokens: 1,
          codex_output_tokens: 1,
          codex_total_tokens: 2
        }
      ],
      retrying: [],
      codex_totals: %{input_tokens: 1, output_tokens: 1, total_tokens: 2, seconds_running: 1},
      rate_limits: nil
    }

    second_snapshot = %{
      running: [
        %{
          issue_id: "issue-new",
          identifier: "MT-NEW",
          title: "New snapshot",
          state: "In Progress",
          linear_state: "In Progress",
          current_phase: "codex_reasoning",
          current_action: "new snapshot",
          health: "normal",
          session_id: "thread-new",
          turn_id: "turn-new",
          turn_count: 2,
          started_at: DateTime.utc_now(),
          last_codex_event: nil,
          last_codex_message: nil,
          last_codex_timestamp: nil,
          codex_input_tokens: 3,
          codex_output_tokens: 4,
          codex_total_tokens: 7
        }
      ],
      retrying: [],
      codex_totals: %{input_tokens: 3, output_tokens: 4, total_tokens: 7, seconds_running: 2},
      rate_limits: nil
    }

    {:ok, orchestrator_pid} =
      GatedSnapshotOrchestrator.start_link(
        name: orchestrator_name,
        test_pid: self()
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 250)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Loading workflow snapshot"

    assert_receive {:snapshot_requested, 1}

    send(view.pid, :observability_updated)
    refute_receive {:snapshot_requested, 2}, 50

    send(orchestrator_pid, {:release_snapshot, 1, first_snapshot})
    assert_receive {:snapshot_requested, 2}

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "MT-OLD" and rendered =~ "Running sessions" and
        not String.contains?(rendered, "Loading workflow snapshot")
    end)

    send(orchestrator_pid, {:release_snapshot, 2, second_snapshot})

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "MT-NEW" and rendered =~ "Running sessions" and
        not String.contains?(rendered, "MT-OLD")
    end)
  end

  test "workflow dashboard keeps showing the last snapshot while a refresh is in flight" do
    orchestrator_name = Module.concat(__MODULE__, :RefreshDisplayDashboardOrchestrator)

    first_snapshot = %{
      running: [
        %{
          issue_id: "issue-visible",
          identifier: "MT-VISIBLE",
          title: "Visible snapshot",
          state: "In Progress",
          linear_state: "In Progress",
          current_phase: "codex_reasoning",
          current_action: "visible snapshot",
          health: "normal",
          session_id: "thread-visible",
          turn_id: "turn-visible",
          turn_count: 2,
          started_at: DateTime.utc_now(),
          last_codex_event: nil,
          last_codex_message: nil,
          last_codex_timestamp: nil,
          codex_input_tokens: 2,
          codex_output_tokens: 3,
          codex_total_tokens: 5
        }
      ],
      retrying: [],
      codex_totals: %{input_tokens: 2, output_tokens: 3, total_tokens: 5, seconds_running: 2},
      rate_limits: nil
    }

    second_snapshot = %{
      running: [
        %{
          issue_id: "issue-refreshed",
          identifier: "MT-REFRESHED",
          title: "Refreshed snapshot",
          state: "In Progress",
          linear_state: "In Progress",
          current_phase: "codex_reasoning",
          current_action: "refreshed snapshot",
          health: "normal",
          session_id: "thread-refreshed",
          turn_id: "turn-refreshed",
          turn_count: 3,
          started_at: DateTime.utc_now(),
          last_codex_event: nil,
          last_codex_message: nil,
          last_codex_timestamp: nil,
          codex_input_tokens: 3,
          codex_output_tokens: 5,
          codex_total_tokens: 8
        }
      ],
      retrying: [],
      codex_totals: %{input_tokens: 3, output_tokens: 5, total_tokens: 8, seconds_running: 3},
      rate_limits: nil
    }

    {:ok, orchestrator_pid} =
      GatedSnapshotOrchestrator.start_link(
        name: orchestrator_name,
        test_pid: self()
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, _html} = live(build_conn(), "/")
    assert_receive {:snapshot_requested, 1}
    send(orchestrator_pid, {:release_snapshot, 1, first_snapshot})

    assert_eventually(fn ->
      rendered = render(view)
      rendered =~ "MT-VISIBLE" and not String.contains?(rendered, "Loading workflow snapshot")
    end)

    send(view.pid, :observability_updated)
    assert_receive {:snapshot_requested, 2}

    rendered_during_refresh = render(view)
    assert rendered_during_refresh =~ "MT-VISIBLE"
    refute rendered_during_refresh =~ "Loading workflow snapshot"

    send(orchestrator_pid, {:release_snapshot, 2, second_snapshot})

    assert_eventually(fn ->
      rendered = render(view)
      rendered =~ "MT-REFRESHED" and not String.contains?(rendered, "MT-VISIBLE")
    end)
  end

  test "workflow dashboard keeps loading when an initial error arrives with a pending refresh" do
    orchestrator_name = Module.concat(__MODULE__, :PendingErrorDashboardOrchestrator)

    recovery_snapshot = %{
      running: [
        %{
          issue_id: "issue-after-error",
          identifier: "MT-AFTER-ERROR",
          title: "After error snapshot",
          state: "In Progress",
          linear_state: "In Progress",
          current_phase: "codex_reasoning",
          current_action: "after error snapshot",
          health: "normal",
          session_id: "thread-after-error",
          turn_id: "turn-after-error",
          turn_count: 2,
          started_at: DateTime.utc_now(),
          last_codex_event: nil,
          last_codex_message: nil,
          last_codex_timestamp: nil,
          codex_input_tokens: 2,
          codex_output_tokens: 3,
          codex_total_tokens: 5
        }
      ],
      retrying: [],
      codex_totals: %{input_tokens: 2, output_tokens: 3, total_tokens: 5, seconds_running: 2},
      rate_limits: nil
    }

    timeout_payload = %{
      running: [],
      retrying: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil,
      error: %{code: "snapshot_timeout", message: "Snapshot timed out"}
    }

    {:ok, orchestrator_pid} =
      GatedSnapshotOrchestrator.start_link(
        name: orchestrator_name,
        test_pid: self()
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 250)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Loading workflow snapshot"
    assert_receive {:snapshot_requested, 1}

    send(view.pid, :observability_updated)
    refute_receive {:snapshot_requested, 2}, 50

    send(orchestrator_pid, {:release_snapshot, 1, timeout_payload})
    assert_receive {:snapshot_requested, 2}

    rendered_after_timeout = render(view)
    refute rendered_after_timeout =~ "snapshot_timeout"
    refute rendered_after_timeout =~ "Snapshot timed out"

    send(orchestrator_pid, {:release_snapshot, 2, recovery_snapshot})

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "MT-AFTER-ERROR" and
        not String.contains?(rendered, "Loading workflow snapshot") and
        not String.contains?(rendered, "snapshot_timeout")
    end)
  end

  test "workflow dashboard recovers from a crashed initial snapshot task and drains pending refreshes" do
    orchestrator_name = Module.concat(__MODULE__, :CrashingDashboardOrchestrator)

    recovery_snapshot = %{
      running: [
        %{
          issue_id: "issue-recovered",
          identifier: "MT-RECOVERED",
          title: "Recovered snapshot",
          state: "In Progress",
          linear_state: "In Progress",
          current_phase: "codex_reasoning",
          current_action: "recovered snapshot",
          health: "normal",
          session_id: "thread-recovered",
          turn_id: "turn-recovered",
          turn_count: 2,
          started_at: DateTime.utc_now(),
          last_codex_event: nil,
          last_codex_message: nil,
          last_codex_timestamp: nil,
          codex_input_tokens: 2,
          codex_output_tokens: 3,
          codex_total_tokens: 5
        }
      ],
      retrying: [],
      codex_totals: %{input_tokens: 2, output_tokens: 3, total_tokens: 5, seconds_running: 2},
      rate_limits: nil
    }

    {:ok, orchestrator_pid} =
      CrashingSnapshotOrchestrator.start_link(
        name: orchestrator_name,
        test_pid: self()
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 250)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Loading workflow snapshot"
    assert_receive {:snapshot_requested, 1}

    send(view.pid, :observability_updated)
    assert_receive {:snapshot_requested, 2}

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "Snapshot unavailable" and rendered =~ "snapshot_unavailable" and
        not String.contains?(rendered, "Loading workflow snapshot")
    end)

    send(orchestrator_pid, {:release_snapshot, 2, recovery_snapshot})

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "MT-RECOVERED" and not String.contains?(rendered, "Loading workflow snapshot") and
        not String.contains?(rendered, "Snapshot unavailable")
    end)
  end

  test "workflow dashboard ignores stale task messages that do not match the current snapshot task" do
    orchestrator_name = Module.concat(__MODULE__, :StaleTaskMessageDashboardOrchestrator)

    visible_snapshot = %{
      running: [
        %{
          issue_id: "issue-visible",
          identifier: "MT-VISIBLE",
          title: "Visible snapshot",
          state: "In Progress",
          linear_state: "In Progress",
          current_phase: "codex_reasoning",
          current_action: "visible snapshot",
          health: "normal",
          session_id: "thread-visible",
          turn_id: "turn-visible",
          turn_count: 2,
          started_at: DateTime.utc_now(),
          last_codex_event: nil,
          last_codex_message: nil,
          last_codex_timestamp: nil,
          codex_input_tokens: 2,
          codex_output_tokens: 3,
          codex_total_tokens: 5
        }
      ],
      retrying: [],
      codex_totals: %{input_tokens: 2, output_tokens: 3, total_tokens: 5, seconds_running: 2},
      rate_limits: nil
    }

    stale_snapshot = %{
      running: [
        %{
          issue_id: "issue-stale",
          identifier: "MT-STALE",
          title: "Stale snapshot",
          state: "In Progress",
          linear_state: "In Progress",
          current_phase: "codex_reasoning",
          current_action: "stale snapshot",
          health: "normal",
          session_id: "thread-stale",
          turn_id: "turn-stale",
          turn_count: 1,
          started_at: DateTime.utc_now(),
          last_codex_event: nil,
          last_codex_message: nil,
          last_codex_timestamp: nil,
          codex_input_tokens: 1,
          codex_output_tokens: 1,
          codex_total_tokens: 2
        }
      ],
      retrying: [],
      codex_totals: %{input_tokens: 1, output_tokens: 1, total_tokens: 2, seconds_running: 1},
      rate_limits: nil
    }

    {:ok, orchestrator_pid} =
      GatedSnapshotOrchestrator.start_link(
        name: orchestrator_name,
        test_pid: self()
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 250)

    {:ok, view, _html} = live(build_conn(), "/")
    assert_receive {:snapshot_requested, 1}
    send(orchestrator_pid, {:release_snapshot, 1, visible_snapshot})

    assert_eventually(fn ->
      rendered = render(view)
      rendered =~ "MT-VISIBLE" and not String.contains?(rendered, "Loading workflow snapshot")
    end)

    send(view.pid, {make_ref(), {99, stale_snapshot}})

    assert_eventually(fn ->
      rendered = render(view)
      rendered =~ "MT-VISIBLE" and not String.contains?(rendered, "MT-STALE")
    end)
  end

  test "workflow dashboard coalesces repeated refresh events until the in-flight snapshot completes" do
    orchestrator_name = Module.concat(__MODULE__, :CoalescedRefreshDashboardOrchestrator)

    first_snapshot = %{
      running: [
        %{
          issue_id: "issue-first",
          identifier: "MT-FIRST",
          title: "First snapshot",
          state: "In Progress",
          linear_state: "In Progress",
          current_phase: "codex_reasoning",
          current_action: "first snapshot",
          health: "normal",
          session_id: "thread-first",
          turn_id: "turn-first",
          turn_count: 1,
          started_at: DateTime.utc_now(),
          last_codex_event: nil,
          last_codex_message: nil,
          last_codex_timestamp: nil,
          codex_input_tokens: 1,
          codex_output_tokens: 1,
          codex_total_tokens: 2
        }
      ],
      retrying: [],
      codex_totals: %{input_tokens: 1, output_tokens: 1, total_tokens: 2, seconds_running: 1},
      rate_limits: nil
    }

    coalesced_snapshot = %{
      running: [
        %{
          issue_id: "issue-coalesced",
          identifier: "MT-COALESCED",
          title: "Coalesced snapshot",
          state: "In Progress",
          linear_state: "In Progress",
          current_phase: "codex_reasoning",
          current_action: "coalesced snapshot",
          health: "normal",
          session_id: "thread-coalesced",
          turn_id: "turn-coalesced",
          turn_count: 2,
          started_at: DateTime.utc_now(),
          last_codex_event: nil,
          last_codex_message: nil,
          last_codex_timestamp: nil,
          codex_input_tokens: 2,
          codex_output_tokens: 3,
          codex_total_tokens: 5
        }
      ],
      retrying: [],
      codex_totals: %{input_tokens: 2, output_tokens: 3, total_tokens: 5, seconds_running: 2},
      rate_limits: nil
    }

    final_snapshot = %{
      running: [
        %{
          issue_id: "issue-final",
          identifier: "MT-FINAL",
          title: "Final snapshot",
          state: "In Progress",
          linear_state: "In Progress",
          current_phase: "codex_reasoning",
          current_action: "final snapshot",
          health: "normal",
          session_id: "thread-final",
          turn_id: "turn-final",
          turn_count: 3,
          started_at: DateTime.utc_now(),
          last_codex_event: nil,
          last_codex_message: nil,
          last_codex_timestamp: nil,
          codex_input_tokens: 4,
          codex_output_tokens: 5,
          codex_total_tokens: 9
        }
      ],
      retrying: [],
      codex_totals: %{input_tokens: 4, output_tokens: 5, total_tokens: 9, seconds_running: 3},
      rate_limits: nil
    }

    {:ok, orchestrator_pid} =
      GatedSnapshotOrchestrator.start_link(
        name: orchestrator_name,
        test_pid: self()
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 250)

    {:ok, view, _html} = live(build_conn(), "/")
    assert_receive {:snapshot_requested, 1}
    send(orchestrator_pid, {:release_snapshot, 1, first_snapshot})

    assert_eventually(fn ->
      rendered = render(view)
      rendered =~ "MT-FIRST" and not String.contains?(rendered, "Loading workflow snapshot")
    end)

    send(view.pid, :observability_updated)
    assert_receive {:snapshot_requested, 2}
    send(view.pid, :observability_updated)
    send(view.pid, :observability_updated)

    refute_receive {:snapshot_requested, 3}, 10

    send(orchestrator_pid, {:release_snapshot, 2, coalesced_snapshot})
    assert_receive {:snapshot_requested, 3}
    refute_receive {:snapshot_requested, 4}, 10

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "MT-FIRST" and not String.contains?(rendered, "MT-COALESCED")
    end)

    send(orchestrator_pid, {:release_snapshot, 3, final_snapshot})

    assert_eventually(fn ->
      rendered = render(view)
      rendered =~ "MT-FINAL" and not String.contains?(rendered, "Loading workflow snapshot")
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

  test "control-plane dashboard keeps run details out of the homepage" do
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
            runtime_state: %{
              status: :running,
              run_summaries: [
                %{
                  issue_identifier: "MT-ALPHA-1",
                  title: "Alpha task",
                  linear_state: "In Progress",
                  current_phase: "codex_waiting_next_event",
                  current_action: "最近一段时间没有新事件",
                  health: "possibly_stalled",
                  session_id: "thread-alpha-turn-9",
                  thread_id: "thread-alpha",
                  turn_id: "turn-9",
                  turn_count: 9,
                  last_event_at: ~U[2026-05-14 02:00:00Z],
                  run_duration_seconds: 960,
                  last_error: "tool_call_failed"
                }
              ]
            }
          }
        ]
      }
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "View details"
    assert html =~ "/projects/alpha"
    refute html =~ "线程状态"
    refute html =~ "MT-ALPHA-1"
    refute html =~ "Alpha task"
    refute html =~ "codex_waiting_next_event"
    refute html =~ "最近一段时间没有新事件"
    refute html =~ "possibly_stalled"
    refute html =~ "thread-alpha"
    refute html =~ "turn-9"
    refute html =~ "thread-alpha-turn-9"
    refute html =~ "960s"
    refute html =~ "tool_call_failed"
    refute html =~ "Recent events"
    refute html =~ "Prompt"
    refute html =~ "Shell output"
    refute html =~ "Timeline"
  end

  test "control-plane dashboard exposes a clear entry to project detail pages" do
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
            runtime_state: %{status: :running}
          }
        ]
      }
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "/projects/alpha"
    assert html =~ "View details"
    refute html =~ "/projects/alpha/runs/"
  end

  test "project detail page stays lightweight and links each run to a deep view" do
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
            runtime_state: %{
              status: :running,
              run_summaries: [
                %{
                  issue_identifier: "MT-ALPHA-1",
                  title: "Alpha task",
                  linear_state: "In Progress",
                  current_phase: "codex_waiting_next_event",
                  current_action: "最近一段时间没有新事件",
                  health: "possibly_stalled",
                  session_id: "thread-alpha-turn-9",
                  thread_id: "thread-alpha",
                  turn_id: "turn-9",
                  turn_count: 9,
                  last_event_at: ~U[2026-05-14 02:00:00Z],
                  run_duration_seconds: 960,
                  last_error: "tool_call_failed"
                }
              ]
            }
          }
        ]
      }
    )

    {:ok, _view, html} = live(build_conn(), "/projects/alpha")
    assert html =~ "Alpha"
    assert html =~ "MT-ALPHA-1"
    assert html =~ "Alpha task"
    assert html =~ "codex_waiting_next_event"
    assert html =~ "最近一段时间没有新事件"
    assert html =~ "possibly_stalled"
    assert html =~ "thread-alpha"
    assert html =~ "turn-9"
    assert html =~ "960s"
    assert html =~ "/projects/alpha/runs/MT-ALPHA-1"
    assert html =~ "Open run"
    refute html =~ "Timeline"
    refute html =~ "Shell output"
    refute html =~ "Prompt"
    refute html =~ "Raw event"
  end

  test "project detail page encodes run detail path segments" do
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
            runtime_state: %{
              status: :running,
              run_summaries: [
                %{
                  issue_identifier: "MT/ALPHA",
                  title: "Encoded alpha task",
                  linear_state: "In Progress"
                }
              ]
            }
          }
        ]
      }
    )

    {:ok, _view, html} = live(build_conn(), "/projects/alpha")
    {:ok, document} = Floki.parse_document(html)

    assert ["/projects/alpha/runs/MT%2FALPHA"] =
             document
             |> Floki.find("a.issue-link")
             |> Floki.attribute("href")
  end

  test "project detail page shows unavailable state when project summary is missing" do
    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer,
      project_registry: %StaticProjectRegistry{entries: []}
    )

    {:ok, _view, html} = live(build_conn(), "/projects/missing")
    assert html =~ "Project unavailable"
    assert html =~ "No lightweight project summary matched"
    assert html =~ "missing"
  end

  test "project detail page renders presenter-backed empty summary fields as n/a and keeps empty run lists lightweight" do
    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer,
      project_registry: %StaticProjectRegistry{
        entries: [
          %{
            project_id: "alpha",
            project_name: "Alpha",
            normalized_config: %{enabled: true, worker_port: ""},
            validation_result: :valid,
            validation_errors: [],
            runtime_state: %{status: :running, last_seen_at: "", last_error: "", run_summaries: []}
          }
        ]
      }
    )

    {:ok, _view, html} = live(build_conn(), "/projects/alpha")
    {:ok, document} = Floki.parse_document(html)

    assert project_section_texts(document, "Project summary") |> Enum.member?("worker port: n/a")
    assert project_section_texts(document, "Project summary") |> Enum.member?("last seen: n/a")
    assert project_section_texts(document, "Project summary") |> Enum.member?("last error: n/a")
    assert run_summaries_empty_state_text(document) == "No run summaries available."
  end

  test "project detail page renders empty run action text as n/a" do
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
            runtime_state: %{
              status: :running,
              run_summaries: [
                %{
                  issue_identifier: "MT-ALPHA-1",
                  title: "Alpha task",
                  linear_state: "In Progress",
                  current_phase: "codex_waiting_next_event",
                  current_action: "",
                  health: "normal",
                  thread_id: "thread-alpha",
                  turn_id: "turn-9",
                  last_event_at: ~U[2026-05-14 02:00:00Z],
                  run_duration_seconds: 960
                }
              ]
            }
          }
        ]
      }
    )

    {:ok, _view, html} = live(build_conn(), "/projects/alpha")
    {:ok, document} = Floki.parse_document(html)

    assert [
             {"article", _, _} = article
           ] = Floki.find(document, "article.section-card")

    assert Floki.text(article) =~ "MT-ALPHA-1"
    assert Floki.text(article) =~ "Alpha task"
    assert article_mono_texts(article) |> Enum.member?("n/a")
  end

  test "run deep view renders summary fields and timeline shell without heavy content by default" do
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
            runtime_state: %{
              status: :running,
              run_summaries: [
                %{
                  issue_identifier: "MT-ALPHA-1",
                  title: "Alpha task",
                  linear_state: "In Progress",
                  current_phase: "codex_waiting_next_event",
                  current_action: "最近一段时间没有新事件",
                  health: "possibly_stalled",
                  session_id: "thread-alpha-turn-9",
                  thread_id: "thread-alpha",
                  turn_id: "turn-9",
                  turn_count: 9,
                  last_event_at: ~U[2026-05-14 02:00:00Z],
                  run_duration_seconds: 960,
                  last_error: "tool_call_failed"
                }
              ]
            }
          }
        ]
      }
    )

    {:ok, _view, html} = live(build_conn(), "/projects/alpha/runs/MT-ALPHA-1")
    assert html =~ "MT-ALPHA-1"
    assert html =~ "Alpha task"
    assert html =~ "In Progress"
    assert html =~ "codex_waiting_next_event"
    assert html =~ "最近一段时间没有新事件"
    assert html =~ "possibly_stalled"
    assert html =~ "thread-alpha"
    assert html =~ "turn-9"
    assert html =~ "2026-05-14T02:00:00Z"
    assert html =~ "960s"
    assert html =~ "Timeline"
    assert html =~ "Event Detail"
    assert html =~ "Context"
    assert html =~ "Context unavailable"
    assert html =~ "Overview"
    assert html =~ "Action Needed"
    assert html =~ "Timeline unavailable"
    refute html =~ "Raw event"
    refute html =~ "Prompt"
    refute html =~ "Shell output"
    refute html =~ "notification"
    refute html =~ "rendered"
  end

  test "run deep view shows project unavailable when the project is missing" do
    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer,
      project_registry: %StaticProjectRegistry{entries: []}
    )

    {:ok, _view, html} = live(build_conn(), "/projects/missing/runs/MT-ALPHA-1")
    assert html =~ "Project unavailable"
    assert html =~ "No project matched"
    assert html =~ "missing"
  end

  test "run deep view renders integer and empty summary values with active badge state" do
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
            runtime_state: %{
              status: :running,
              run_summaries: [
                %{
                  issue_identifier: "MT-ALPHA-1",
                  title: "Alpha task",
                  linear_state: "running",
                  current_phase: nil,
                  current_action: "",
                  health: nil,
                  thread_id: nil,
                  turn_id: 7,
                  last_event_at: nil,
                  run_duration_seconds: 960
                }
              ]
            }
          }
        ]
      }
    )

    {:ok, _view, html} = live(build_conn(), "/projects/alpha/runs/MT-ALPHA-1")
    {:ok, document} = Floki.parse_document(html)

    assert [
             {"span", attributes, _}
           ] = Floki.find(document, "header.hero-card div.status-stack span.state-badge")

    assert attributes |> Enum.into(%{}) |> Map.fetch!("class") =~ "state-badge-active"
    assert summary_row_text(document, "linear_state") == "linear_state: running"
    assert summary_row_text(document, "current_phase") == "current_phase: n/a"
    assert summary_row_text(document, "current_action") == "current_action: n/a"
    assert summary_row_text(document, "health") == "health: n/a"
    assert summary_row_text(document, "thread_id") == "thread_id: n/a"
    assert summary_row_text(document, "turn_id") == "turn_id: 7"
    assert summary_row_text(document, "last_event_at") == "last_event_at: n/a"
    assert summary_row_text(document, "run_duration_seconds") == "run_duration_seconds: 960s"
  end

  @tag :run_live_product
  test "run deep view renders product sections, fixed counts, and static default expansion" do
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
            runtime_state: %{
              status: :running,
              run_summaries: [
                %{
                  issue_identifier: "MT-PRODUCT-1",
                  title: "Product task",
                  linear_state: "In Progress",
                  current_phase: "codex_waiting_next_event",
                  current_action: "waiting for a follow-up",
                  health: "needs_attention",
                  blocked_by: [
                    %{
                      issue_identifier: "MT-BLOCKER-1",
                      title: "Blocker one",
                      linear_state: "In Progress",
                      url: "https://linear.app/example/issue/MT-BLOCKER-1"
                    }
                  ],
                  blocks: [
                    %{
                      issue_identifier: "MT-BLOCKED-1",
                      title: "Blocked child",
                      linear_state: "Todo",
                      url: "https://linear.app/example/issue/MT-BLOCKED-1"
                    }
                  ],
                  attention_items: [
                    %{kind: "needs_attention", message: "Primary follow-up required."},
                    %{kind: "blocked", message: "Secondary queue signal."}
                  ]
                }
              ]
            }
          }
        ]
      }
    )

    {:ok, _view, html} = live(build_conn(), "/projects/alpha/runs/MT-PRODUCT-1")
    document = Floki.parse_document!(html)

    assert find_section_by_title(document, "Overview")
    assert find_section_by_title(document, "Action Needed")
    assert find_section_by_title(document, "Timeline")
    assert find_section_by_title(document, "Context")
    assert find_section_by_title(document, "Event Detail")

    assert metric_value(document, "Attention") == "2"
    assert metric_value(document, "Blocked by") == "1"
    assert metric_value(document, "Blocks") == "1"
    assert action_needed_primary_text(document) == "Primary follow-up required."
    assert section_expanded?(document, "Overview")
    assert section_expanded?(document, "Action Needed")
    assert section_expanded?(document, "Timeline")
    refute section_expanded?(document, "Context")
    refute section_expanded?(document, "Event Detail")
    assert html =~ "Choose an event to inspect details."
  end

  @tag :run_live_product
  test "run deep view keeps checking action-needed empty state and placeholder blockers visible" do
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
            runtime_state: %{
              status: :running,
              run_summaries: [
                %{
                  issue_identifier: "MT-CHECKING-PRODUCT",
                  title: "Checking task",
                  linear_state: "Checking",
                  current_phase: "checking_tracker_state",
                  current_action: "bounded recheck queued",
                  health: "normal",
                  blocked_by: [
                    %{
                      title: "External blocker",
                      linear_state: "Todo",
                      url: "https://linear.app/example/issue/EXT-BLOCKER"
                    }
                  ],
                  attention_items: []
                }
              ]
            }
          }
        ]
      }
    )

    {:ok, _view, html} = live(build_conn(), "/projects/alpha/runs/MT-CHECKING-PRODUCT")
    document = Floki.parse_document!(html)

    assert action_needed_primary_text(document) == "No action needed."
    refute Floki.text(find_section_by_title(document, "Action Needed")) =~ "bounded recheck queued"
    assert Floki.text(find_section_by_title(document, "Action Needed")) =~ "External blocker"
    assert Floki.text(find_section_by_title(document, "Action Needed")) =~ "Todo"
  end

  @tag :run_live_product
  test "run deep view keeps event detail in entry state until an event is selected" do
    manager_name = Module.concat(__MODULE__, RunLiveProductEntryManager)

    {:ok, port} =
      start_stub_http_server(fn
        "GET", "/api/v1/runs/MT-DETAIL-ENTRY/timeline" ->
          {200,
           %{
             items: [
               %{
                 event_id: "evt-entry",
                 timestamp: "2026-05-14T02:00:00Z",
                 source: "codex",
                 event_group: "turn",
                 summary: "entry event",
                 event_type: "turn_completed",
                 status_markers: []
               }
             ],
             next_cursor: nil
           }}
      end)

    start_supervised!({WorkerPortManagerStub, name: manager_name, worker_ports: %{"alpha" => port}})
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer,
      project_registry: run_live_project_registry("MT-DETAIL-ENTRY", "Entry detail")
    )

    {:ok, view, _html} = live(build_conn(), "/projects/alpha/runs/MT-DETAIL-ENTRY")

    assert_eventually(fn ->
      rendered = render(view)
      rendered =~ "entry event" and rendered =~ "Choose an event to inspect details."
    end)

    refute render(view) =~ "event_id: evt-entry"
  end

  @tag :run_live_product
  test "run deep view reapplies the active timeline filter after load more" do
    manager_name = Module.concat(__MODULE__, RunLiveProductTimelineFilterManager)

    {:ok, port} =
      start_stub_http_server(fn
        "GET", "/api/v1/runs/MT-FILTER/timeline" ->
          {200,
           %{
             items: [
               %{
                 event_id: "evt-attention-1",
                 timestamp: "2026-05-14T02:00:00Z",
                 source: "codex",
                 event_group: "turn",
                 summary: "attention event 1",
                 event_type: "turn_completed",
                 status_markers: ["attention"]
               },
               %{
                 event_id: "evt-session",
                 timestamp: "2026-05-14T02:01:00Z",
                 source: "codex",
                 event_group: "session",
                 summary: "session event",
                 event_type: "session_started",
                 status_markers: []
               }
             ],
             next_cursor: "older"
           }}

        "GET", "/api/v1/runs/MT-FILTER/timeline?cursor=older" ->
          {200,
           %{
             items: [
               %{
                 event_id: "evt-attention-2",
                 timestamp: "2026-05-14T01:59:00Z",
                 source: "codex",
                 event_group: "turn",
                 summary: "attention event 2",
                 event_type: "run_result",
                 status_markers: ["attention"]
               },
               %{
                 event_id: "evt-run-result",
                 timestamp: "2026-05-14T01:58:00Z",
                 source: "codex",
                 event_group: "turn",
                 summary: "run result event",
                 event_type: "run_result",
                 status_markers: []
               }
             ],
             next_cursor: nil
           }}
      end)

    start_supervised!({WorkerPortManagerStub, name: manager_name, worker_ports: %{"alpha" => port}})
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer,
      project_registry: run_live_project_registry("MT-FILTER", "Filter run")
    )

    {:ok, view, _html} = live(build_conn(), "/projects/alpha/runs/MT-FILTER")

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "attention event 1" and rendered =~ "session event" and
        rendered =~ "All" and rendered =~ "Attention" and rendered =~ "Retry" and
        rendered =~ "Session" and rendered =~ "Turn completed" and rendered =~ "Run result"
    end)

    render_click(element(view, "button[phx-click='set_timeline_filter'][phx-value-filter='attention']"))

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "attention event 1" and
        not String.contains?(rendered, "session event") and
        not String.contains?(rendered, "run result event")
    end)

    render_click(view, "load_more_timeline")

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "attention event 1" and rendered =~ "attention event 2" and
        not String.contains?(rendered, "session event") and
        not String.contains?(rendered, "run result event")
    end)
  end

  @tag :run_live_product
  test "run deep view ignores unknown section toggles and falls back invalid timeline filters to all" do
    manager_name = Module.concat(__MODULE__, RunLiveProductInvalidFilterManager)

    {:ok, port} =
      start_stub_http_server(fn
        "GET", "/api/v1/runs/MT-INVALID-FILTER/timeline" ->
          {200,
           %{
             items: [
               %{
                 event_id: "evt-invalid-filter",
                 timestamp: "2026-05-14T02:00:00Z",
                 source: "codex",
                 event_group: "turn",
                 summary: "baseline event",
                 event_type: "turn_completed",
                 status_markers: []
               }
             ],
             next_cursor: nil
           }}
      end)

    start_supervised!({WorkerPortManagerStub, name: manager_name, worker_ports: %{"alpha" => port}})
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer,
      project_registry: run_live_project_registry("MT-INVALID-FILTER", "Invalid filter run")
    )

    {:ok, view, _html} = live(build_conn(), "/projects/alpha/runs/MT-INVALID-FILTER")

    assert_eventually(fn ->
      render(view) =~ "baseline event"
    end)

    render_click(view, "toggle_section", %{"section" => "unknown_section"})
    assert render(view) =~ "baseline event"

    render_click(view, "set_timeline_filter", %{"filter" => "invalid-filter"})

    assert_eventually(fn ->
      rendered = render(view)
      rendered =~ "baseline event" and rendered =~ "Turn completed"
    end)
  end

  @tag :run_live_product
  test "run deep view covers remaining timeline filters and dependency display fallbacks" do
    manager_name = Module.concat(__MODULE__, RunLiveProductCoverageManager)

    {:ok, port} =
      start_stub_http_server(fn
        "GET", "/api/v1/runs/MT-COVERAGE/timeline" ->
          {200,
           %{
             items: [
               %{
                 event_id: "evt-retry",
                 timestamp: "2026-05-14T02:00:00Z",
                 source: "orchestrator",
                 event_group: "retry",
                 summary: "retry event",
                 event_type: "retry_scheduled",
                 status_markers: []
               },
               %{
                 event_id: "evt-session-filter",
                 timestamp: "2026-05-14T02:01:00Z",
                 source: "codex",
                 event_group: "session",
                 summary: "session filter event",
                 event_type: "session_started",
                 status_markers: []
               },
               %{
                 event_id: "evt-turn-filter",
                 timestamp: "2026-05-14T02:02:00Z",
                 source: "codex",
                 event_group: "turn",
                 summary: "turn filter event",
                 event_type: "turn_completed",
                 status_markers: []
               },
               %{
                 event_id: "evt-run-result-filter",
                 timestamp: "2026-05-14T02:03:00Z",
                 source: "codex",
                 event_group: "result",
                 summary: "run result filter event",
                 event_type: "run_result",
                 status_markers: []
               }
             ],
             next_cursor: nil
           }}
      end)

    start_supervised!({WorkerPortManagerStub, name: manager_name, worker_ports: %{"alpha" => port}})
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

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
            runtime_state: %{
              status: :running,
              run_summaries: [
                %{
                  issue_identifier: "MT-COVERAGE",
                  title: "Coverage run",
                  linear_state: "In Progress",
                  current_phase: "codex_waiting_next_event",
                  current_action: "coverage sweep",
                  health: "normal",
                  blocked_by: [
                    %{url: "https://linear.app/example/issue/URL-ONLY"},
                    %{title: "Title only blocker", linear_state: "Todo"},
                    "ignore me"
                  ],
                  blocks: [],
                  attention_items: []
                }
              ]
            }
          }
        ]
      }
    )

    {:ok, view, _html} = live(build_conn(), "/projects/alpha/runs/MT-COVERAGE")

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "retry event" and rendered =~ "session filter event" and rendered =~ "turn filter event" and
        rendered =~ "run result filter event"
    end)

    render_click(element(view, "button[phx-click='set_timeline_filter'][phx-value-filter='retry']"))
    assert_eventually(fn -> render(view) =~ "retry event" end)
    refute render(view) =~ "session filter event"

    render_click(element(view, "button[phx-click='set_timeline_filter'][phx-value-filter='session']"))
    assert_eventually(fn -> render(view) =~ "session filter event" end)
    refute render(view) =~ "retry event"

    render_click(element(view, "button[phx-click='set_timeline_filter'][phx-value-filter='turn_completed']"))
    assert_eventually(fn -> render(view) =~ "turn filter event" end)
    refute render(view) =~ "run result filter event"

    render_click(element(view, "button[phx-click='set_timeline_filter'][phx-value-filter='run_result']"))
    assert_eventually(fn -> render(view) =~ "run result filter event" end)
    refute render(view) =~ "turn filter event"

    document = Floki.parse_document!(render(view))
    action_needed_text = Floki.text(find_section_by_title(document, "Action Needed"))

    assert action_needed_text =~ "Related issue"
    assert action_needed_text =~ "Title only blocker"
    assert action_needed_text =~ "Todo"
    refute action_needed_text =~ "ignore me"

    links =
      document
      |> find_section_by_title("Action Needed")
      |> Floki.find("a.issue-link")
      |> Enum.map(&Floki.attribute(&1, "href"))
      |> List.flatten()

    assert "https://linear.app/example/issue/URL-ONLY" in links
    assert "#" in links
  end

  test "run deep view render filters non-map dependencies before action-needed rendering" do
    run = %{
      issue_identifier: "MT-RENDER-COVERAGE",
      title: "Render coverage run",
      linear_state: "In Progress",
      current_phase: "codex_waiting_next_event",
      current_action: "render coverage",
      health: "normal",
      blocked_by: [
        "ignore me",
        %{title: "Visible blocker", linear_state: "Todo"}
      ],
      blocks: [],
      attention_items: []
    }

    html =
      rendered_to_string(
        SymphonyElixirWeb.RunLive.render(%{
          run_state: {:ok, %{project: %{project_id: "alpha", project_name: "Alpha"}, run: run}},
          issue_identifier: "MT-RENDER-COVERAGE",
          project_id: "alpha",
          section_state: %{
            overview: true,
            action_needed: true,
            timeline: true,
            context: false,
            event_detail: false
          },
          timeline_filter: "all",
          timeline_state: %{status: :ready, items: [], next_cursor: nil, error: nil, load_more_error: nil},
          context_state: %{status: :idle, context: nil, error: nil},
          detail_state: %{status: :idle, event_id: nil, detail: nil, error: nil, surfaces: %{}}
        })
      )

    assert html =~ "Visible blocker"
    refute html =~ "ignore me"
  end

  test "control-plane timeline proxy degrades when project manager is unavailable" do
    Application.delete_env(:symphony_elixir, :project_process_manager_name)

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
            runtime_state: %{
              status: :running,
              run_summaries: [
                %{issue_identifier: "MT-ALPHA-1", title: "Alpha task", linear_state: "In Progress"}
              ]
            }
          }
        ]
      }
    )

    assert json_response(get(build_conn(), "/api/v1/projects/alpha/runs/MT-ALPHA-1/timeline"), 503) == %{
             "error" => %{"code" => "timeline_unavailable", "message" => "Run timeline is unavailable"}
           }

    {:ok, _view, html} = live(build_conn(), "/projects/alpha/runs/MT-ALPHA-1")
    assert html =~ "Alpha task"
    assert html =~ "Timeline unavailable"
    refute html =~ "Run unavailable"
  end

  test "run deep view stays lightweight when the run summary is unavailable" do
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
            runtime_state: %{status: :running, run_summaries: []}
          }
        ]
      }
    )

    {:ok, _view, html} = live(build_conn(), "/projects/alpha/runs/MT-MISSING")
    assert html =~ "Run unavailable"
    assert html =~ "MT-MISSING"
    refute html =~ "Timeline"
    refute html =~ "Shell output"
    refute html =~ "Prompt"
  end

  test "run deep view renders dependency and attention panels" do
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
            runtime_state: %{
              status: :running,
              run_summaries: [
                %{
                  issue_identifier: "MT-ALPHA-1",
                  title: "Alpha task",
                  issue_url: "https://linear.app/example/issue/MT-ALPHA-1",
                  linear_state: "In Progress",
                  current_phase: "codex_waiting_next_event",
                  current_action: "waiting for blocker",
                  health: "needs_attention",
                  blocked_by: [
                    %{
                      issue_identifier: "MT-BLOCKER-1",
                      title: "Blocker one",
                      linear_state: "In Progress",
                      url: "https://linear.app/example/issue/MT-BLOCKER-1"
                    }
                  ],
                  blocks: [
                    %{
                      issue_identifier: "MT-BLOCKED-1",
                      title: "Blocked child",
                      linear_state: "Todo",
                      url: "https://linear.app/example/issue/MT-BLOCKED-1"
                    }
                  ],
                  attention_items: [
                    %{kind: "needs_attention", message: "Run requires manual follow-up."}
                  ]
                }
              ]
            }
          }
        ]
      }
    )

    {:ok, _view, html} = live(build_conn(), "/projects/alpha/runs/MT-ALPHA-1")
    document = Floki.parse_document!(html)

    assert project_section_texts(document, "Action Needed") |> Enum.any?(&String.contains?(&1, "Blocked by"))
    assert project_section_texts(document, "Action Needed") |> Enum.any?(&String.contains?(&1, "MT-BLOCKER-1"))
    assert project_section_texts(document, "Action Needed") |> Enum.any?(&String.contains?(&1, "Blocks"))
    assert project_section_texts(document, "Action Needed") |> Enum.any?(&String.contains?(&1, "MT-BLOCKED-1"))
    assert project_section_texts(document, "Action Needed") |> Enum.member?("Run requires manual follow-up.")

    links =
      document
      |> find_section_by_title("Action Needed")
      |> Floki.find("a.issue-link")
      |> Enum.map(&Floki.attribute(&1, "href"))
      |> List.flatten()

    assert "https://linear.app/example/issue/MT-BLOCKER-1" in links
    assert "https://linear.app/example/issue/MT-BLOCKED-1" in links
  end

  test "run deep view keeps dependency placeholders without identifiers visible" do
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
            runtime_state: %{
              status: :running,
              run_summaries: [
                %{
                  issue_identifier: "MT-ALPHA-2",
                  title: "Placeholder dependency task",
                  issue_url: "https://linear.app/example/issue/MT-ALPHA-2",
                  linear_state: "In Progress",
                  current_phase: "codex_waiting_tool",
                  current_action: "waiting for dependency placeholder",
                  health: "tool_blocked",
                  blocked_by: [
                    %{
                      title: "External blocker",
                      linear_state: "Todo",
                      url: "https://linear.app/example/issue/EXT-BLOCKER"
                    }
                  ],
                  attention_items: [
                    %{kind: "tool_blocked", message: "Run is blocked on a tool failure and needs manual follow-up."}
                  ]
                }
              ]
            }
          }
        ]
      }
    )

    {:ok, _view, html} = live(build_conn(), "/projects/alpha/runs/MT-ALPHA-2")
    document = Floki.parse_document!(html)

    assert project_section_texts(document, "Action Needed") |> Enum.any?(&String.contains?(&1, "External blocker"))
    assert project_section_texts(document, "Action Needed") |> Enum.any?(&String.contains?(&1, "Todo"))

    links =
      document
      |> find_section_by_title("Action Needed")
      |> Floki.find("a.issue-link")
      |> Enum.map(&Floki.attribute(&1, "href"))
      |> List.flatten()

    assert "https://linear.app/example/issue/EXT-BLOCKER" in links
  end

  test "run deep view hides checking cooldown summaries from attention panel" do
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
            runtime_state: %{
              status: :running,
              run_summaries: [
                %{
                  issue_identifier: "MT-CHECKING-1",
                  title: "Checking task",
                  linear_state: "Checking",
                  current_phase: "checking_tracker_state",
                  current_action: "bounded recheck queued",
                  health: "normal",
                  attention_items: []
                }
              ]
            }
          }
        ]
      }
    )

    {:ok, _view, html} = live(build_conn(), "/projects/alpha/runs/MT-CHECKING-1")
    document = Floki.parse_document!(html)
    assert project_section_texts(document, "Action Needed") |> Enum.member?("No attention items.")
  end

  test "run deep view renders empty dependency and attention states" do
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
            runtime_state: %{
              status: :running,
              run_summaries: [
                %{
                  issue_identifier: "MT-CLEAR-1",
                  title: "Clear task",
                  linear_state: "In Progress",
                  current_phase: "codex_reasoning",
                  current_action: "active",
                  health: "normal",
                  blocked_by: [],
                  blocks: [],
                  attention_items: []
                }
              ]
            }
          }
        ]
      }
    )

    {:ok, _view, html} = live(build_conn(), "/projects/alpha/runs/MT-CLEAR-1")
    document = Floki.parse_document!(html)

    assert project_section_texts(document, "Action Needed") |> Enum.count(&(&1 == "No dependencies.")) == 2
    assert project_section_texts(document, "Action Needed") |> Enum.member?("No attention items.")
  end

  test "run deep view ignores timeline load messages when summary is unavailable" do
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
            runtime_state: %{status: :running, run_summaries: []}
          }
        ]
      }
    )

    {:ok, view, _html} = live(build_conn(), "/projects/alpha/runs/MT-MISSING")
    send(view.pid, :load_timeline)

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "Run unavailable" and rendered =~ "MT-MISSING" and
        not String.contains?(rendered, "Timeline")
    end)
  end

  test "workflow run deep view renders timeline items from orchestrator" do
    orchestrator_name = Module.concat(__MODULE__, RunLiveWorkflowTimelineOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        run_timeline_results: %{
          {"MT-WORKFLOW", nil} =>
            {:ok,
             %{
               items: [
                 %{
                   event_id: "evt-workflow",
                   timestamp: "2026-05-16T01:00:00Z",
                   source: "codex",
                   event_type: "turn_completed",
                   summary: "workflow timeline loaded",
                   status_markers: ["completed"]
                 }
               ],
               next_cursor: nil
             }}
        }
      )

    start_test_endpoint(
      orchestrator: orchestrator_name,
      project_registry: run_live_project_registry("MT-WORKFLOW", "Workflow run")
    )

    {:ok, view, _html} = live(build_conn(), "/projects/alpha/runs/MT-WORKFLOW")

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "Workflow run" and rendered =~ "workflow timeline loaded" and
        rendered =~ "turn completed" and not String.contains?(rendered, "Timeline unavailable")
    end)
  end

  test "workflow run deep view renders context from orchestrator and humanizes statuses" do
    orchestrator_name = Module.concat(__MODULE__, RunLiveWorkflowContextOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        run_timeline_results: %{
          {"MT-WORKFLOW-CONTEXT", nil} =>
            {:ok,
             %{
               items: [
                 %{
                   event_id: "evt-workflow-context",
                   timestamp: "2026-05-16T01:10:00Z",
                   source: "codex",
                   event_type: "turn_completed",
                   summary: "workflow timeline with context",
                   status_markers: ["completed"]
                 }
               ],
               next_cursor: nil
             }}
        },
        run_context_results: %{
          "MT-WORKFLOW-CONTEXT" =>
            {:ok,
             %{
               anchor: %{session_id: "workflow-session", thread_id: "workflow-thread", turn_id: "workflow-turn", turn_count: 6},
               conversation: %{items: [], truncated: false},
               continuation: %{status: "none_observed", label: "none observed", event_id: nil},
               issue_refresh: %{
                 status: "issue_snapshot_unchanged",
                 status_text: "issue_snapshot_unchanged",
                 observed_changes: [],
                 updated_at_changed?: true,
                 event_id: "evt-issue-refresh-1",
                 notes: [
                   "No observed %SymphonyElixir.Linear.Issue{} snapshot field changes.",
                   "updated_at changed from ~U[2026-05-16 01:00:00Z] to ~U[2026-05-16 01:05:00Z], but that alone is not treated as a semantic field change.",
                   "This may still reflect v1-unobserved changes such as comments, threads, or body revisions."
                 ]
               },
               tools: %{items: []},
               shell: %{items: []},
               subagents: %{items: [], status: "ready"}
             }}
        }
      )

    start_test_endpoint(
      orchestrator: orchestrator_name,
      project_registry: run_live_project_registry("MT-WORKFLOW-CONTEXT", "Workflow context")
    )

    {:ok, view, _html} = live(build_conn(), "/projects/alpha/runs/MT-WORKFLOW-CONTEXT")
    render_click(element(view, "button[phx-click='toggle_section'][phx-value-section='context']"))

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "Workflow context" and
        rendered =~ "workflow timeline with context" and
        rendered =~ "Context" and
        rendered =~ "Issue Refresh" and
        rendered =~ "issue_snapshot_unchanged" and
        rendered =~ "updated_at changed from ~U[2026-05-16 01:00:00Z] to ~U[2026-05-16 01:05:00Z]" and
        rendered =~ "session: workflow-session" and
        rendered =~ "turn_count: 6" and
        rendered =~ "ready"
    end)
  end

  test "workflow run deep view humanizes unavailable and unknown context statuses" do
    orchestrator_name = Module.concat(__MODULE__, RunLiveWorkflowContextStatusOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        run_timeline_results: %{
          {"MT-WORKFLOW-CONTEXT-STATUS", nil} =>
            {:ok,
             %{
               items: [
                 %{
                   event_id: "evt-workflow-context-status",
                   timestamp: "2026-05-16T01:20:00Z",
                   source: "codex",
                   event_type: "turn_completed",
                   summary: "workflow timeline with context statuses",
                   status_markers: []
                 }
               ],
               next_cursor: nil
             }}
        },
        run_context_results: %{
          "MT-WORKFLOW-CONTEXT-STATUS" =>
            {:ok,
             %{
               anchor: %{session_id: "workflow-session-2", thread_id: "workflow-thread-2", turn_id: "workflow-turn-2", turn_count: 2},
               conversation: %{items: [], truncated: false},
               continuation: %{status: "none_observed", label: "none observed", event_id: nil},
               issue_refresh: %{
                 status: "none_observed",
                 status_text: "none observed",
                 observed_changes: [],
                 updated_at_changed?: false,
                 event_id: nil,
                 notes: []
               },
               tools: %{items: []},
               shell: %{items: []},
               subagents: %{items: [], status: "mystery_status"}
             }}
        }
      )

    start_test_endpoint(
      orchestrator: orchestrator_name,
      project_registry: run_live_project_registry("MT-WORKFLOW-CONTEXT-STATUS", "Workflow context status")
    )

    {:ok, view, _html} = live(build_conn(), "/projects/alpha/runs/MT-WORKFLOW-CONTEXT-STATUS")

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "Workflow context status" and
        rendered =~ "workflow timeline with context statuses" and
        rendered =~ "unavailable"
    end)
  end

  test "workflow run deep view humanizes explicit unavailable context status" do
    orchestrator_name = Module.concat(__MODULE__, RunLiveWorkflowContextUnavailableStatusOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        run_timeline_results: %{
          {"MT-WORKFLOW-CONTEXT-UNAVAILABLE", nil} =>
            {:ok,
             %{
               items: [
                 %{
                   event_id: "evt-workflow-context-unavailable",
                   timestamp: "2026-05-16T01:21:00Z",
                   source: "codex",
                   event_type: "turn_completed",
                   summary: "workflow timeline with unavailable context status",
                   status_markers: []
                 }
               ],
               next_cursor: nil
             }}
        },
        run_context_results: %{
          "MT-WORKFLOW-CONTEXT-UNAVAILABLE" =>
            {:ok,
             %{
               anchor: %{session_id: "workflow-session-3", thread_id: "workflow-thread-3", turn_id: "workflow-turn-3", turn_count: 3},
               conversation: %{items: [], truncated: false},
               continuation: %{status: "none_observed", label: "none observed", event_id: nil},
               issue_refresh: %{
                 status: "issue_snapshot_unavailable",
                 status_text: "issue_snapshot_unavailable",
                 observed_changes: [],
                 updated_at_changed?: false,
                 event_id: "evt-issue-refresh-2",
                 notes: [
                   "Observed snapshot comparison degraded: at least one field was not safely compared, so this is not a normal changed/unchanged conclusion.",
                   "blocked_by was not safely compared because blocked_by contains an entry without stable id/state keys: %{state: \"Todo\"}; treat this as unavailable/not_yet_observed for the current snapshot conclusion."
                 ]
               },
               tools: %{items: []},
               shell: %{items: []},
               subagents: %{items: [], status: "unavailable"}
             }}
        }
      )

    start_test_endpoint(
      orchestrator: orchestrator_name,
      project_registry: run_live_project_registry("MT-WORKFLOW-CONTEXT-UNAVAILABLE", "Workflow context unavailable status")
    )

    {:ok, view, _html} = live(build_conn(), "/projects/alpha/runs/MT-WORKFLOW-CONTEXT-UNAVAILABLE")

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "Workflow context unavailable status" and
        rendered =~ "workflow timeline with unavailable context status" and
        rendered =~ "Issue Refresh" and
        rendered =~ "issue_snapshot_unavailable" and
        rendered =~ "blocked_by was not safely compared" and
        rendered =~ "unavailable"
    end)
  end

  test "workflow run deep view degrades timeline errors without hiding summary" do
    orchestrator_name = Module.concat(__MODULE__, RunLiveWorkflowTimelineErrorOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        run_timeline_results: %{{"MT-WORKFLOW-ERR", nil} => {:error, :duplicate_run}}
      )

    start_test_endpoint(
      orchestrator: orchestrator_name,
      project_registry: run_live_project_registry("MT-WORKFLOW-ERR", "Workflow duplicate")
    )

    {:ok, view, _html} = live(build_conn(), "/projects/alpha/runs/MT-WORKFLOW-ERR")

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "Workflow duplicate" and rendered =~ "Timeline unavailable" and
        not String.contains?(rendered, "Run unavailable")
    end)
  end

  test "workflow run deep view degrades when orchestrator is unavailable" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, MissingRunLiveTimelineOrchestrator),
      project_registry: run_live_project_registry("MT-WORKFLOW-DOWN", "Workflow down")
    )

    {:ok, view, _html} = live(build_conn(), "/projects/alpha/runs/MT-WORKFLOW-DOWN")

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "Workflow down" and rendered =~ "Timeline unavailable" and
        not String.contains?(rendered, "Run unavailable")
    end)
  end

  test "workflow run deep view degrades when timeline call times out" do
    orchestrator_name = Module.concat(__MODULE__, RunLiveTimelineTimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: orchestrator_name)

    start_test_endpoint(
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 1,
      project_registry: run_live_project_registry("MT-WORKFLOW-TIMEOUT", "Workflow timeout")
    )

    {:ok, view, _html} = live(build_conn(), "/projects/alpha/runs/MT-WORKFLOW-TIMEOUT")

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "Workflow timeout" and rendered =~ "Timeline unavailable" and
        not String.contains?(rendered, "Run unavailable")
    end)
  end

  test "run deep view skips context loading when summary is unavailable" do
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
            runtime_state: %{status: :running, run_summaries: []}
          }
        ]
      }
    )

    {:ok, _view, html} = live(build_conn(), "/projects/alpha/runs/MT-NO-SUMMARY-CONTEXT")
    assert html =~ "Run unavailable"
    refute html =~ "Context"
  end

  test "run deep view ignores context load messages when summary is unavailable" do
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
            runtime_state: %{status: :running, run_summaries: []}
          }
        ]
      }
    )

    {:ok, view, _html} = live(build_conn(), "/projects/alpha/runs/MT-NO-SUMMARY-CONTEXT-MESSAGE")
    send(view.pid, :load_context)

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "Run unavailable" and rendered =~ "MT-NO-SUMMARY-CONTEXT-MESSAGE" and
        not String.contains?(rendered, "Context")
    end)
  end

  test "run deep view ignores load more clicks when no cursor is available" do
    orchestrator_name = Module.concat(__MODULE__, RunLiveNoCursorOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        run_timeline_results: %{
          {"MT-NO-CURSOR", nil} =>
            {:ok,
             %{
               items: [%{event_id: "evt-no-cursor", summary: "single timeline page"}],
               next_cursor: nil
             }}
        }
      )

    start_test_endpoint(
      orchestrator: orchestrator_name,
      project_registry: run_live_project_registry("MT-NO-CURSOR", "No cursor run")
    )

    {:ok, view, _html} = live(build_conn(), "/projects/alpha/runs/MT-NO-CURSOR")

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "No cursor run" and rendered =~ "single timeline page" and
        not String.contains?(rendered, "Load more")
    end)

    render_click(view, "load_more_timeline")

    rendered = render(view)
    assert rendered =~ "single timeline page"
    refute rendered =~ "Timeline load more failed"
    refute rendered =~ "Load more"
  end

  test "run deep view lazily loads event detail and surface content independently from timeline" do
    manager_name = Module.concat(__MODULE__, RunLiveTimelineManager)
    test_pid = self()

    {:ok, port} =
      start_stub_http_server(fn
        "GET", "/api/v1/runs/MT-ALPHA-1/timeline" ->
          {200,
           %{
             items: [
               %{
                 event_id: "evt-2",
                 timestamp: "2026-05-14T01:59:00Z",
                 source: "codex",
                 event_group: "session",
                 summary: "session opened",
                 event_type: "session_started",
                 status_markers: ["session_started"]
               },
               %{
                 event_id: "evt-3",
                 timestamp: "2026-05-14T02:00:00Z",
                 source: "orchestrator",
                 event_group: "retry",
                 summary: "retry queued",
                 event_type: "retry_scheduled",
                 status_markers: []
               },
               %{
                 event_id: "evt-4",
                 timestamp: "2026-05-14T02:01:00Z",
                 source: "codex",
                 event_group: "turn",
                 summary: "turn finished",
                 event_type: "turn_completed",
                 status_markers: ["completed", "attention"]
               },
               %{
                 event_id: "evt-5",
                 timestamp: "2026-05-14T02:02:00Z",
                 source: "orchestrator",
                 event_group: "result",
                 summary: "run finished",
                 event_type: "run_result",
                 status_markers: []
               }
             ],
             next_cursor: "older"
           }}

        "GET", "/api/v1/runs/MT-ALPHA-1/timeline?cursor=older" ->
          send(test_pid, {:stub_request, "timeline", "older"})

          {200,
           %{
             items: [
               %{
                 event_id: "evt-1",
                 timestamp: "2026-05-14T01:58:00Z",
                 source: "agent_runner",
                 event_group: "workspace",
                 summary: "workspace ready",
                 event_type: "worker_runtime_info",
                 status_markers: []
               }
             ],
             next_cursor: nil
           }}

        "GET", "/api/v1/runs/MT-ALPHA-1/events/evt-4" ->
          send(test_pid, {:stub_request, "detail", "evt-4"})

          {200,
           %{
             event: %{event_id: "evt-4", timestamp: "2026-05-14T02:01:00Z", source: "codex", event_type: "turn_completed", event_group: "turn", summary: "turn finished"},
             run: %{issue_identifier: "MT-ALPHA-1", run_id: "run-evt-4"},
             context: %{session_id: "thread-alpha-turn-9", thread_id: "thread-alpha", turn_id: "turn-9"},
             summaries: %{tool_call: "shell", payload: "JSON object with 2 top-level keys", prompt: "Continue?", shell: "git status --short"},
             surfaces: %{
               raw: %{available: false, byte_size: 0, preview: nil, truncated: false},
               payload: %{available: true, byte_size: 64, preview: "{\"tool\":\"shell\"}", truncated: false},
               prompt: %{available: true, byte_size: 9, preview: "Continue?", truncated: false},
               shell: %{available: true, byte_size: 18, preview: "git status --short", truncated: false}
             }
           }}

        "GET", "/api/v1/runs/MT-ALPHA-1/events/evt-4/shell" ->
          send(test_pid, {:stub_request, "surface", "shell"})
          {200, %{surface: "shell", available: true, content: "git status --short", byte_size: 18, truncated: false}}

        "GET", "/api/v1/runs/MT-ALPHA-1/events/evt-4/prompt" ->
          send(test_pid, {:stub_request, "surface", "prompt"})
          {404, %{error: %{code: "surface_not_available", message: "no prompt"}}}
      end)

    start_supervised!({WorkerPortManagerStub, name: manager_name, worker_ports: %{"alpha" => port}})
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

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
            runtime_state: %{
              status: :running,
              run_summaries: [
                %{
                  issue_identifier: "MT-ALPHA-1",
                  title: "Alpha task",
                  linear_state: "In Progress",
                  current_phase: "codex_waiting_next_event",
                  current_action: "最近一段时间没有新事件",
                  health: "possibly_stalled",
                  thread_id: "thread-alpha",
                  turn_id: "turn-9",
                  last_event_at: ~U[2026-05-14 02:00:00Z],
                  run_duration_seconds: 960
                }
              ]
            }
          }
        ]
      }
    )

    {:ok, view, html} = live(build_conn(), "/projects/alpha/runs/MT-ALPHA-1")
    assert html =~ "Alpha task"
    assert html =~ "Timeline"

    refute_receive {:stub_request, "detail", _}
    refute_receive {:stub_request, "surface", _}

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "session opened" and
        rendered =~ "retry queued" and
        rendered =~ "turn finished" and
        rendered =~ "run finished" and
        rendered =~ "quiet attention" and
        rendered =~ "session started" and
        rendered =~ "turn completed" and
        rendered =~ "run result" and
        rendered =~ "retry" and
        rendered =~ "completed" and
        rendered =~ "attention" and
        rendered =~ "Load more"
    end)

    render_click(view, "load_more_timeline")

    assert_eventually(fn ->
      rendered = render(view)
      rendered =~ "workspace ready" and not String.contains?(rendered, "Load more")
    end)

    render_click(element(view, "button[phx-value-event_id='evt-4']"))
    assert_receive {:stub_request, "detail", "evt-4"}

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "event_id: evt-4" and
        rendered =~ "thread: thread-alpha" and
        rendered =~ "prompt summary: Continue?" and
        rendered =~ "Load shell" and
        rendered =~ "Surface body stays unloaded."
    end)

    refute_receive {:stub_request, "surface", _}

    render_click(element(view, "button[phx-value-surface='shell']"))
    assert_receive {:stub_request, "surface", "shell"}

    assert_eventually(fn ->
      rendered = render(view)
      rendered =~ "git status --short"
    end)

    render_click(element(view, "button[phx-value-surface='prompt']"))
    assert_receive {:stub_request, "surface", "prompt"}

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "Surface unavailable for this event" and
        rendered =~ "workspace ready" and
        rendered =~ "turn finished"
    end)
  end

  test "run deep view ignores surface clicks before detail is ready and renders detail errors" do
    manager_name = Module.concat(__MODULE__, RunLiveDetailErrorManager)
    test_pid = self()

    {:ok, port} =
      start_stub_http_server(fn
        "GET", "/api/v1/runs/MT-DETAIL-ERROR/timeline" ->
          {200,
           %{
             items: [
               %{
                 event_id: "evt-error",
                 timestamp: "2026-05-14T02:01:00Z",
                 source: "codex",
                 event_group: "turn",
                 summary: "broken detail",
                 event_type: "turn_completed",
                 status_markers: []
               }
             ],
             next_cursor: nil
           }}

        "GET", "/api/v1/runs/MT-DETAIL-ERROR/events/evt-error" ->
          send(test_pid, {:stub_request, "detail", "evt-error"})
          {503, %{error: %{code: "event_detail_unavailable", message: "detail down"}}}
      end)

    start_supervised!({WorkerPortManagerStub, name: manager_name, worker_ports: %{"alpha" => port}})
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer,
      project_registry: run_live_project_registry("MT-DETAIL-ERROR", "Detail error")
    )

    {:ok, view, _html} = live(build_conn(), "/projects/alpha/runs/MT-DETAIL-ERROR")

    assert_eventually(fn ->
      rendered = render(view)
      rendered =~ "broken detail" and rendered =~ "Choose an event to inspect details."
    end)

    render_click(view, "load_event_surface", %{"surface" => "prompt"})
    refute_receive {:stub_request, "surface", _}

    render_click(element(view, "button[phx-value-event_id='evt-error']"))
    assert_receive {:stub_request, "detail", "evt-error"}

    assert_eventually(fn ->
      rendered = render(view)
      rendered =~ "Event detail unavailable" and rendered =~ "broken detail"
    end)

    render_click(view, "load_event_surface", %{"surface" => "prompt"})
    refute_receive {:stub_request, "surface", _}
  end

  test "run deep view ignores stale detail and surface completion messages" do
    manager_name = Module.concat(__MODULE__, RunLiveStaleMessageManager)
    test_pid = self()

    {:ok, port} =
      start_stub_http_server(fn
        "GET", "/api/v1/runs/MT-STALE/timeline" ->
          {200,
           %{
             items: [
               %{
                 event_id: "evt-stale",
                 timestamp: "2026-05-14T02:01:00Z",
                 source: "codex",
                 event_group: "turn",
                 summary: "stale candidate",
                 event_type: "turn_completed",
                 status_markers: []
               }
             ],
             next_cursor: nil
           }}

        "GET", "/api/v1/runs/MT-STALE/events/evt-stale" ->
          send(test_pid, {:stub_request, "detail", "evt-stale"})
          {200, run_live_detail_payload("evt-stale")}

        "GET", "/api/v1/runs/MT-STALE/events/evt-stale/shell" ->
          send(test_pid, {:stub_request, "surface", "shell"})
          {200, %{surface: "shell", available: true, content: "echo ok", byte_size: 7, truncated: false}}
      end)

    start_supervised!({WorkerPortManagerStub, name: manager_name, worker_ports: %{"alpha" => port}})
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer,
      project_registry: run_live_project_registry("MT-STALE", "Stale run")
    )

    {:ok, view, _html} = live(build_conn(), "/projects/alpha/runs/MT-STALE")

    assert_eventually(fn ->
      render(view) =~ "stale candidate"
    end)

    send(view.pid, {:load_event_detail, 403})
    refute_receive {:stub_request, "detail", _}

    send(view.pid, {:event_detail_loaded, 403, {:error, :event_detail_unavailable}})
    assert render(view) =~ "Choose an event to inspect details."

    render_click(element(view, "button[phx-value-event_id='evt-stale']"))
    assert_receive {:stub_request, "detail", "evt-stale"}

    assert_eventually(fn ->
      rendered = render(view)
      rendered =~ "event_id: evt-stale" and rendered =~ "Load shell"
    end)

    send(view.pid, {:event_detail_loaded, "evt-other", {:error, :event_detail_unavailable}})
    rendered_after_stale_detail = render(view)
    assert rendered_after_stale_detail =~ "event_id: evt-stale"
    refute rendered_after_stale_detail =~ "Event detail unavailable"

    send(view.pid, {:load_event_surface, "evt-other", "shell"})
    refute_receive {:stub_request, "surface", _}

    send(view.pid, {:load_event_surface, "evt-stale", 445})
    refute_receive {:stub_request, "surface", _}

    render_click(element(view, "button[phx-value-surface='shell']"))
    assert_receive {:stub_request, "surface", "shell"}

    assert_eventually(fn ->
      render(view) =~ "echo ok"
    end)

    send(view.pid, {:event_surface_loaded, "evt-other", "shell", {:error, :surface_not_available}})
    send(view.pid, {:event_surface_loaded, "evt-stale", "unknown", {:error, :surface_not_available}})

    rendered_after_stale_surface = render(view)
    assert rendered_after_stale_surface =~ "echo ok"
    refute rendered_after_stale_surface =~ "Surface unavailable for this event"
  end

  test "workflow run deep view maps worker event detail and surface responses" do
    orchestrator_name = Module.concat(__MODULE__, RunLiveWorkflowEventHelpersOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        run_timeline_results: %{
          {"MT-WORKFLOW-EVENTS", nil} =>
            {:ok,
             %{
               items: [
                 %{
                   event_id: "evt-ok",
                   timestamp: "2026-05-16T01:00:00Z",
                   source: "codex",
                   event_type: "turn_completed",
                   summary: "ok event",
                   status_markers: []
                 },
                 %{
                   event_id: "evt-error",
                   timestamp: "2026-05-16T01:01:00Z",
                   source: "codex",
                   event_type: "turn_completed",
                   summary: "error event",
                   status_markers: []
                 },
                 %{
                   event_id: "evt-timeout",
                   timestamp: "2026-05-16T01:02:00Z",
                   source: "codex",
                   event_type: "turn_completed",
                   summary: "timeout event",
                   status_markers: []
                 },
                 %{
                   event_id: "evt-down",
                   timestamp: "2026-05-16T01:03:00Z",
                   source: "codex",
                   event_type: "turn_completed",
                   summary: "down event",
                   status_markers: []
                 },
                 %{
                   event_id: "evt-surface-error",
                   timestamp: "2026-05-16T01:04:00Z",
                   source: "codex",
                   event_type: "turn_completed",
                   summary: "surface error event",
                   status_markers: []
                 },
                 %{
                   event_id: "evt-surface-timeout",
                   timestamp: "2026-05-16T01:05:00Z",
                   source: "codex",
                   event_type: "turn_completed",
                   summary: "surface timeout event",
                   status_markers: []
                 },
                 %{
                   event_id: "evt-surface-down",
                   timestamp: "2026-05-16T01:06:00Z",
                   source: "codex",
                   event_type: "turn_completed",
                   summary: "surface down event",
                   status_markers: []
                 }
               ],
               next_cursor: nil
             }}
        },
        run_event_detail_results: %{
          {"MT-WORKFLOW-EVENTS", "evt-ok"} => {:ok, run_live_detail_payload("evt-ok")},
          {"MT-WORKFLOW-EVENTS", "evt-error"} => {:error, :event_not_found},
          {"MT-WORKFLOW-EVENTS", "evt-timeout"} => :timeout,
          {"MT-WORKFLOW-EVENTS", "evt-down"} => :unavailable,
          {"MT-WORKFLOW-EVENTS", "evt-surface-error"} => {:ok, run_live_detail_payload("evt-surface-error")},
          {"MT-WORKFLOW-EVENTS", "evt-surface-timeout"} => {:ok, run_live_detail_payload("evt-surface-timeout")},
          {"MT-WORKFLOW-EVENTS", "evt-surface-down"} => {:ok, run_live_detail_payload("evt-surface-down")}
        },
        run_event_surface_results: %{
          {"MT-WORKFLOW-EVENTS", "evt-ok", "shell"} => {:ok, %{surface: "shell", available: true, content: "workflow shell", byte_size: 14, truncated: false}},
          {"MT-WORKFLOW-EVENTS", "evt-surface-error", "shell"} => {:error, :surface_not_available},
          {"MT-WORKFLOW-EVENTS", "evt-surface-timeout", "payload"} => :timeout,
          {"MT-WORKFLOW-EVENTS", "evt-surface-down", "prompt"} => :unavailable
        }
      )

    start_test_endpoint(
      orchestrator: orchestrator_name,
      project_registry: run_live_project_registry("MT-WORKFLOW-EVENTS", "Workflow event helpers")
    )

    {:ok, view, _html} = live(build_conn(), "/projects/alpha/runs/MT-WORKFLOW-EVENTS")

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "ok event" and rendered =~ "error event" and rendered =~ "timeout event" and
        rendered =~ "surface error event"
    end)

    render_click(element(view, "button[phx-value-event_id='evt-ok']"))

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "event_id: evt-ok" and rendered =~ "shell summary: git status --short" and
        rendered =~ "prompt summary: n/a"
    end)

    render_click(element(view, "button[phx-value-surface='shell']"))

    assert_eventually(fn ->
      render(view) =~ "workflow shell"
    end)

    send(view.pid, {:event_surface_loaded, "evt-ok", "shell", {:error, :invalid_surface}})
    assert_eventually(fn -> render(view) =~ "Surface unavailable for this event" end)

    render_click(element(view, "button[phx-value-event_id='evt-error']"))
    assert_eventually(fn -> render(view) =~ "Event detail unavailable" end)

    render_click(element(view, "button[phx-value-event_id='evt-timeout']"))
    assert_eventually(fn -> render(view) =~ "Event detail unavailable" end)

    render_click(element(view, "button[phx-value-event_id='evt-down']"))
    assert_eventually(fn -> render(view) =~ "Event detail unavailable" end)

    render_click(element(view, "button[phx-value-event_id='evt-surface-error']"))

    assert_eventually(fn ->
      render(view) =~ "event_id: evt-surface-error"
    end)

    render_click(element(view, "button[phx-value-surface='shell']"))
    assert_eventually(fn -> render(view) =~ "Surface unavailable for this event" end)

    render_click(element(view, "button[phx-value-event_id='evt-surface-timeout']"))

    assert_eventually(fn ->
      render(view) =~ "event_id: evt-surface-timeout"
    end)

    render_click(element(view, "button[phx-value-surface='payload']"))
    assert_eventually(fn -> render(view) =~ "Surface unavailable for this event" end)

    render_click(element(view, "button[phx-value-event_id='evt-surface-down']"))

    assert_eventually(fn ->
      render(view) =~ "event_id: evt-surface-down"
    end)

    render_click(element(view, "button[phx-value-surface='prompt']"))
    assert_eventually(fn -> render(view) =~ "Surface unavailable for this event" end)
  end

  test "run deep view renders context cards independently and degrades context failures without hiding timeline or detail" do
    manager_name = Module.concat(__MODULE__, RunLiveContextManager)
    test_pid = self()

    {:ok, port} =
      start_stub_http_server(fn
        "GET", "/api/v1/runs/MT-CONTEXT-LIVE/timeline" ->
          {200,
           %{
             items: [
               %{
                 event_id: "evt-live-1",
                 timestamp: "2026-05-14T02:01:00Z",
                 source: "codex",
                 event_group: "turn",
                 summary: "timeline survives context",
                 event_type: "turn_completed",
                 status_markers: []
               }
             ],
             next_cursor: nil
           }}

        "GET", "/api/v1/runs/MT-CONTEXT-LIVE/context" ->
          send(test_pid, {:stub_request, "context", "MT-CONTEXT-LIVE"})

          {200,
           %{
             anchor: %{session_id: "thread-live-turn-4", thread_id: "thread-live", turn_id: "turn-4", turn_count: 4},
             conversation: %{
               items: [
                 %{event_id: "evt-live-ctx-3", kind: "user_input_request", label: "tool input request", text: "Continue?"}
               ],
               truncated: false
             },
             continuation: %{status: "checking_recheck", label: "checking recheck", event_id: "evt-live-ctx-2"},
             tools: %{items: [%{event_id: "evt-live-ctx-4", tool: "shell", status: "completed", summary: "dynamic tool call completed (shell)"}]},
             shell: %{items: [%{event_id: "evt-live-ctx-5", kind: "exec_command", text: "git status --short"}]},
             subagents: %{items: [], status: "none_observed"}
           }}

        "GET", "/api/v1/runs/MT-CONTEXT-LIVE/events/evt-live-1" ->
          {200, run_live_detail_payload("evt-live-1")}

        "GET", "/api/v1/runs/MT-CONTEXT-DOWN-LIVE/timeline" ->
          {200,
           %{
             items: [
               %{
                 event_id: "evt-live-down",
                 timestamp: "2026-05-14T02:01:00Z",
                 source: "codex",
                 event_group: "turn",
                 summary: "timeline still visible",
                 event_type: "turn_completed",
                 status_markers: []
               }
             ],
             next_cursor: nil
           }}

        "GET", "/api/v1/runs/MT-CONTEXT-DOWN-LIVE/context" ->
          send(test_pid, {:stub_request, "context", "MT-CONTEXT-DOWN-LIVE"})
          {503, %{error: %{code: "context_unavailable", message: "context down"}}}

        "GET", "/api/v1/runs/MT-CONTEXT-DOWN-LIVE/events/evt-live-down" ->
          {200, run_live_detail_payload("evt-live-down")}
      end)

    start_supervised!({WorkerPortManagerStub, name: manager_name, worker_ports: %{"alpha" => port}})
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

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
            runtime_state: %{
              status: :running,
              run_summaries: [
                %{issue_identifier: "MT-CONTEXT-LIVE", title: "Context ready", linear_state: "In Progress"},
                %{issue_identifier: "MT-CONTEXT-DOWN-LIVE", title: "Context down", linear_state: "In Progress"}
              ]
            }
          }
        ]
      }
    )

    {:ok, view, _html} = live(build_conn(), "/projects/alpha/runs/MT-CONTEXT-LIVE")
    assert_receive {:stub_request, "context", "MT-CONTEXT-LIVE"}

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "Context ready" and
        rendered =~ "timeline survives context" and
        rendered =~ "Thread &amp; Turn" and
        rendered =~ "session: thread-live-turn-4" and
        rendered =~ "thread: thread-live" and
        rendered =~ "turn: turn-4" and
        rendered =~ "turn_count: 4" and
        rendered =~ "Recent interaction signals" and
        rendered =~ "tool input request" and
        rendered =~ "Continue?" and
        rendered =~ "Continuation &amp; Retry" and
        rendered =~ "checking recheck" and
        rendered =~ "event_id: evt-live-ctx-2" and
        rendered =~ "Open detail: evt-live-ctx-2" and
        rendered =~ "Tools &amp; Shell" and
        rendered =~ "dynamic tool call completed (shell)" and
        rendered =~ "Open detail: evt-live-ctx-4" and
        rendered =~ "Open detail: evt-live-ctx-5" and
        rendered =~ "git status --short" and
        rendered =~ "Sub-agent" and
        rendered =~ "none observed"
    end)

    render_click(element(view, "button[phx-value-event_id='evt-live-ctx-2']"))

    assert_eventually(fn ->
      rendered = render(view)
      rendered =~ "event_id: evt-live-ctx-2"
    end)

    render_click(element(view, "button[phx-value-event_id='evt-live-1']"))

    assert_eventually(fn ->
      rendered = render(view)
      rendered =~ "event_id: evt-live-1" and rendered =~ "shell summary: git status --short"
    end)

    {:ok, down_view, _html} = live(build_conn(), "/projects/alpha/runs/MT-CONTEXT-DOWN-LIVE")
    assert_receive {:stub_request, "context", "MT-CONTEXT-DOWN-LIVE"}

    assert_eventually(fn ->
      rendered = render(down_view)

      rendered =~ "Context down" and
        rendered =~ "timeline still visible" and
        rendered =~ "Context unavailable" and
        not String.contains?(rendered, "Run unavailable")
    end)

    render_click(element(down_view, "button[phx-value-event_id='evt-live-down']"))

    assert_eventually(fn ->
      rendered = render(down_view)
      rendered =~ "event_id: evt-live-down" and rendered =~ "timeline still visible"
    end)
  end

  test "run deep view renders empty detail summaries as n/a and preview fallback text" do
    manager_name = Module.concat(__MODULE__, RunLivePreviewFallbackManager)

    {:ok, port} =
      start_stub_http_server(fn
        "GET", "/api/v1/runs/MT-PREVIEW/timeline" ->
          {200,
           %{
             items: [
               %{
                 event_id: "evt-preview",
                 timestamp: "2026-05-14T02:01:00Z",
                 source: "codex",
                 event_group: "turn",
                 summary: "preview event",
                 event_type: "turn_completed",
                 status_markers: []
               }
             ],
             next_cursor: nil
           }}

        "GET", "/api/v1/runs/MT-PREVIEW/events/evt-preview" ->
          {200,
           %{
             event: %{event_id: "evt-preview", timestamp: "2026-05-14T02:01:00Z", source: "codex", event_type: "turn_completed", event_group: "turn", summary: "preview event"},
             run: %{issue_identifier: "MT-PREVIEW", run_id: "run-preview"},
             context: %{session_id: "session-preview", thread_id: "thread-preview", turn_id: "turn-preview"},
             summaries: %{tool_call: "", payload: "", prompt: "", shell: ""},
             surfaces: %{
               raw: %{available: false, byte_size: 0, preview: nil, truncated: false},
               payload: %{available: true, byte_size: 0, preview: nil, truncated: false},
               prompt: %{available: true, byte_size: 0, preview: "", truncated: false},
               shell: %{available: false, byte_size: 0, preview: nil, truncated: false}
             }
           }}
      end)

    start_supervised!({WorkerPortManagerStub, name: manager_name, worker_ports: %{"alpha" => port}})
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer,
      project_registry: run_live_project_registry("MT-PREVIEW", "Preview fallback")
    )

    {:ok, view, _html} = live(build_conn(), "/projects/alpha/runs/MT-PREVIEW")

    assert_eventually(fn ->
      render(view) =~ "preview event"
    end)

    render_click(element(view, "button[phx-value-event_id='evt-preview']"))

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "tool summary: n/a" and rendered =~ "payload summary: n/a" and
        rendered =~ "prompt summary: n/a" and rendered =~ "shell summary: n/a" and
        rendered =~ "Preview unavailable"
    end)
  end

  test "control-plane event detail lookup does not depend on current timeline page items" do
    manager_name = Module.concat(__MODULE__, RunLiveDetailOffPageManager)
    test_pid = self()

    {:ok, port} =
      start_stub_http_server(fn
        "GET", "/api/v1/runs/MT-OFFPAGE/timeline" ->
          {200,
           %{
             items: [
               %{
                 event_id: "evt-visible",
                 timestamp: "2026-05-14T02:00:00Z",
                 source: "codex",
                 event_group: "turn",
                 summary: "visible item",
                 event_type: "turn_completed",
                 status_markers: []
               }
             ],
             next_cursor: nil
           }}

        "GET", "/api/v1/runs/MT-OFFPAGE/events/evt-hidden" ->
          send(test_pid, {:stub_request, "detail", "evt-hidden"})

          {200,
           %{
             event: %{event_id: "evt-hidden", timestamp: "2026-05-14T02:01:00Z", source: "codex", event_type: "notification", event_group: "turn", summary: "hidden item"},
             run: %{issue_identifier: "MT-OFFPAGE", run_id: "run-hidden"},
             context: %{session_id: "session-hidden", thread_id: "thread-hidden", turn_id: "turn-hidden"},
             summaries: %{tool_call: nil, payload: nil, prompt: nil, shell: nil},
             surfaces: %{
               raw: %{available: false, byte_size: 0, preview: nil, truncated: false},
               payload: %{available: false, byte_size: 0, preview: nil, truncated: false},
               prompt: %{available: false, byte_size: 0, preview: nil, truncated: false},
               shell: %{available: false, byte_size: 0, preview: nil, truncated: false}
             }
           }}
      end)

    start_supervised!({WorkerPortManagerStub, name: manager_name, worker_ports: %{"alpha" => port}})
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer,
      project_registry: run_live_project_registry("MT-OFFPAGE", "Off-page detail")
    )

    assert json_response(get(build_conn(), "/api/v1/projects/alpha/runs/MT-OFFPAGE/events/evt-hidden"), 200)["event"]["event_id"] == "evt-hidden"
    assert_receive {:stub_request, "detail", "evt-hidden"}
  end

  test "run deep view keeps summary visible when timeline load and load-more fail" do
    manager_name = Module.concat(__MODULE__, RunLiveTimelineErrorManager)

    {:ok, port} =
      start_stub_http_server(fn
        "GET", "/api/v1/runs/MT-ALPHA-1/timeline" ->
          {200,
           %{
             items: [
               %{
                 event_id: "evt-2",
                 timestamp: "2026-05-14T02:00:00Z",
                 source: "codex",
                 event_group: "turn",
                 summary: "turn finished",
                 event_type: "turn_completed",
                 status_markers: ["completed"]
               }
             ],
             next_cursor: "broken"
           }}

        "GET", "/api/v1/runs/MT-ALPHA-1/timeline?cursor=broken" ->
          {400, %{error: %{code: "invalid_cursor", message: "cursor expired"}}}

        "GET", "/api/v1/runs/MT-BROKEN/timeline" ->
          {409, %{error: %{code: "duplicate_run", message: "duplicate"}}}
      end)

    start_supervised!({WorkerPortManagerStub, name: manager_name, worker_ports: %{"alpha" => port}})
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

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
            runtime_state: %{
              status: :running,
              run_summaries: [
                %{issue_identifier: "MT-ALPHA-1", title: "Alpha task", linear_state: "In Progress"},
                %{issue_identifier: "MT-BROKEN", title: "Broken task", linear_state: "In Progress"}
              ]
            }
          }
        ]
      }
    )

    {:ok, view, _html} = live(build_conn(), "/projects/alpha/runs/MT-ALPHA-1")

    assert_eventually(fn ->
      rendered = render(view)
      rendered =~ "Alpha task" and rendered =~ "turn finished"
    end)

    render_click(view, "load_more_timeline")

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "Alpha task" and rendered =~ "turn finished" and
        rendered =~ "Timeline load more failed" and not String.contains?(rendered, "Load more")
    end)

    {:ok, broken_view, _html} = live(build_conn(), "/projects/alpha/runs/MT-BROKEN")

    assert_eventually(fn ->
      rendered = render(broken_view)
      rendered =~ "Broken task" and rendered =~ "Timeline unavailable" and not String.contains?(rendered, "Run unavailable")
    end)
  end

  test "run deep view disables load more after generic timeline page failure" do
    manager_name = Module.concat(__MODULE__, RunLiveTimelineLoadMoreUnavailableManager)

    {:ok, port} =
      start_stub_http_server(fn
        "GET", "/api/v1/runs/MT-LOAD-MORE-DOWN/timeline" ->
          {200,
           %{
             items: [%{event_id: "evt-first", summary: "first page"}],
             next_cursor: "down"
           }}

        "GET", "/api/v1/runs/MT-LOAD-MORE-DOWN/timeline?cursor=down" ->
          {503, %{error: %{code: "timeline_unavailable", message: "worker unavailable"}}}
      end)

    start_supervised!({WorkerPortManagerStub, name: manager_name, worker_ports: %{"alpha" => port}})
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer,
      project_registry: run_live_project_registry("MT-LOAD-MORE-DOWN", "History down")
    )

    {:ok, view, _html} = live(build_conn(), "/projects/alpha/runs/MT-LOAD-MORE-DOWN")

    assert_eventually(fn ->
      rendered = render(view)
      rendered =~ "History down" and rendered =~ "first page" and rendered =~ "Load more"
    end)

    render_click(view, "load_more_timeline")

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "History down" and rendered =~ "first page" and
        rendered =~ "Timeline load more failed" and not String.contains?(rendered, "Load more")
    end)
  end

  test "run deep view keeps summary visible when worker returns timeline run_not_found" do
    manager_name = Module.concat(__MODULE__, RunLiveTimelineMissingManager)

    {:ok, port} =
      start_stub_http_server(fn
        "GET", "/api/v1/runs/MT-MISSING-TIMELINE/timeline" ->
          {404, %{error: %{code: "run_not_found", message: "worker missing run trace"}}}
      end)

    start_supervised!({WorkerPortManagerStub, name: manager_name, worker_ports: %{"alpha" => port}})
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

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
            runtime_state: %{
              status: :running,
              run_summaries: [
                %{issue_identifier: "MT-MISSING-TIMELINE", title: "Missing timeline", linear_state: "In Progress"}
              ]
            }
          }
        ]
      }
    )

    {:ok, view, _html} = live(build_conn(), "/projects/alpha/runs/MT-MISSING-TIMELINE")

    assert_eventually(fn ->
      rendered = render(view)

      rendered =~ "Missing timeline" and rendered =~ "Timeline unavailable" and
        not String.contains?(rendered, "Run unavailable")
    end)
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Loading workflow snapshot"

    assert_eventually(fn ->
      rendered = render(view)
      rendered =~ "Snapshot unavailable" and rendered =~ "snapshot_unavailable"
    end)
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
      control_plane: %{health_poll_interval_ms: 10, health_check_timeout_ms: 10}
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

    start_supervised!({SymphonyElixir.WorkerHealthPoller, manager: manager_name, poll_interval_ms: 250})

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

    command_builder = fake_worker_builder(%{"alpha" => "normal", "beta" => "normal"})

    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: command_builder})
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

  test "control-plane dashboard shows workflow generation failure feedback without crashing" do
    test_root = temp_root!("dashboard-workflow-generation-failed")
    manager_name = Module.concat(__MODULE__, DashboardWorkflowGenerationFailedManager)
    port = reserve_tcp_port!()

    project =
      project_fixture(test_root, "alpha", port,
        workflow?: false,
        project_slug: "slug-alpha",
        repo_url: "https://example.com/alpha.git"
      )

    File.write!(project.workflow_source, "---\n[]\n---\nPrompt body\n")
    config_path = write_projects_config!(test_root, [project])

    on_exit(fn -> File.rm_rf!(test_root) end)
    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
    Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

    start_supervised!({ProjectProcessManager, name: manager_name, command_builder: fake_worker_builder(%{})})

    start_test_endpoint(
      runtime_mode: :control_plane,
      orchestrator: SymphonyElixir.ControlPlaneSnapshotServer
    )

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Alpha"

    feedback_html =
      render_click(view, "project_action", %{"project_id" => "alpha", "action" => "start"})

    assert feedback_html =~ "Project action failed"
    assert feedback_html =~ "workflow generation failed"
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

  test "workflow m3 precheck endpoint explains disabled auto dispatch" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", m3_enabled: false)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{id: "issue-1", identifier: "MT-1", title: "Todo", state: "Todo"}
    ])

    start_test_endpoint(orchestrator: Module.concat(__MODULE__, :WorkflowM3PrecheckOrchestrator))

    payload = json_response(post(build_conn(), "/api/v1/m3_precheck", %{}), 200)

    assert payload["m3_enabled"] == false
    refute Map.has_key?(payload, "eligible")
    refute Map.has_key?(payload, "dispatch")
    refute Map.has_key?(payload, "blocked")
    assert payload["eligible_todos"] == []
    assert payload["dispatched_todos"] == []
    assert payload["capacity_queued_todos"] == []
    assert payload["blocked_todos"] == %{"MT-1" => ["m3 disabled for project"]}
    assert payload["current_work"] == %{"count" => 0, "entries" => []}
    assert payload["anomalies"] == []
    assert payload["text"] =~ "M3 is disabled"
  end

  test "workflow m3 precheck endpoint uses current orchestrator instance running state" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", m3_enabled: true, max_concurrent_agents: 2)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{id: "issue-1", identifier: "MT-1", title: "Todo 1", state: "Todo"},
      %Issue{id: "issue-2", identifier: "MT-2", title: "Todo 2", state: "Todo"}
    ])

    orchestrator_name = Module.concat(__MODULE__, :WorkflowM3PrecheckRunningOrchestrator)

    start_supervised!(
      {M3PrecheckOrchestrator,
       name: orchestrator_name,
       max_concurrent_agents: 2,
       running: %{
         "running-1" => %{issue: %Issue{id: "running-1", identifier: "RUN-1", state: "In Progress"}}
       }}
    )

    start_test_endpoint(orchestrator: orchestrator_name)

    payload = json_response(post(build_conn(), "/api/v1/m3_precheck", %{}), 200)

    refute Map.has_key?(payload, "eligible")
    refute Map.has_key?(payload, "dispatch")
    refute Map.has_key?(payload, "blocked")
    assert Enum.map(payload["eligible_todos"], & &1["issue_identifier"]) == ["MT-1", "MT-2"]
    assert Enum.map(payload["dispatched_todos"], & &1["issue_identifier"]) == ["MT-1"]
    assert Enum.map(payload["capacity_queued_todos"], & &1["issue_identifier"]) == ["MT-2"]
    assert payload["blocked_todos"] == %{}

    assert payload["current_work"] == %{
             "count" => 1,
             "entries" => [
               %{
                 "issue_id" => "running-1",
                 "issue_identifier" => "RUN-1",
                 "state" => "In Progress"
               }
             ]
           }

    assert payload["anomalies"] == []
    assert payload["text"] =~ "Eligible Todo waiting for free capacity: MT-2"
  end

  test "control-plane project m3 precheck route proxies worker result" do
    test_root = temp_root!("project-precheck")
    manager_name = Module.concat(__MODULE__, ProjectPrecheckManager)
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

    assert {:ok, _running_state} = ProjectProcessManager.start_project(manager_name, "alpha")

    assert_eventually(fn ->
      payload = json_response(post(build_conn(), "/api/v1/projects/alpha/m3_precheck", %{}), 200)

      assert payload["generated_at"] == "2026-05-12T00:00:00Z"
      assert payload["m3_enabled"] == true
      refute Map.has_key?(payload, "eligible")
      refute Map.has_key?(payload, "dispatch")
      refute Map.has_key?(payload, "blocked")

      assert payload["eligible_todos"] == [
               %{"issue_identifier" => "MT-CP-1", "issue_id" => "cp-1", "state" => "Todo"}
             ]

      assert payload["dispatched_todos"] == []

      assert payload["capacity_queued_todos"] == [
               %{"issue_identifier" => "MT-CP-1", "issue_id" => "cp-1", "state" => "Todo"}
             ]

      assert payload["blocked_todos"] == %{"MT-CP-2" => ["waiting on non-terminal blockers: MT-CP-9"]}

      assert payload["current_work"] == %{
               "count" => 1,
               "entries" => [
                 %{
                   "issue_id" => "cp-running",
                   "issue_identifier" => "RUN-CP-1",
                   "state" => "In Progress",
                   "worker_host" => "worker-alpha"
                 }
               ]
             }

      assert payload["anomalies"] == [
               %{
                 "type" => "blocked_but_in_progress",
                 "issue_identifier" => "MT-CP-3",
                 "issue_id" => "cp-3",
                 "state" => "In Progress",
                 "blocking_identifiers" => ["MT-CP-10"]
               }
             ]

      assert payload["text"] =~ "fake worker m3 precheck"
    end)
  end

  test "presenter m3 precheck payload normalizes malformed worker body safely" do
    payload =
      SymphonyElixirWeb.Presenter.m3_precheck_payload(%{
        "generated_at" => "2026-05-12T00:00:00Z",
        "eligible_todos" => %{"issue_identifier" => "bad-shape"},
        "dispatched_todos" => nil,
        "capacity_queued_todos" => "bad-shape",
        "blocked_todos" => %{
          "MT-BLOCKED-1" => "bad-shape",
          "MT-BLOCKED-2" => ["waiting on dependency"]
        },
        "anomalies" => %{"type" => "bad-shape"},
        "current_work" => %{
          "count" => "bad-count",
          "entries" => [
            %{
              "issue_id" => "cp-running",
              "issue_identifier" => "RUN-CP-1",
              "state" => "In Progress"
            }
          ]
        }
      })

    assert payload.generated_at == "2026-05-12T00:00:00Z"
    assert payload.eligible_todos == []
    assert payload.dispatched_todos == []
    assert payload.capacity_queued_todos == []
    assert payload.blocked_todos == %{"MT-BLOCKED-2" => ["waiting on dependency"]}
    assert payload.anomalies == []

    assert payload.current_work == %{
             count: 1,
             entries: [
               %{
                 "issue_id" => "cp-running",
                 "issue_identifier" => "RUN-CP-1",
                 "state" => "In Progress"
               }
             ]
           }

    fallback_payload =
      SymphonyElixirWeb.Presenter.m3_precheck_payload(%{
        "blocked_todos" => "bad-shape"
      })

    assert fallback_payload.blocked_todos == %{}
  end

  test "control-plane dashboard renders m3 precheck result on demand" do
    test_root = temp_root!("project-precheck-live")
    manager_name = Module.concat(__MODULE__, ProjectPrecheckLiveManager)
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

    assert {:ok, _running_state} = ProjectProcessManager.start_project(manager_name, "alpha")

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "运行预检"

    view
    |> element("button[phx-click='run_m3_precheck'][phx-value-project_id='alpha']")
    |> render_click()

    rendered = render(view)
    assert rendered =~ "运行预检"
    assert rendered =~ "依赖阻塞"
    assert rendered =~ "可放行 Todo"
    assert rendered =~ "容量排队"
    assert rendered =~ "本轮已派发"
    assert rendered =~ "异常执行态"
    assert rendered =~ "当前执行中"
    assert rendered =~ "MT-CP-2"
    assert rendered =~ "MT-CP-1"
    assert rendered =~ "RUN-CP-1"
    assert rendered =~ "MT-CP-3"
    refute rendered =~ "fake worker m3 precheck"
  end

  test "workflow dashboard renders m3 precheck entry and result on demand" do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      tracker_kind: "memory",
      m3_enabled: true,
      max_concurrent_agents: 2
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{id: "issue-1", identifier: "MT-1", title: "Ready 1", state: "Todo", blocked_by: []},
      %Issue{id: "issue-2", identifier: "MT-2", title: "Ready 2", state: "Todo", blocked_by: []},
      %Issue{
        id: "issue-3",
        identifier: "MT-3",
        title: "Blocked",
        state: "Todo",
        blocked_by: [%{id: "dep-1", identifier: "MT-9", state: "In Progress", project_slug: "alpha"}]
      },
      %Issue{
        id: "issue-4",
        identifier: "MT-4",
        title: "Blocked but running",
        state: "In Progress",
        blocked_by: [%{id: "dep-2", identifier: "MT-10", state: "Todo", project_slug: "alpha"}]
      }
    ])

    orchestrator_name = Module.concat(__MODULE__, :WorkflowDashboardM3PrecheckOrchestrator)

    start_supervised!(
      {M3PrecheckOrchestrator,
       name: orchestrator_name,
       max_concurrent_agents: 2,
       running: %{
         "running-1" => %{issue: %Issue{id: "running-1", identifier: "RUN-1", state: "In Progress"}}
       }}
    )

    start_test_endpoint(orchestrator: orchestrator_name)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Todo 池检验"
    assert html =~ "M3-0 预检"
    assert html =~ "尚未运行。点击“运行预检”查看当前 Todo 池放行、容量排队、阻塞与异常判断。"
    refute html =~ "可放行 0"
    refute html =~ "(none)"

    view
    |> element("button[phx-click='run_m3_precheck'][phx-value-project_id='workflow']")
    |> render_click()

    rendered = render(view)
    assert rendered =~ "可放行 Todo"
    assert rendered =~ "容量排队"
    assert rendered =~ "本轮已派发"
    assert rendered =~ "依赖阻塞"
    assert rendered =~ "当前执行中"
    assert rendered =~ "异常执行态"
    assert rendered =~ "MT-1"
    assert rendered =~ "MT-2"
    assert rendered =~ "MT-3"
    assert rendered =~ "waiting on non-terminal blockers: MT-9"
    assert rendered =~ "RUN-1"
    assert rendered =~ "MT-4"
  end

  test "workflow dashboard shows m3 precheck failure instead of an empty result" do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      tracker_kind: "memory",
      m3_enabled: true,
      max_concurrent_agents: 2
    )

    previous_override = Application.get_env(:symphony_elixir, :tracker_adapter_override)

    on_exit(fn ->
      if is_nil(previous_override) do
        Application.delete_env(:symphony_elixir, :tracker_adapter_override)
      else
        Application.put_env(:symphony_elixir, :tracker_adapter_override, previous_override)
      end
    end)

    Application.put_env(:symphony_elixir, :tracker_adapter_override, FailingTrackerAdapter)

    orchestrator_name = Module.concat(__MODULE__, :WorkflowDashboardM3PrecheckFailureOrchestrator)

    start_supervised!({M3PrecheckOrchestrator, name: orchestrator_name, max_concurrent_agents: 2})

    start_test_endpoint(orchestrator: orchestrator_name)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Todo 池检验"

    view
    |> element("button[phx-click='run_m3_precheck'][phx-value-project_id='workflow']")
    |> render_click()

    rendered = render(view)
    assert rendered =~ "m3 precheck request failed"
    refute rendered =~ "(none)"
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
        workflow_source: /tmp/alpha/WORKFLOW.md
        workflow_generated: /tmp/alpha/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/alpha
        logs_root: /tmp/logs/alpha
        project_slug: alpha-slug
        repo_url: https://example.com/alpha.git
      - id: Beta
        name: Beta
        workflow_source: /tmp/beta/WORKFLOW.md
        workflow_generated: /tmp/beta/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/beta
        logs_root: /tmp/logs/beta
        project_slug: beta-slug
        repo_url: https://example.com/beta.git
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
        workflow_source: /tmp/alpha/WORKFLOW.md
        workflow_generated: /tmp/alpha/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/alpha
        logs_root: /tmp/logs/alpha
        project_slug: alpha-slug
        repo_url: https://example.com/alpha.git
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
    base_endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.put_new(:runtime_mode, :workflow)

    endpoint_config =
      if Keyword.has_key?(overrides, :project_registry) do
        Keyword.merge(base_endpoint_config, overrides)
      else
        base_endpoint_config
        |> Keyword.delete(:project_registry)
        |> Keyword.merge(overrides)
      end

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp static_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          title: "HTTP issue",
          issue_url: "https://example.org/issues/MT-HTTP",
          state: "In Progress",
          linear_state: "In Progress",
          current_phase: "codex_reasoning",
          current_action: "reasoning summary streaming",
          health: "normal",
          run_status: "running",
          approval_pending: true,
          tool_failure: false,
          blocked_by: [
            %{
              identifier: "MT-BLOCKER-1",
              title: "HTTP blocker",
              state: "In Progress",
              url: "https://example.org/issues/MT-BLOCKER-1"
            }
          ],
          session_id: "thread-http",
          thread_id: "thread-http",
          turn_id: "turn-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: DateTime.utc_now(),
          last_codex_event: :notification,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: DateTime.utc_now(),
          last_error: nil
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

  defp refute_rendered_raw_activity?(rendered) when is_binary(rendered) do
    not String.contains?(rendered, "rendered") and
      not String.contains?(rendered, "notification") and
      not String.contains?(rendered, "agent message content streaming: structured update") and
      not String.contains?(rendered, "2026-05-13T03:00:00Z") and
      not String.contains?(rendered, "Timeline") and
      not String.contains?(rendered, "Prompt") and
      not String.contains?(rendered, "Shell output") and
      not String.contains?(rendered, "Recent events")
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp summary_row_text(document, label) do
    document
    |> find_section_by_title("Overview")
    |> then(fn
      nil -> []
      section -> Floki.find(section, "p.mono")
    end)
    |> Enum.map(&Floki.text(&1, sep: " ", deep: true))
    |> Enum.map(&String.replace(&1, ~r/\s+/, " "))
    |> Enum.map(&String.replace(&1, ~r/\s*:\s*/, ": "))
    |> Enum.map(&String.trim/1)
    |> Enum.find(&String.starts_with?(&1, "#{label}:"))
  end

  defp project_section_texts(document, title) do
    document
    |> find_section_by_title(title)
    |> then(fn
      nil -> []
      section -> Floki.find(section, "p.mono, p.metric-label")
    end)
    |> Enum.map(&Floki.text(&1, sep: " ", deep: true))
    |> Enum.map(&String.replace(&1, ~r/\s+/, " "))
    |> Enum.map(&String.trim/1)
  end

  defp run_summaries_empty_state_text(document) do
    document
    |> find_section_by_title("Run summaries")
    |> then(fn
      nil -> []
      section -> Floki.find(section, "p.empty-state")
    end)
    |> Floki.text()
    |> String.trim()
  end

  defp metric_value(document, label) do
    document
    |> Floki.find("article.metric-card")
    |> Enum.find(fn metric ->
      metric
      |> Floki.find("p.metric-label")
      |> Floki.text()
      |> String.trim() == label
    end)
    |> then(fn
      nil ->
        nil

      metric ->
        metric
        |> Floki.find("p.metric-value")
        |> Floki.text()
        |> String.trim()
    end)
  end

  defp action_needed_primary_text(document) do
    document
    |> find_section_by_title("Action Needed")
    |> then(fn
      nil -> []
      section -> Floki.find(section, "[data-role='action-needed-primary']")
    end)
    |> Floki.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp section_expanded?(document, title) do
    section_name =
      case title do
        "Overview" -> "overview"
        "Action Needed" -> "action-needed"
        "Timeline" -> "timeline"
        "Context" -> "context"
        "Event Detail" -> "event-detail"
        _ -> nil
      end

    document
    |> Floki.find(~s(section[data-section="#{section_name}"] .run-section-body))
    |> List.first()
    |> case do
      {_tag, attributes, _children} -> not Map.has_key?(Enum.into(attributes, %{}), "hidden")
      _ -> false
    end
  end

  defp run_live_project_registry(issue_identifier, title) do
    %StaticProjectRegistry{
      entries: [
        %{
          project_id: "alpha",
          project_name: "Alpha",
          validation_result: :valid,
          validation_errors: [],
          runtime_state: %{
            status: :running,
            run_summaries: [
              %{
                issue_identifier: issue_identifier,
                title: title,
                linear_state: "In Progress",
                current_phase: "codex_waiting_next_event",
                health: "normal"
              }
            ]
          }
        }
      ]
    }
  end

  defp run_live_detail_payload(event_id) do
    %{
      event: %{
        event_id: event_id,
        timestamp: "2026-05-14T02:01:00Z",
        source: "codex",
        event_type: "turn_completed",
        event_group: "turn",
        summary: "#{event_id} summary"
      },
      run: %{issue_identifier: "MT-WORKFLOW-EVENTS", run_id: "run-#{event_id}"},
      context: %{session_id: "session-#{event_id}", thread_id: "thread-#{event_id}", turn_id: "turn-#{event_id}"},
      summaries: %{
        tool_call: "shell",
        payload: "JSON object with 1 top-level keys",
        prompt: nil,
        shell: "git status --short"
      },
      surfaces: %{
        raw: %{available: false, byte_size: 0, preview: nil, truncated: false},
        payload: %{available: true, byte_size: 18, preview: "{\"tool\":\"shell\"}", truncated: false},
        prompt: %{available: false, byte_size: 0, preview: nil, truncated: false},
        shell: %{available: true, byte_size: 18, preview: "git status --short", truncated: false}
      }
    }
  end

  defp find_section_by_title(document, title) do
    document
    |> Floki.find("section.section-card")
    |> Enum.find(fn section ->
      Floki.find(section, "h2.section-title")
      |> Floki.text()
      |> String.trim() == title
    end)
  end

  defp article_mono_texts(article) do
    article
    |> Floki.find("p.mono")
    |> Enum.map(&Floki.text(&1, sep: " ", deep: true))
    |> Enum.map(&String.replace(&1, ~r/\s+/, " "))
    |> Enum.map(&String.trim/1)
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

  defp start_stub_http_server(handler) when is_function(handler, 2) do
    port = reserve_tcp_port!()
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, listener} = open_stub_http_listener(port)

        send(parent, {:stub_http_server_ready, self()})
        accept_stub_http_requests(listener, handler)
      end)

    assert_receive {:stub_http_server_ready, ^pid}

    on_exit(fn ->
      Process.exit(pid, :kill)
      wait_for_tcp_port_closed(port)
    end)

    {:ok, port}
  end

  defp open_stub_http_listener(port) do
    :gen_tcp.listen(port, [:binary, {:active, false}, {:reuseaddr, true}, {:ip, {127, 0, 0, 1}}])
  end

  defp accept_stub_http_requests(listener, handler) do
    {:ok, socket} = :gen_tcp.accept(listener)

    spawn(fn ->
      serve_stub_http_request(socket, handler)
    end)

    accept_stub_http_requests(listener, handler)
  end

  defp serve_stub_http_request(socket, handler) do
    request = read_stub_http_request(socket)
    {method, path} = parse_http_request(request)
    {status, body} = handler.(method, path)
    json = Jason.encode!(body)

    :gen_tcp.send(
      socket,
      "HTTP/1.1 #{status} #{http_status_text(status)}\r\ncontent-length: #{byte_size(json)}\r\ncontent-type: application/json\r\nconnection: close\r\n\r\n#{json}"
    )

    :gen_tcp.close(socket)
  end

  defp read_stub_http_request(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> data
      _other -> ""
    end
  end

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

  defp wait_for_tcp_port_closed(port, attempts \\ 10)

  defp wait_for_tcp_port_closed(port, attempts) when attempts > 0 do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, {:active, false}], 50) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        Process.sleep(50)
        wait_for_tcp_port_closed(port, attempts - 1)

      {:error, _reason} ->
        :ok
    end
  end

  defp wait_for_tcp_port_closed(_port, _attempts), do: :ok

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

  defp parse_http_request(request) when is_binary(request) do
    case String.split(request, "\r\n", parts: 2) do
      [request_line | _rest] ->
        case String.split(request_line, " ", parts: 3) do
          [method, path | _rest] -> {method, path}
          _other -> {"GET", "/"}
        end

      _other ->
        {"GET", "/"}
    end
  end

  defp http_status_text(200), do: "OK"
  defp http_status_text(400), do: "Bad Request"
  defp http_status_text(404), do: "Not Found"
  defp http_status_text(409), do: "Conflict"
  defp http_status_text(503), do: "Service Unavailable"
  defp http_status_text(_status), do: "OK"

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
      workspace_root: if(Keyword.get(opts, :omit_workspace_root?, false), do: nil, else: workspace_root),
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

  defp project_yaml(project) do
    [
      "  - id: \"#{project.id}\"",
      "    name: \"#{project.name}\"",
      optional_project_yaml_line("workflow_source", project[:workflow_source]),
      "    workflow_generated: \"#{project.workflow_generated}\"",
      project.workspace_root && "    workspace_root: \"#{project.workspace_root}\"",
      "    logs_root: \"#{project.logs_root}\"",
      optional_project_yaml_line("project_slug", project[:project_slug]),
      optional_project_yaml_line("repo_url", project[:repo_url]),
      "    enabled: #{if(project.enabled, do: "true", else: "false")}",
      "    worker_port: #{project.worker_port}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp optional_project_yaml_line(_field, nil), do: nil
  defp optional_project_yaml_line(field, value), do: "    #{field}: \"#{value}\""

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
    expected_run_summaries = Keyword.get(expected, :run_summaries, [])

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
      "runtime_state",
      "run_summaries"
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
    assert project["run_summaries"] == expected_run_summaries
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
    sleep_ms = Keyword.get(opts, :sleep_ms, 25)

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
      attempts,
      sleep_ms
    )

    assert_eventually(extra_check, extra_attempts, sleep_ms)
  end

  defp assert_eventually(fun, attempts \\ 20, sleep_ms \\ 25)

  defp assert_eventually(fun, attempts, sleep_ms) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(sleep_ms)
      assert_eventually(fun, attempts - 1, sleep_ms)
    end
  end

  defp assert_eventually(_fun, 0, _sleep_ms), do: flunk("condition not met in time")

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
