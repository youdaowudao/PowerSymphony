defmodule SymphonyElixir.CoreTest do
  use SymphonyElixir.TestSupport

  @resource_binding_file ".symphony-resource.json"
  @continuation_retry_callback_issue %Issue{
    id: "issue-continuation-retry-callback",
    identifier: "MT-570",
    title: "Continuation callback",
    description: "Should keep claim and retry through the real callback path",
    state: "In Progress",
    labels: []
  }

  defmodule ContinuationRetryCallbackTrackerAdapter do
    alias SymphonyElixir.CoreTest

    def fetch_candidate_issues, do: {:ok, [CoreTest.continuation_retry_callback_issue()]}

    def fetch_issues_by_states(states) when is_list(states) do
      issue = CoreTest.continuation_retry_callback_issue()

      normalized_states =
        states
        |> Enum.map(&normalize_state/1)
        |> MapSet.new()

      if MapSet.member?(normalized_states, normalize_state(issue.state)) do
        {:ok, [issue]}
      else
        {:ok, []}
      end
    end

    def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
      issue = CoreTest.continuation_retry_callback_issue()

      if issue.id in issue_ids do
        {:ok, [issue]}
      else
        {:ok, []}
      end
    end

    def create_comment(_issue_id, _body), do: :ok
    def update_issue_state(_issue_id, _state_name), do: :ok

    defp normalize_state(state) when is_binary(state) do
      state
      |> String.trim()
      |> String.downcase()
    end

    defp normalize_state(_state), do: ""
  end

  def continuation_retry_callback_issue, do: @continuation_retry_callback_issue

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

  test "config defaults and validation checks" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: nil,
      poll_interval_ms: nil,
      tracker_active_states: nil,
      tracker_terminal_states: nil,
      codex_command: nil
    )

    refute File.read!(Workflow.workflow_file_path()) =~ "\ncontrol_plane:\n"

    config = Config.settings!()
    assert config.polling.interval_ms == 30_000
    assert config.tracker.active_states == ["Todo", "In Progress", "Checking"]
    assert config.tracker.terminal_states == ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    assert config.tracker.assignee == nil
    assert config.agent.max_turns == 20
    assert config.control_plane.health_poll_interval_ms == 3_000
    assert config.control_plane.health_check_timeout_ms == 1_000

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: "invalid")

    assert_raise ArgumentError, ~r/interval_ms/, fn ->
      Config.settings!().polling.interval_ms
    end

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "polling.interval_ms"

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: 45_000)
    assert Config.settings!().polling.interval_ms == 45_000

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_turns"

    write_workflow_file!(Workflow.workflow_file_path(), control_plane: %{health_poll_interval_ms: 0})
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "control_plane.health_poll_interval_ms"

    write_workflow_file!(Workflow.workflow_file_path(), control_plane: %{health_check_timeout_ms: 0})
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "control_plane.health_check_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 5)
    assert Config.settings!().agent.max_turns == 5

    write_workflow_file!(Workflow.workflow_file_path(), control_plane: %{health_poll_interval_ms: 4_500})

    assert Config.settings!().control_plane.health_poll_interval_ms == 4_500
    assert Config.settings!().control_plane.health_check_timeout_ms == 1_000

    write_workflow_file!(Workflow.workflow_file_path(), control_plane: %{health_check_timeout_ms: 1_500})
    assert Config.settings!().control_plane.health_poll_interval_ms == 3_000
    assert Config.settings!().control_plane.health_check_timeout_ms == 1_500

    write_workflow_file!(Workflow.workflow_file_path(), control_plane: %{health_poll_interval_ms: "invalid"})

    assert_raise ArgumentError, ~r/health_poll_interval_ms/, fn ->
      Config.settings!().control_plane.health_poll_interval_ms
    end

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "control_plane.health_poll_interval_ms"

    write_workflow_file!(Workflow.workflow_file_path(), control_plane: %{health_check_timeout_ms: "invalid"})

    assert_raise ArgumentError, ~r/health_check_timeout_ms/, fn ->
      Config.settings!().control_plane.health_check_timeout_ms
    end

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "control_plane.health_check_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: "Todo,  Review,")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    assert {:error, :missing_linear_project_slug} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "project",
      codex_command: ""
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.command"
    assert message =~ "can't be blank"

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "   ")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.command == "   "

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "/bin/sh app-server")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "definitely-not-valid")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "unsafe-ish")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_turn_sandbox_policy: %{type: "workspaceWrite", writableRoots: ["relative/path"]}
    )

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.approval_policy"

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.thread_sandbox"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "123")
    assert {:error, {:unsupported_tracker_kind, "123"}} = Config.validate!()
  end

  test "current WORKFLOW.md file is valid and preserves direct single-project placeholders" do
    original_workflow_path = Workflow.workflow_file_path()
    on_exit(fn -> Workflow.set_workflow_file_path(original_workflow_path) end)
    Workflow.clear_workflow_file_path()

    assert {:ok, %{config: config, prompt: prompt}} = Workflow.load()
    assert is_map(config)

    tracker = Map.get(config, "tracker", %{})
    assert is_map(tracker)
    assert Map.get(tracker, "kind") == "linear"
    assert Map.get(tracker, "project_slug") == "set-via-generated-workflow"
    assert is_list(Map.get(tracker, "active_states"))
    assert is_list(Map.get(tracker, "terminal_states"))

    m3 = Map.get(config, "m3", %{})
    assert is_map(m3)
    assert Map.get(m3, "enabled") == true
    assert Config.m3_enabled?() == true

    hooks = Map.get(config, "hooks", %{})
    assert is_map(hooks)

    assert Map.get(hooks, "after_create") =~
             ~s(git clone --depth 1 "${SYMPHONY_REPO_URL:?set SYMPHONY_REPO_URL for direct single-project runs}" .)

    assert Map.get(hooks, "after_create") =~ "control-plane workflow generation replaces the clone command above"
    assert Map.get(hooks, "after_create") =~ "cd elixir && mise trust"
    assert Map.get(hooks, "after_create") =~ "mise exec -- mix deps.get"
    assert Map.get(hooks, "before_remove") =~ "true"

    assert String.trim(prompt) != ""
    assert is_binary(Config.workflow_prompt())
    assert Config.workflow_prompt() == prompt
  end

  test "linear api token resolves from LINEAR_API_KEY env var" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    env_api_key = "test-linear-api-key"

    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.put_env("LINEAR_API_KEY", env_api_key)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.api_key == env_api_key
    assert Config.settings!().tracker.project_slug == "project"
    assert :ok = Config.validate!()
  end

  test "linear assignee resolves from LINEAR_ASSIGNEE env var" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")
    env_assignee = "dev@example.com"

    on_exit(fn -> restore_env("LINEAR_ASSIGNEE", previous_linear_assignee) end)
    System.put_env("LINEAR_ASSIGNEE", env_assignee)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_assignee: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.assignee == env_assignee
  end

  test "workflow file path defaults to WORKFLOW.md in the current working directory when app env is unset" do
    original_workflow_path = Workflow.workflow_file_path()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
    end)

    Workflow.clear_workflow_file_path()

    assert Workflow.workflow_file_path() == Path.join(File.cwd!(), "WORKFLOW.md")
  end

  test "workflow file path resolves from app env when set" do
    app_workflow_path = "/tmp/app/WORKFLOW.md"

    on_exit(fn ->
      Workflow.clear_workflow_file_path()
    end)

    Workflow.set_workflow_file_path(app_workflow_path)

    assert Workflow.workflow_file_path() == app_workflow_path
  end

  test "orchestrator inert start skips startup cleanup and initial poll scheduling" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    orchestrator_name = Module.concat(__MODULE__, :InertStartupOrchestrator)
    pid = nil

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-inert-startup-#{System.unique_integer([:positive])}"
      )

    closed_identifier = "MT-STARTUP-CLEANUP"
    closed_workspace = Path.join(test_root, closed_identifier)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: test_root,
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{id: "issue-startup-cleanup", identifier: closed_identifier, state: "Closed", labels: []}
    ])

    try do
      File.mkdir_p!(closed_workspace)
      {:ok, pid} = start_inert_orchestrator(orchestrator_name)

      state = :sys.get_state(pid)

      refute state.poll_check_in_progress
      assert state.tick_timer_ref == nil
      assert state.tick_token == nil
      assert File.exists?(closed_workspace)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)

      if is_pid(pid) and Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end
  end

  test "orchestrator active start performs startup cleanup and enters startup poll flow" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    orchestrator_name = Module.concat(__MODULE__, :ActiveStartupOrchestrator)
    pid = nil

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-active-startup-#{System.unique_integer([:positive])}"
      )

    closed_identifier = "MT-ACTIVE-STARTUP"
    closed_workspace = Path.join(test_root, closed_identifier)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: test_root,
      poll_interval_ms: 30_000,
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{id: "issue-active-startup", identifier: closed_identifier, state: "Closed", labels: []}
    ])

    try do
      File.mkdir_p!(closed_workspace)

      File.write!(
        Path.join(closed_workspace, @resource_binding_file),
        Jason.encode!(%{
          "issue_id" => "issue-active-startup",
          "issue_identifier" => closed_identifier,
          "run_instance_id" => "run-startup-old",
          "worker_host" => nil,
          "workspace_path" => closed_workspace,
          "state" => "closing",
          "closing_reason" => "startup_terminal_sweep",
          "inserted_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        })
      )

      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      assert_eventually(
        fn ->
          state = :sys.get_state(pid)
          binding = Workspace.read_resource_binding(closed_workspace)

          File.dir?(closed_workspace) and
            match?({:ok, %{"state" => "closing", "closing_reason" => "startup_terminal_sweep"}}, binding) and
            state.poll_check_in_progress == true and
            state.next_poll_due_at_ms == nil and
            state.tick_timer_ref == nil and
            state.tick_token == nil
        end,
        40,
        2
      )

      assert_eventually(
        fn ->
          state = :sys.get_state(pid)

          next_poll_due_in_ms =
            case state.next_poll_due_at_ms do
              due_at_ms when is_integer(due_at_ms) ->
                due_at_ms - System.monotonic_time(:millisecond)

              _ ->
                nil
            end

          File.dir?(closed_workspace) and
            state.poll_check_in_progress == false and
            is_reference(state.tick_timer_ref) and
            is_reference(state.tick_token) and
            is_integer(state.next_poll_due_at_ms) and
            is_integer(next_poll_due_in_ms) and
            next_poll_due_in_ms > 20_000
        end,
        40
      )

      assert {:ok, binding} = Workspace.read_resource_binding(closed_workspace)
      assert binding["state"] == "closing"
      assert binding["closing_reason"] == "startup_terminal_sweep"
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)

      if is_pid(pid) and Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end
  end

  test "orchestrator public start_link rejects reserved startup_mode option" do
    assert_raise ArgumentError, ~r/startup_mode is reserved for internal test helpers/, fn ->
      Orchestrator.start_link(name: Module.concat(__MODULE__, :RejectedStartupModeOrchestrator), startup_mode: :active)
    end
  end

  test "workflow load accepts prompt-only files without front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "PROMPT_ONLY_WORKFLOW.md")
    File.write!(workflow_path, "Prompt only\n")

    assert {:ok, %{config: %{}, prompt: "Prompt only", prompt_template: "Prompt only"}} =
             Workflow.load(workflow_path)
  end

  test "workflow load accepts unterminated front matter with an empty prompt" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "UNTERMINATED_WORKFLOW.md")
    File.write!(workflow_path, "---\ntracker:\n  kind: linear\n")

    assert {:ok, %{config: %{"tracker" => %{"kind" => "linear"}}, prompt: "", prompt_template: ""}} =
             Workflow.load(workflow_path)
  end

  test "workflow load rejects non-map front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "INVALID_FRONT_MATTER_WORKFLOW.md")
    File.write!(workflow_path, "---\n- not-a-map\n---\nPrompt body\n")

    assert {:error, :workflow_front_matter_not_a_map} = Workflow.load(workflow_path)
  end

  test "SymphonyElixir.start_link delegates to the orchestrator" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    on_exit(fn ->
      if orchestrator_configured_child?() and is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    if is_pid(orchestrator_pid) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
    end

    assert {:ok, pid} = SymphonyElixir.start_link()
    assert Process.whereis(SymphonyElixir.Orchestrator) == pid

    GenServer.stop(pid)
  end

  defp orchestrator_configured_child? do
    SymphonyElixir.Application.child_specs(SymphonyElixir.runtime_mode())
    |> Enum.any?(fn
      %{id: SymphonyElixir.Orchestrator} -> true
      SymphonyElixir.Orchestrator -> true
      _ -> false
    end)
  end

  test "linear issue state reconciliation fetch with no running issues is a no-op" do
    assert {:ok, []} = Client.fetch_issue_states_by_ids([])
  end

  test "non-active issue state stops running agent without cleaning workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-nonactive-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-1"
    issue_identifier = "MT-555"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "Todo", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Backlog",
        title: "Queued",
        description: "Not started",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal issue state stops running agent and cleans workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-2"
    issue_identifier = "MT-556"
    workspace = Path.join(test_root, issue_identifier)
    orchestrator_name = Module.concat(__MODULE__, :TerminalReconcileOrchestrator)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      File.write!(
        Path.join(workspace, @resource_binding_file),
        Jason.encode!(%{
          "issue_id" => issue_id,
          "issue_identifier" => issue_identifier,
          "run_instance_id" => "run-terminal-cleanup",
          "worker_host" => nil,
          "workspace_path" => workspace,
          "state" => "active",
          "closing_reason" => nil,
          "inserted_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        })
      )

      {:ok, pid} = start_inert_orchestrator(orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      agent_pid =
        spawn(fn ->
          Process.flag(:trap_exit, true)

          receive do
            {:EXIT, _from, :shutdown} -> :ok
          end
        end)

      initial_state = :sys.get_state(pid)
      ref = Process.monitor(agent_pid)

      state =
        initial_state
        |> Map.put(:running, %{
          issue_id => %{
            pid: agent_pid,
            ref: ref,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            run_instance_id: "run-terminal-cleanup",
            workspace_path: workspace,
            started_at: DateTime.utc_now()
          }
        })
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
        |> Map.put(:codex_totals, %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0})

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Closed",
        title: "Done",
        description: "Completed",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      assert %{cleanup_workspace: true} = updated_state.running[issue_id]
      assert MapSet.member?(updated_state.claimed, issue_id)
      assert File.exists?(workspace)
      assert {:ok, binding} = Workspace.read_resource_binding(workspace)
      assert binding["state"] == "closing"
      assert binding["closing_reason"] == "terminal_running_cleanup"

      :sys.replace_state(pid, fn _ -> updated_state end)
      send(pid, {:DOWN, ref, :process, agent_pid, :shutdown})

      assert_eventually(
        fn ->
          state = :sys.get_state(pid)

          not Map.has_key?(state.running, issue_id) and
            not MapSet.member?(state.claimed, issue_id) and
            not Map.has_key?(state.retry_attempts, issue_id) and
            MapSet.member?(state.completed, issue_id) and
            not File.exists?(workspace)
        end,
        20
      )

      state = :sys.get_state(pid)
      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Map.has_key?(state.retry_attempts, issue_id)
      assert MapSet.member?(state.completed, issue_id)
      refute Process.alive?(agent_pid)
    after
      File.rm_rf(test_root)
    end
  end

  test "missing running issues stop active agents without cleaning the workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-running-reconcile-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-missing"
    issue_identifier = "MT-557"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        poll_interval_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      orchestrator_name = Module.concat(__MODULE__, :MissingRunningIssueOrchestrator)
      {:ok, pid} = start_inert_orchestrator(orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      Process.sleep(50)

      assert {:ok, workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(test_root, issue_identifier))

      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: agent_pid,
        ref: nil,
        identifier: issue_identifier,
        issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, :tick)
      Process.sleep(100)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end
  end

  test "reconcile updates running issue state for active issues" do
    issue_id = "issue-3"

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: self(),
          ref: nil,
          identifier: "MT-557",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-557",
            state: "Todo"
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-557",
      state: "In Progress",
      title: "Active state refresh",
      description: "State should be refreshed",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)
    updated_entry = updated_state.running[issue_id]

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert updated_entry.issue.state == "In Progress"
  end

  test "todo auto dispatch requires project-level m3 opt-in" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "todo-no-m3",
      identifier: "MT-1008",
      title: "Needs manual start",
      state: "Todo",
      blocked_by: []
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "prepare_issue_for_dispatch keeps todo state until worker startup succeeds" do
    write_workflow_file!(Workflow.workflow_file_path(), m3_enabled: true)

    issue = %Issue{
      id: "todo-transition",
      identifier: "MT-1009",
      title: "Transition before run",
      state: "Todo",
      blocked_by: []
    }

    assert {:ok, %Issue{state: "Todo"} = refreshed_issue} =
             Orchestrator.prepare_issue_for_dispatch_for_test(
               issue,
               fn
                 ["todo-transition"] -> {:ok, [issue]}
               end,
               fn "todo-transition", "In Progress" -> :ok end
             )

    assert refreshed_issue.identifier == "MT-1009"
  end

  test "m3_precheck returns current_work and queue split based on running workers" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      m3_enabled: true,
      max_concurrent_agents: 2
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{id: "issue-1", identifier: "MT-1100", title: "Todo 1", state: "Todo"},
      %Issue{id: "issue-2", identifier: "MT-1101", title: "Todo 2", state: "Todo"}
    ])

    orchestrator_name = Module.concat(__MODULE__, :M3PrecheckCurrentWorkOrchestrator)

    start_supervised!(
      {M3PrecheckOrchestrator,
       name: orchestrator_name,
       max_concurrent_agents: 2,
       running: %{
         "running-1" => %{
           issue: %Issue{id: "running-1", identifier: "RUN-1100", state: "In Progress"},
           worker_host: "worker-a",
           workspace_path: "/tmp/run-1100",
           started_at: DateTime.utc_now()
         }
       }}
    )

    assert {:ok, payload} = Orchestrator.m3_precheck(orchestrator_name)
    assert payload.current_work.count == 1

    assert payload.current_work.entries == [
             %{
               issue_id: "running-1",
               issue_identifier: "RUN-1100",
               state: "In Progress",
               worker_host: "worker-a",
               workspace_path: "/tmp/run-1100"
             }
           ]

    assert Enum.map(payload.eligible_todos, & &1.identifier) == ["MT-1100", "MT-1101"]
    assert Enum.map(payload.dispatched_todos, & &1.identifier) == ["MT-1100"]
    assert Enum.map(payload.capacity_queued_todos, & &1.identifier) == ["MT-1101"]
    assert payload.blocked_todos == %{}
    assert payload.anomalies == []
  end

  test "todo transition rollback restores todo state and stops spawned worker when post-start revalidation fails" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      m3_enabled: true,
      max_concurrent_agents: 1
    )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)

    issue =
      %Issue{
        id: "todo-rollback",
        identifier: "MT-1110",
        title: "Rollback after spawn",
        state: "Todo",
        blocked_by: []
      }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    orchestrator_name = Module.concat(__MODULE__, :TodoRollbackOrchestrator)
    {:ok, pid} = start_inert_orchestrator(orchestrator_name)

    on_exit(fn ->
      restore_app_env(:memory_tracker_issues, previous_memory_issues)

      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    retry_token = make_ref()

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:max_concurrent_agents, 1)
      |> Map.put(:retry_attempts, %{
        issue.id => %{
          attempt: 1,
          timer_ref: nil,
          retry_token: retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 30_000,
          identifier: issue.identifier,
          error: "retrying"
        }
      })
    end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      issue,
      %Issue{id: "other-todo", identifier: "MT-1111", title: "Other", state: "Todo", blocked_by: []}
    ])

    send(pid, {:retry_issue, issue.id, retry_token})
    Process.sleep(100)

    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue.id)
    refute MapSet.member?(state.claimed, issue.id)
    assert %{attempt: attempt, error: error} = state.retry_attempts[issue.id]
    assert attempt >= 2
    assert error =~ "failed to transition spawned issue"

    assert {:ok, [%Issue{state: "Todo"}]} =
             SymphonyElixir.Tracker.fetch_issue_states_by_ids([issue.id])
  end

  test "todo dispatch selection remains stable for the first eligible todo across repeated should_dispatch checks" do
    write_workflow_file!(Workflow.workflow_file_path(), m3_enabled: true, max_concurrent_agents: 1)

    issues = [
      %Issue{id: "todo-a", identifier: "MT-1120", title: "A", state: "Todo", blocked_by: []},
      %Issue{id: "todo-b", identifier: "MT-1121", title: "B", state: "Todo", blocked_by: []}
    ]

    state = %Orchestrator.State{
      max_concurrent_agents: 1,
      running: %{},
      claimed: MapSet.new(),
      blocked_claims: %{},
      retry_attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    assert Orchestrator.should_dispatch_issue_for_test(List.first(issues), state)
    assert Orchestrator.should_dispatch_issue_for_test(List.first(issues), state)
  end

  test "reconcile stops running issue when it is reassigned away from this worker" do
    issue_id = "issue-reassigned"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-561",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-561",
            state: "In Progress",
            assigned_to_worker: true
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-561",
      state: "In Progress",
      title: "Reassigned active issue",
      description: "Worker should stop",
      labels: [],
      assigned_to_worker: false
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "normal worker exit schedules active-state continuation retry" do
    issue_id = "issue-resume"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ContinuationOrchestrator)
    {:ok, pid} = start_inert_orchestrator(orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-558",
      issue: %Issue{id: issue_id, identifier: "MT-558", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(
      pid,
      {:agent_run_result, issue_id,
       %{
         status: :continuation_required,
         reason: :issue_still_active,
         turn_count: 1
       }}
    )

    down_triggered_at_ms = System.monotonic_time(:millisecond)
    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)
    observed_at_ms = System.monotonic_time(:millisecond)

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.completed, issue_id)
    assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
    assert is_integer(due_at_ms)
    assert_due_from_trigger_window(due_at_ms, down_triggered_at_ms, observed_at_ms, 1_000)
  end

  test "normal worker exit without continuation run result does not schedule active-state continuation retry" do
    issue_id = "issue-run-complete"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CompletedRunOrchestrator)
    {:ok, pid} = start_inert_orchestrator(orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-562",
      issue: %Issue{id: issue_id, identifier: "MT-562", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:agent_run_result, issue_id, %{status: :completed, reason: :issue_inactive, turn_count: 1}})
    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.completed, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)
  end

  test "normal completed worker exit releases claim so the issue can be dispatched again" do
    issue_id = "issue-run-reopen"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CompletedRunReopenOrchestrator)
    {:ok, pid} = start_inert_orchestrator(orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-566",
      issue: %Issue{id: issue_id, identifier: "MT-566", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:agent_run_result, issue_id, %{status: :completed, reason: :issue_inactive, turn_count: 1}})
    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    issue = %Issue{
      id: issue_id,
      identifier: "MT-566",
      title: "Reopened after completion",
      description: "Should be dispatchable again",
      state: "In Progress",
      labels: []
    }

    refute MapSet.member?(state.claimed, issue_id)
    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "normal worker exit with continuation run result schedules active-state continuation retry" do
    issue_id = "issue-run-continue"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :RunResultContinuationOrchestrator)
    {:ok, pid} = start_inert_orchestrator(orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-563",
      issue: %Issue{id: issue_id, identifier: "MT-563", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(
      pid,
      {:agent_run_result, issue_id,
       %{
         status: :continuation_required,
         reason: :max_turns_reached,
         turn_count: 2
       }}
    )

    down_triggered_at_ms = System.monotonic_time(:millisecond)
    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)
    observed_at_ms = System.monotonic_time(:millisecond)

    issue = %Issue{
      id: issue_id,
      identifier: "MT-563",
      title: "Continuation remains claimed",
      description: "Should wait for continuation retry",
      state: "In Progress",
      labels: []
    }

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.claimed, issue_id)
    assert MapSet.member?(state.completed, issue_id)
    assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
    assert is_integer(due_at_ms)
    assert_due_from_trigger_window(due_at_ms, down_triggered_at_ms, observed_at_ms, 1_000)
    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "checking issue remains non-dispatchable before cooldown retry due time" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress", "Checking"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    )

    issue = %Issue{
      id: "issue-checking-cooldown",
      identifier: "MT-563CHECK",
      title: "Checking cooldown",
      description: "Should wait for checking retry window",
      state: "Checking",
      labels: []
    }

    state = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new([issue.id]),
      blocked_claims: %{},
      retry_attempts: %{
        issue.id => %{
          attempt: 1,
          due_at_ms: System.monotonic_time(:millisecond) + 60_000,
          retry_token: make_ref(),
          timer_ref: nil,
          identifier: issue.identifier,
          delay_type: :checking_recheck
        }
      },
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "active issue with non-terminal blocker is not dispatchable" do
    issue = %Issue{
      id: "issue-active-blocked",
      identifier: "MT-563A",
      title: "Blocked active issue",
      description: "Should not dispatch while blocker is not terminal",
      state: "In Progress",
      blocked_by: [%{state: "In Progress"}],
      labels: []
    }

    state = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new(),
      blocked_claims: %{},
      retry_attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "active issue becomes dispatchable after all blockers reach terminal state" do
    blocked_issue = %Issue{
      id: "issue-active-unblocked",
      identifier: "MT-563B",
      title: "Previously blocked active issue",
      description: "Should dispatch after blockers close",
      state: "In Progress",
      blocked_by: [%{state: "In Progress"}],
      labels: []
    }

    unblocked_issue = %Issue{blocked_issue | blocked_by: [%{state: "Done"}]}

    state = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new(),
      blocked_claims: %{},
      retry_attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    refute Orchestrator.should_dispatch_issue_for_test(blocked_issue, state)
    assert Orchestrator.should_dispatch_issue_for_test(unblocked_issue, state)
  end

  test "revalidate blocks active issue retry until blockers are terminal" do
    issue = %Issue{
      id: "issue-active-revalidate",
      identifier: "MT-563C",
      title: "Blocked active retry",
      description: "Should skip retry while blocker remains active",
      state: "In Progress",
      blocked_by: [],
      labels: []
    }

    assert {:skip, %Issue{id: "issue-active-revalidate"} = blocked_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(issue, fn [_issue_id] ->
               {:ok, [%Issue{issue | blocked_by: [%{state: "Todo"}]}]}
             end)

    assert blocked_issue.blocked_by == [%{state: "Todo"}]

    assert {:ok, %Issue{id: "issue-active-revalidate"} = unblocked_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(issue, fn [_issue_id] ->
               {:ok, [%Issue{issue | blocked_by: [%{state: "Done"}]}]}
             end)

    assert unblocked_issue.blocked_by == [%{state: "Done"}]
  end

  test "continuation retry callback redispatches through the real retry_issue path while keeping claim until handoff" do
    previous_tracker_adapter = Application.get_env(:symphony_elixir, :tracker_adapter_override)
    issue_id = "issue-continuation-retry-callback"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ContinuationRetryCallbackOrchestrator)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-continuation-retry-callback-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    codex_binary = Path.join(test_root, "fake-codex")

    File.mkdir_p!(workspace_root)

    File.write!(codex_binary, """
    #!/bin/sh
    count=0
    while IFS= read -r _line; do
      count=$((count + 1))
      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          ;;
        3)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-continuation-retry"}}}'
          ;;
        4)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-continuation-retry-1"}}}'
          sleep 30
          exit 0
          ;;
        *)
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress", "In Review"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    Application.put_env(
      :symphony_elixir,
      :tracker_adapter_override,
      ContinuationRetryCallbackTrackerAdapter
    )

    {:ok, pid} = start_inert_orchestrator(orchestrator_name)

    on_exit(fn ->
      restore_app_env(:tracker_adapter_override, previous_tracker_adapter)

      if Process.alive?(pid) do
        running =
          case :sys.get_state(pid) do
            %{running: running} when is_map(running) -> running
            _ -> %{}
          end

        Enum.each(running, fn
          {_running_issue_id, %{pid: running_pid}} when is_pid(running_pid) ->
            if Process.alive?(running_pid) do
              Process.exit(running_pid, :kill)
            end

          _ ->
            :ok
        end)

        Process.exit(pid, :normal)
      end

      File.rm_rf(test_root)
    end)

    initial_state = :sys.get_state(pid)

    worker_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      if Process.alive?(worker_pid) do
        send(worker_pid, :stop)
      end
    end)

    running_entry = %{
      pid: worker_pid,
      ref: ref,
      identifier: "MT-570",
      worker_host: "worker-a",
      workspace_path: "/tmp/continuation-callback",
      issue: %Issue{id: issue_id, identifier: "MT-570", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:max_concurrent_agents, 1)
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(
      pid,
      {:agent_run_result, issue_id,
       %{
         status: :continuation_required,
         reason: :issue_still_active,
         turn_count: 1
       }}
    )

    send(pid, {:DOWN, ref, :process, worker_pid, :normal})

    assert_eventually(
      fn ->
        match?(
          %{
            attempt: 1,
            worker_host: "worker-a",
            workspace_path: "/tmp/continuation-callback"
          },
          :sys.get_state(pid).retry_attempts[issue_id]
        )
      end,
      20
    )

    %{
      attempt: 1,
      retry_token: retry_token,
      timer_ref: timer_ref,
      worker_host: "worker-a",
      workspace_path: "/tmp/continuation-callback"
    } = :sys.get_state(pid).retry_attempts[issue_id]

    Process.cancel_timer(timer_ref, async: false, info: false)

    assert MapSet.member?(:sys.get_state(pid).claimed, issue_id)
    send(pid, {:retry_issue, issue_id, retry_token})

    assert_eventually(
      fn ->
        state = :sys.get_state(pid)

        case state.running[issue_id] do
          %{
            pid: spawned_pid,
            retry_attempt: 1,
            worker_host: nil,
            workspace_path: workspace_path,
            run_instance_id: run_instance_id,
            issue: %Issue{identifier: "MT-570"}
          }
          when is_pid(spawned_pid) and is_binary(workspace_path) and is_binary(run_instance_id) ->
            spawned_pid != worker_pid and
              workspace_path == Path.join(workspace_root, "MT-570") and
              not Map.has_key?(state.retry_attempts, issue_id) and
              MapSet.member?(state.claimed, issue_id) and
              MapSet.member?(state.completed, issue_id)

          _ ->
            false
        end
      end,
      80
    )

    state = :sys.get_state(pid)
    assert MapSet.member?(state.claimed, issue_id)
    assert MapSet.member?(state.completed, issue_id)

    assert %{
             pid: spawned_pid,
             retry_attempt: 1,
             worker_host: nil,
             workspace_path: workspace_path,
             run_instance_id: run_instance_id,
             issue: %Issue{identifier: "MT-570"}
           } = state.running[issue_id]

    assert is_pid(spawned_pid)
    refute spawned_pid == worker_pid
    assert workspace_path == Path.join(workspace_root, "MT-570")
    assert is_binary(run_instance_id)
    refute Map.has_key?(state.retry_attempts, issue_id)
  end

  test "abnormal worker exit increments retry attempt progressively" do
    issue_id = "issue-crash"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CrashRetryOrchestrator)
    {:ok, pid} = start_inert_orchestrator(orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-559",
      retry_attempt: 2,
      issue: %Issue{id: issue_id, identifier: "MT-559", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    down_triggered_at_ms = System.monotonic_time(:millisecond)
    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)
    observed_at_ms = System.monotonic_time(:millisecond)

    assert %{attempt: 3, due_at_ms: due_at_ms, identifier: "MT-559", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_from_trigger_window(due_at_ms, down_triggered_at_ms, observed_at_ms, 40_000)
  end

  test "first abnormal worker exit waits before retrying" do
    issue_id = "issue-crash-initial"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :InitialCrashRetryOrchestrator)
    {:ok, pid} = start_inert_orchestrator(orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560",
      issue: %Issue{id: issue_id, identifier: "MT-560", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 1, due_at_ms: due_at_ms, identifier: "MT-560", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 8_750, 10_500)
  end

  test "stale retry timer messages do not consume newer retry entries" do
    issue_id = "issue-stale-retry"
    orchestrator_name = Module.concat(__MODULE__, :StaleRetryOrchestrator)
    {:ok, pid} = start_inert_orchestrator(orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    current_retry_token = make_ref()
    stale_retry_token = make_ref()

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 2,
          timer_ref: nil,
          retry_token: current_retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 30_000,
          identifier: "MT-561",
          error: "agent exited: :boom"
        }
      })
    end)

    send(pid, {:retry_issue, issue_id, stale_retry_token})
    Process.sleep(50)

    assert %{
             attempt: 2,
             retry_token: ^current_retry_token,
             identifier: "MT-561",
             error: "agent exited: :boom"
           } = :sys.get_state(pid).retry_attempts[issue_id]
  end

  test "manual refresh coalesces repeated requests and ignores superseded ticks" do
    now_ms = System.monotonic_time(:millisecond)
    stale_tick_token = make_ref()

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: now_ms + 30_000,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: stale_tick_token,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:reply, %{queued: true, coalesced: false}, refreshed_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, state)

    assert is_reference(refreshed_state.tick_timer_ref)
    assert is_reference(refreshed_state.tick_token)
    refute refreshed_state.tick_token == stale_tick_token
    assert refreshed_state.next_poll_due_at_ms <= System.monotonic_time(:millisecond)

    assert {:reply, %{queued: true, coalesced: true}, coalesced_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, refreshed_state)

    assert coalesced_state.tick_token == refreshed_state.tick_token
    assert {:noreply, ^coalesced_state} = Orchestrator.handle_info({:tick, stale_tick_token}, coalesced_state)
  end

  test "select_worker_host_for_test skips full ssh hosts under the shared per-host cap" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == "worker-b"
  end

  test "select_worker_host_for_test returns no_worker_capacity when every ssh host is full" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == :no_worker_capacity
  end

  test "select_worker_host_for_test keeps the preferred ssh host when it still has capacity" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 2
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, "worker-a") == "worker-a"
  end

  defp assert_due_in_range(due_at_ms, min_remaining_ms, max_remaining_ms) do
    remaining_ms = due_at_ms - System.monotonic_time(:millisecond)

    assert remaining_ms >= min_remaining_ms
    assert remaining_ms <= max_remaining_ms
  end

  defp assert_due_from_trigger_window(
         due_at_ms,
         trigger_at_ms,
         observed_at_ms,
         expected_delay_ms
       ) do
    scheduled_at_ms = due_at_ms - expected_delay_ms

    assert scheduled_at_ms >= trigger_at_ms
    assert scheduled_at_ms <= observed_at_ms
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp start_inert_orchestrator(name) do
    Orchestrator.start_inert_for_test(name: name)
  end

  test "fetch issues by states with empty state set is a no-op" do
    assert {:ok, []} = Client.fetch_issues_by_states([])
  end

  test "prompt builder renders issue and attempt values from workflow template" do
    workflow_prompt =
      "Ticket {{ issue.identifier }} {{ issue.title }} labels={{ issue.labels }} attempt={{ attempt }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "S-1",
      title: "Refactor backend request path",
      description: "Replace transport layer",
      state: "Todo",
      url: "https://example.org/issues/S-1",
      labels: ["backend"]
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 3)

    assert prompt =~ "Ticket S-1 Refactor backend request path"
    assert prompt =~ "labels=backend"
    assert prompt =~ "attempt=3"
  end

  test "prompt builder renders issue datetime fields without crashing" do
    workflow_prompt = "Ticket {{ issue.identifier }} created={{ issue.created_at }} updated={{ issue.updated_at }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    created_at = DateTime.from_naive!(~N[2026-02-26 18:06:48], "Etc/UTC")
    updated_at = DateTime.from_naive!(~N[2026-02-26 18:07:03], "Etc/UTC")

    issue = %Issue{
      identifier: "MT-697",
      title: "Live smoke",
      description: "Prompt should serialize datetimes",
      state: "Todo",
      url: "https://example.org/issues/MT-697",
      labels: [],
      created_at: created_at,
      updated_at: updated_at
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Ticket MT-697"
    assert prompt =~ "created=2026-02-26T18:06:48Z"
    assert prompt =~ "updated=2026-02-26T18:07:03Z"
  end

  test "prompt builder normalizes nested date-like values, maps, and structs in issue fields" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.identifier }}")

    issue = %Issue{
      identifier: "MT-701",
      title: "Serialize nested values",
      description: "Prompt builder should normalize nested terms",
      state: "Todo",
      url: "https://example.org/issues/MT-701",
      labels: [
        ~N[2026-02-27 12:34:56],
        ~D[2026-02-28],
        ~T[12:34:56],
        %{phase: "test"},
        URI.parse("https://example.org/issues/MT-701")
      ]
    }

    assert PromptBuilder.build_prompt(issue) == "Ticket MT-701"
  end

  test "prompt builder uses strict variable rendering" do
    workflow_prompt = "Work on ticket {{ missing.ticket_id }} and follow these steps."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-123",
      title: "Investigate broken sync",
      description: "Reproduce and fix",
      state: "In Progress",
      url: "https://example.org/issues/MT-123",
      labels: ["bug"]
    }

    assert_raise Solid.RenderError, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder surfaces invalid template content with prompt context" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "{% if issue.identifier %}")

    issue = %Issue{
      identifier: "MT-999",
      title: "Broken prompt",
      description: "Invalid template syntax",
      state: "Todo",
      url: "https://example.org/issues/MT-999",
      labels: []
    }

    assert_raise RuntimeError, ~r/template_parse_error:.*template="/s, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder uses a sensible default template when workflow prompt is blank" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "   \n")

    issue = %Issue{
      identifier: "MT-777",
      title: "Make fallback prompt useful",
      description: "Include enough issue context to start working.",
      state: "In Progress",
      url: "https://example.org/issues/MT-777",
      labels: ["prompt"]
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "You are working on a Linear issue."
    assert prompt =~ "Identifier: MT-777"
    assert prompt =~ "Title: Make fallback prompt useful"
    assert prompt =~ "Body:"
    assert prompt =~ "Include enough issue context to start working."
    assert Config.workflow_prompt() =~ "{{ issue.identifier }}"
    assert Config.workflow_prompt() =~ "{{ issue.title }}"
    assert Config.workflow_prompt() =~ "{{ issue.description }}"
  end

  test "prompt builder default template warns against ending active turns prematurely" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "   \n")

    issue = %Issue{
      identifier: "MT-779",
      title: "Keep active turns open",
      description: "Do not stop after an interim update while the issue is still active.",
      state: "In Progress",
      url: "https://example.org/issues/MT-779",
      labels: ["prompt"]
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Do not end the turn merely because you have posted an interim update while the Linear issue remains active."
    assert prompt =~ "Only stop the turn early when you are truly blocked or when the issue is ready for correct closeout."
  end

  test "prompt builder default template handles missing issue body" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "")

    issue = %Issue{
      identifier: "MT-778",
      title: "Handle empty body",
      description: nil,
      state: "Todo",
      url: "https://example.org/issues/MT-778",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Identifier: MT-778"
    assert prompt =~ "Title: Handle empty body"
    assert prompt =~ "No description provided."
  end

  test "prompt builder reports workflow load failures separately from template parse errors" do
    original_workflow_path = Workflow.workflow_file_path()
    workflow_store_pid = Process.whereis(SymphonyElixir.WorkflowStore)

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)

      if is_pid(workflow_store_pid) and is_nil(Process.whereis(SymphonyElixir.WorkflowStore)) do
        Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
      end
    end)

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)

    Workflow.set_workflow_file_path(Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md"))

    issue = %Issue{
      identifier: "MT-780",
      title: "Workflow unavailable",
      description: "Missing workflow file",
      state: "Todo",
      url: "https://example.org/issues/MT-780",
      labels: []
    }

    assert_raise RuntimeError, ~r/workflow_unavailable:/, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "in-repo WORKFLOW.md renders correctly" do
    workflow_path = Workflow.workflow_file_path()
    Workflow.set_workflow_file_path(Path.expand("WORKFLOW.md", File.cwd!()))

    issue = %Issue{
      identifier: "MT-616",
      title: "Use rich templates for WORKFLOW.md",
      description: "Render with rich template variables",
      state: "In Progress",
      url: "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd",
      labels: ["templating", "workflow"]
    }

    on_exit(fn -> Workflow.set_workflow_file_path(workflow_path) end)

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt =~ "You are working on a Linear ticket `MT-616`"
    assert prompt =~ "Issue context:"
    assert prompt =~ "Identifier: MT-616"
    assert prompt =~ "Title: Use rich templates for WORKFLOW.md"
    assert prompt =~ "Current status: In Progress"
    assert prompt =~ "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd"
    assert prompt =~ "## Stable issue-body model"
    assert prompt =~ "## Preflight body gate"
    assert prompt =~ "## Execution Brief"
    assert prompt =~ "## Codex Workpad"

    assert prompt =~
             "This is an unattended orchestration session only after the preflight body gate has classified the run as `execute`."

    assert prompt =~ "Never ask a human to perform follow-up actions during normal execution."
    assert prompt =~ "This is retry attempt #2 because the ticket is still in an active state."
    assert prompt =~ "Do not end the turn while the issue remains in an active state"
    assert prompt =~ "open and follow `.codex/skills/land/SKILL.md`"
    assert prompt =~ "Do not bypass the repo-local GitHub helper path with ad-hoc CLI commands"
    assert prompt =~ "PR created / updated is only the entry signal into the PR closeout path, not the completion signal."
    assert prompt =~ "After every successful PR creation or branch update push, immediately attempt to enable auto-merge for the current PR before reading checks or mergeability."
    assert prompt =~ "## Document-phase evaluation gate (required before coding)"
    assert prompt =~ "This gate applies after preflight and before the run enters coding."
    assert prompt =~ "It covers requirement reading, implementation planning, task/subtask splitting, validation design, and boundary/dependency checks."
    assert prompt =~ "Do not start coding until the document-phase evaluation gate has completed with a final `proceed`."
    assert prompt =~ "`Small change` uses exactly 1 read-only analysis subagent."
    assert prompt =~ "`Large change` uses exactly 2 read-only analysis subagents in a lightweight red/blue review."
    assert prompt =~ "If the change does not clearly qualify as `Small change`, classify it as `Large change`."
    assert prompt =~ "The blue side argues the current route can proceed. The red side challenges scope, assumptions, risks, and missing validation."
    assert prompt =~ "Read-only analysis subagents must not write code, edit files, change requirements, update Linear, or expand scope."
    assert prompt =~ "`proceed` means the current plan/task split and validation route are sufficiently clear and bounded for coding."
    assert prompt =~ "`revise` means the route is close but incomplete; the main thread must revise the plan/task and run the same evaluation lane again."
    assert prompt =~ "`escalate` means the route is unsafe, under-specified, or crossing the current lane's boundary."
    assert prompt =~ "In the `Small change` lane, `escalate` promotes the run to the `Large change` lane immediately."
    assert prompt =~ "If a second `Small change` pass still does not end in `proceed`, promote it to `Large change`."
    assert prompt =~ "In the `Large change` lane, any remaining `escalate`, or a second pass that still does not end in `proceed`, must stop before coding and escalate."
    assert prompt =~ "Once promoted to `Large change`, the run must finish that lane before coding. It may not fall back to \"no assessment, direct coding.\""
    assert prompt =~ "`Checking` -> stop the current implementation run after the bounded PR closeout pass."
    assert prompt =~ "For a ticket already in `Checking`, run one short recheck thread only."
    assert prompt =~ "Read only three signal classes: latest PR merge status, latest head SHA required checks, and the newest human review delta."
    assert prompt =~ "If merge is complete, move to `Done`."
    assert prompt =~ "If checks reached a non-success terminal state, move to `In Progress`."
    assert prompt =~ "If automation cannot safely continue, move to `Human Review`."
    assert prompt =~ "When an attached PR already exists, do not move to `Human Review` merely because the PR exists."
    assert prompt =~ "Checking closes successfully only when the PR is still valid and the latest head SHA required checks are passing."
    assert prompt =~ "Every PR create/update push must be followed immediately by an auto-merge attempt for the current PR before reading checks, mergeability, or other closeout signals."
    assert prompt =~ "If the auto-merge attempt returns exact `clean status`, do not treat that as a permission blocker"

    assert prompt =~
             "If the attached PR already has review comments, top-level PR comments, or review threads, confirm there is no unresolved review delta before moving to `Human Review`."

    assert prompt =~ "Checks from an older head SHA do not satisfy the closeout requirement for the latest commit."
    assert prompt =~ "Do not require the PR to be merged and do not require `Merging` to finish for this ticket to succeed."

    assert prompt =~
             "If checks fail, stay on the same branch and in the same PR by default; continue fixing there instead of opening a new ticket, opening a new PR, or escalating to `Human Review` after a single failure."

    assert prompt =~ "If a new commit is pushed during `Checking`, discard prior check conclusions and evaluate only the new head SHA."
    assert prompt =~ "If checks are green and auto-merge is active, prefer the auto-merge path over any manual merge."
    assert prompt =~ "manual merge is allowed only as an explicit fallback"

    assert prompt =~
             "In this ticket, `Human Review` only serves as the manual confirmation entry after successful `Checking` closeout or as the escalation path when automation cannot safely continue after the auto-merge path and manual-merge fallback have both been evaluated."

    assert prompt =~
             "First-version escalation must cover at least repeated failures with diminishing returns, merge conflicts that cannot be resolved safely, repository protection rules that require human action, insufficient permissions, checks that remain abnormal for too long, and PRs that are closed or unreachable."

    assert prompt =~
             "Escalation comments must minimally include the failure reason, current PR identifier, current head SHA, affected checks or gate, and the recommended human action, with deduplication for repeated identical causes."

    assert prompt =~ "## Step 2: Execution phase (Todo -> In Progress -> Checking -> Human Review)"
    assert prompt =~ "Classify the planned delta as `Small change` or `Large change` before any code edits."
    assert prompt =~ "Only after a final `proceed` may the run continue from document-phase planning into coding."

    assert prompt =~
             "Do not skip `Checking` closeout and do not move to `Human Review` merely because the PR already exists."

    assert prompt =~ "If the attached PR already has review comments, top-level PR comments, or review threads"

    assert prompt =~
             "no actionable comments remain and `## Review Summary` accurately reflects that there is no unresolved review delta."

    assert prompt =~
             "Before stopping this run from normal execution, do not force the issue to `Human Review` unless `Checking` has closed successfully or an explicit escalation path requires a human handoff."

    assert prompt =~
             "When normal execution ends, do not force the issue to `Human Review` unless `Checking` has closed successfully or a documented escalation path requires a human handoff."

    refute prompt =~ "Then move to `Human Review`."

    refute prompt =~
             "When normal execution ends for any reason other than immediate continuation in another active execution step, confirm that the issue state has been updated to `Human Review` before stopping."

    refute prompt =~
             "If it is not, update it to `Human Review` first unless the issue has legitimately entered a terminal state."

    refute prompt =~
             "When stopping work, ending the run, or yielding because of a blocker, the agent must ensure the issue state is `Human Review` before exiting."

    assert prompt =~ "Continuation context:"
    assert prompt =~ "retry attempt #2"
  end

  test "prompt builder adds continuation guidance for retries" do
    workflow_prompt = "{% if attempt %}Retry #" <> "{{ attempt }}" <> "{% endif %}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-201",
      title: "Continue autonomous ticket",
      description: "Retry flow",
      state: "In Progress",
      url: "https://example.org/issues/MT-201",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt == "Retry #2"
  end

  test "prompt builder continuation prompt marks snapshot diff as partial observation" do
    previous_issue = %Issue{
      id: "issue-248",
      identifier: "MT-248",
      title: "Same title",
      description: "Same description",
      state: "In Progress",
      updated_at: DateTime.from_naive!(~N[2026-05-18 09:00:00], "Etc/UTC")
    }

    current_issue = %Issue{
      previous_issue
      | updated_at: DateTime.from_naive!(~N[2026-05-18 10:00:00], "Etc/UTC")
    }

    prompt = PromptBuilder.build_continuation_prompt(previous_issue, current_issue, 2, 3)

    assert prompt =~ "Issue refresh since last turn:"
    assert prompt =~ "Observed issue snapshot fields were unchanged."
    assert prompt =~ "Only compares the current %SymphonyElixir.Linear.Issue{} snapshot fields."
    assert prompt =~ "Does not cover comments, threads, or description/body revision history."
    assert prompt =~ "updated_at changed"
    assert prompt =~ "not treated as a semantic field change"
    assert prompt =~ "This does not rule out comment/thread/body changes outside the observed snapshot fields."
  end

  test "prompt builder continuation prompt summarizes long description changes without leaking full text" do
    previous_description = String.duplicate("old-body-", 40)
    current_description = String.duplicate("new-body-", 40)

    previous_issue = %Issue{
      id: "issue-249",
      identifier: "MT-249",
      title: "Long body diff",
      description: previous_description,
      state: "In Progress"
    }

    current_issue = %Issue{previous_issue | description: current_description}

    prompt = PromptBuilder.build_continuation_prompt(previous_issue, current_issue, 2, 3)

    assert prompt =~ "Observed issue snapshot fields changed:"
    assert prompt =~ "- description"
    assert prompt =~ "text summary"
    refute prompt =~ previous_description
    refute prompt =~ current_description
  end

  test "prompt builder continuation prompt surfaces unavailable snapshot comparison explicitly" do
    previous_issue = %Issue{
      id: "issue-250",
      identifier: "MT-250",
      blocked_by: [%{id: "b-1", state: "Todo"}],
      state: "In Progress"
    }

    current_issue = %Issue{
      id: "issue-250",
      identifier: "MT-250",
      blocked_by: [%{state: "Todo"}],
      state: "In Progress"
    }

    prompt = PromptBuilder.build_continuation_prompt(previous_issue, current_issue, 2, 3)

    assert prompt =~ "Issue refresh is unavailable for this turn."
    assert prompt =~ "This is not a normal changed/unchanged conclusion."
    assert prompt =~ "blocked_by was not safely compared"
  end

  test "agent runner continuation prompt compresses unchanged issue refresh while preserving scope limits" do
    previous_issue = %Issue{
      id: "issue-251",
      identifier: "MT-251",
      title: "Same title",
      description: "Same description",
      state: "In Progress"
    }

    current_issue = %Issue{previous_issue | updated_at: DateTime.from_naive!(~N[2026-05-18 11:00:00], "Etc/UTC")}

    prompt = PromptBuilder.build_continuation_prompt(previous_issue, current_issue, 2, 3)

    refute prompt =~ "Observed field changes:"
    refute prompt =~ "Result: issue_snapshot_unchanged"
    assert prompt =~ "Observed issue snapshot fields were unchanged."
    assert prompt =~ "Does not cover comments, threads, or description/body revision history."
  end

  test "agent runner keeps workspace after successful codex run" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-retain-workspace-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(workspace_root)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/usr/bin/env bash
      set -euo pipefail

      while IFS= read -r line; do
        if printf '%s\\n' "$line" | grep -q '"method":"initialize"'; then
          printf '%s\\n' '{"id":1,"result":{}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"thread/start"'; then
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-1"}}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"turn/start"'; then
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1"}}}'
          printf '%s\\n' '{"method":"turn/completed"}'
        elif printf '%s\\n' "$line" | grep -q '"method":"thread/resume"'; then
          printf '%s\\n' '{"id":5,"result":{"thread":{"id":"thread-1","status":{"type":"idle"},"turns":[{"id":"turn-1","status":"completed","items":[],"startedAt":1,"completedAt":2}]}}}'
          exit 0
        fi
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        identifier: "S-99",
        title: "Smoke test",
        description: "Run and keep workspace",
        state: "In Progress",
        url: "https://example.org/issues/S-99",
        labels: ["backend"]
      }

      before = MapSet.new(File.ls!(workspace_root))
      assert :ok = AgentRunner.run(issue)
      entries_after = MapSet.new(File.ls!(workspace_root))

      created =
        MapSet.difference(entries_after, before) |> Enum.filter(&(&1 == "S-99"))

      created = MapSet.new(created)

      assert MapSet.size(created) == 1
      workspace_name = created |> Enum.to_list() |> List.first()
      assert workspace_name == "S-99"

      workspace = Path.join(workspace_root, workspace_name)
      assert File.exists?(workspace)
      assert File.exists?(Path.join(workspace, "README.md"))
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner forwards timestamped codex updates to recipient" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-updates-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(
        codex_binary,
        """
        #!/usr/bin/env bash
        set -euo pipefail
        while IFS= read -r line; do
          if printf '%s\\n' "$line" | grep -q '"method":"initialize"'; then
            printf '%s\\n' '{"id":1,"result":{}}'
          elif printf '%s\\n' "$line" | grep -q '"method":"thread/start"'; then
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-live"}}}'
          elif printf '%s\\n' "$line" | grep -q '"method":"turn/start"'; then
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-live"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
          elif printf '%s\\n' "$line" | grep -q '"method":"thread/resume"'; then
            printf '%s\\n' '{"id":5,"result":{"thread":{"id":"thread-live","status":{"type":"idle"},"turns":[{"id":"turn-live","status":"completed","items":[],"startedAt":1,"completedAt":2}]}}}'
            exit 0
          fi
        done
        """
      )

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-live-updates",
        identifier: "MT-99",
        title: "Smoke test",
        description: "Capture codex updates",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      test_pid = self()

      assert :ok =
               AgentRunner.run(
                 issue,
                 test_pid,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )

      assert_receive {:codex_worker_update, "issue-live-updates",
                      %{
                        event: :session_started,
                        timestamp: %DateTime{},
                        session_id: session_id
                      }},
                     500

      assert session_id == "thread-live-turn-live"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner surfaces ssh startup failures instead of silently hopping hosts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-single-host-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *worker-a*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\n' 'worker-a prepare failed' >&2
          exit 75
          ;;
        *worker-b*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '/remote/home/.symphony-remote-workspaces/MT-SSH-FAILOVER'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "~/.symphony-remote-workspaces",
        worker_ssh_hosts: ["worker-a", "worker-b"]
      )

      issue = %Issue{
        id: "issue-ssh-failover",
        identifier: "MT-SSH-FAILOVER",
        title: "Do not fail over within a single worker run",
        description: "Surface the startup failure to the orchestrator",
        state: "In Progress"
      }

      assert_raise RuntimeError, ~r/workspace_prepare_failed/, fn ->
        AgentRunner.run(issue, nil, worker_host: "worker-a")
      end

      trace = File.read!(trace_file)
      assert trace =~ "worker-a bash -lc"
      refute trace =~ "worker-b bash -lc"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner continues with a follow-up turn while the issue remains active" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-continuation-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/usr/bin/env bash
      set -euo pipefail
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      run_id="$(date +%s%N)-$$"
      printf 'RUN:%s\\n' "$run_id" >> "$trace_file"
      turn_count=0

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        if printf '%s\\n' "$line" | grep -q '"method":"initialize"'; then
          printf '%s\\n' '{"id":1,"result":{}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"thread/start"'; then
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-cont"}}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"turn/start"'; then
          turn_count=$((turn_count + 1))
          if [ "$turn_count" -eq 2 ]; then
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-2"}}}'
          else
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-1"}}}'
          fi
          printf '%s\\n' '{"method":"turn/completed"}'
        elif printf '%s\\n' "$line" | grep -q '"method":"thread/resume"'; then
          if [ "$turn_count" -ge 2 ]; then
            printf '%s\\n' '{"id":5,"result":{"thread":{"id":"thread-cont","status":{"type":"idle"},"turns":[{"id":"turn-cont-1","status":"completed","items":[],"startedAt":1,"completedAt":2},{"id":"turn-cont-2","status":"completed","items":[],"startedAt":3,"completedAt":4}]}}}'
            exit 0
          else
            printf '%s\\n' '{"id":5,"result":{"thread":{"id":"thread-cont","status":{"type":"idle"},"turns":[{"id":"turn-cont-1","status":"completed","items":[],"startedAt":1,"completedAt":2}]}}}'
          fi
        fi
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      parent = self()

      state_fetcher = fn [_issue_id] ->
        attempt = Process.get(:agent_turn_fetch_count, 0) + 1
        Process.put(:agent_turn_fetch_count, attempt)
        send(parent, {:issue_state_fetch, attempt})

        {state, title} =
          if attempt == 1 do
            {"In Progress", "Continue until done (updated)"}
          else
            {"Done", "Continue until done (updated)"}
          end

        {:ok,
         [
           %Issue{
             id: "issue-continue",
             identifier: "MT-247",
             title: title,
             description: "Still active after first turn",
             state: state,
             url: "https://example.org/issues/MT-247",
             labels: []
           }
         ]}
      end

      issue = %Issue{
        id: "issue-continue",
        identifier: "MT-247",
        title: "Continue until done",
        description: "Still active after first turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-247",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:issue_state_fetch, 1}
      assert_receive {:issue_state_fetch, 2}

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert length(Enum.filter(lines, &String.starts_with?(&1, "RUN:"))) == 1
      assert length(Enum.filter(lines, &String.contains?(&1, "\"method\":\"thread/start\""))) == 1

      turn_texts =
        lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
      refute Enum.at(turn_texts, 1) =~ "You are an agent for this repository."
      assert Enum.at(turn_texts, 1) =~ "Continuation guidance:"
      assert Enum.at(turn_texts, 1) =~ "continuation turn #2 of 3"
      assert Enum.at(turn_texts, 1) =~ "Issue refresh since last turn:"
      assert Enum.at(turn_texts, 1) =~ "Observed issue snapshot fields changed:"
      assert Enum.at(turn_texts, 1) =~ "Only compares the current %SymphonyElixir.Linear.Issue{} snapshot fields."
      assert Enum.at(turn_texts, 1) =~ "Does not cover comments, threads, or description/body revision history."
      assert Enum.at(turn_texts, 1) =~ ~s|- title: "Continue until done" -> "Continue until done (updated)"|
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner reports continuation_required run result when active issue remains after a normal turn" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-run-result-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/usr/bin/env bash
      set -euo pipefail
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      turn_count=0

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        if printf '%s\\n' "$line" | grep -q '"method":"initialize"'; then
          printf '%s\\n' '{"id":1,"result":{}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"thread/start"'; then
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-result"}}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"turn/start"'; then
          turn_count=$((turn_count + 1))
          if [ "$turn_count" -eq 2 ]; then
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-result-2"}}}'
          else
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-result-1"}}}'
          fi
          printf '%s\\n' '{"method":"turn/completed"}'
        elif printf '%s\\n' "$line" | grep -q '"method":"thread/resume"'; then
          if [ "$turn_count" -ge 2 ]; then
            printf '%s\\n' '{"id":5,"result":{"thread":{"id":"thread-result","status":{"type":"idle"},"turns":[{"id":"turn-result-1","status":"completed","items":[],"startedAt":1,"completedAt":2},{"id":"turn-result-2","status":"completed","items":[],"startedAt":3,"completedAt":4}]}}}'
          else
            printf '%s\\n' '{"id":5,"result":{"thread":{"id":"thread-result","status":{"type":"idle"},"turns":[{"id":"turn-result-1","status":"completed","items":[],"startedAt":1,"completedAt":2}]}}}'
          fi
        fi
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      parent = self()

      state_fetcher = fn [_issue_id] ->
        attempt = Process.get(:agent_result_fetch_count, 0) + 1
        Process.put(:agent_result_fetch_count, attempt)

        state =
          if attempt == 1 do
            "In Progress"
          else
            "Done"
          end

        {:ok,
         [
           %Issue{
             id: "issue-run-result",
             identifier: "MT-564",
             title: "Report run result",
             description: "Still active after first turn",
             state: state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-run-result",
        identifier: "MT-564",
        title: "Report run result",
        description: "Still active after first turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-564",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, parent, issue_state_fetcher: state_fetcher)

      assert_receive(
        {:agent_run_result, "issue-run-result",
         %{
           status: :continuation_required,
           reason: :issue_still_active,
           turn_count: 1
         }},
        500
      )
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner fails current turn when workspace becomes invalid before continuation decision" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-stale-continuation-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        if printf '%s\\n' "$line" | grep -q '"method":"initialize"'; then
          printf '%s\\n' '{"id":1,"result":{}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"thread/start"'; then
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-stale-turn"}}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"turn/start"'; then
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-stale-1"}}}'
          printf '%s\\n' '{"method":"turn/completed"}'
        elif printf '%s\\n' "$line" | grep -q '"method":"thread/resume"'; then
          printf '%s\\n' '{"id":5,"result":{"thread":{"id":"thread-stale-turn","status":{"type":"idle"},"turns":[{"id":"turn-stale-1","status":"completed","items":[],"startedAt":1,"completedAt":2}]}}}'
        fi
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      parent = self()
      issue_id = "issue-stale-continuation"
      issue_identifier = "MT-STALE-CONT"

      state_fetcher = fn [_issue_id] ->
        workspace = Path.join(workspace_root, issue_identifier)

        File.write!(
          Path.join(workspace, @resource_binding_file),
          Jason.encode!(%{
            "issue_id" => issue_id,
            "issue_identifier" => issue_identifier,
            "run_instance_id" => "run-stale-continuation",
            "worker_host" => nil,
            "workspace_path" => workspace,
            "state" => "closing",
            "closing_reason" => "terminal_cleanup_pending",
            "inserted_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          })
        )

        {:ok,
         [
           %Issue{
             id: issue_id,
             identifier: issue_identifier,
             title: "Stale continuation guard",
             description: "Second turn should be fenced",
             state: "In Progress"
           }
         ]}
      end

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        title: "Stale continuation guard",
        description: "Second turn should be fenced",
        state: "In Progress",
        url: "https://example.org/issues/#{issue_identifier}",
        labels: []
      }

      assert :ok =
               AgentRunner.run(issue, parent,
                 issue_state_fetcher: state_fetcher,
                 run_instance_id: "run-stale-continuation"
               )

      assert_receive(
        {:agent_run_result, ^issue_id,
         %{
           status: :failed,
           reason: :workspace_lifecycle_invalid,
           turn_count: 1,
           run_instance_id: "run-stale-continuation"
         }},
        500
      )

      refute_receive(
        {:agent_run_result, ^issue_id, %{status: :continuation_required, reason: :issue_still_active, turn_count: 1}},
        200
      )

      turn_start_count =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.count(&(&1["method"] == "turn/start"))

      assert turn_start_count == 1
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner reports lifecycle failure when workspace is already owned by another active run" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-owned-by-other-run-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      parent = self()
      issue_id = "issue-owned-by-other-run"
      issue_identifier = "MT-OWNED-OTHER"

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      workspace = Path.join(workspace_root, issue_identifier)
      File.mkdir_p!(workspace)

      File.write!(
        Path.join(workspace, @resource_binding_file),
        Jason.encode!(%{
          "issue_id" => issue_id,
          "issue_identifier" => issue_identifier,
          "run_instance_id" => "run-existing-owner",
          "worker_host" => nil,
          "workspace_path" => workspace,
          "state" => "active",
          "closing_reason" => nil,
          "inserted_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        })
      )

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        title: "Owned by another run",
        description: "Acquisition should fail with lifecycle semantics",
        state: "In Progress",
        url: "https://example.org/issues/#{issue_identifier}",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, parent, run_instance_id: "run-new-owner")

      assert_receive {:agent_run_result, ^issue_id,
                      %{
                        status: :failed,
                        reason: :workspace_lifecycle_invalid,
                        turn_count: 1,
                        run_instance_id: "run-new-owner"
                      }},
                     500
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops continuation when refreshed active issue gains a non-terminal blocker" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-blocked-continuation-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/usr/bin/env bash
      set -euo pipefail
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        if printf '%s\\n' "$line" | grep -q '"method":"initialize"'; then
          printf '%s\\n' '{"id":1,"result":{}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"thread/start"'; then
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-blocked"}}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"turn/start"'; then
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-blocked-1"}}}'
          printf '%s\\n' '{"method":"turn/completed"}'
        elif printf '%s\\n' "$line" | grep -q '"method":"thread/resume"'; then
          printf '%s\\n' '{"id":5,"result":{"thread":{"id":"thread-blocked","status":{"type":"idle"},"turns":[{"id":"turn-blocked-1","status":"completed","items":[],"startedAt":1,"completedAt":2}]}}}'
        fi
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
      )

      issue = %Issue{
        id: "issue-blocked-continuation",
        identifier: "MT-572",
        title: "Do not continue when blocked",
        description: "Continuation should honor blocker gate",
        state: "In Progress",
        url: "https://example.org/issues/MT-572",
        labels: []
      }

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: issue.id,
             identifier: issue.identifier,
             title: issue.title,
             description: issue.description,
             state: "In Progress",
             blocked_by: [%{state: "Todo"}]
           }
         ]}
      end

      assert :ok = AgentRunner.run(issue, self(), issue_state_fetcher: state_fetcher)

      assert_receive {:agent_run_result, "issue-blocked-continuation", run_result}, 500
      assert run_result.status == :completed
      assert run_result.reason == :issue_inactive
      assert run_result.turn_count == 1

      trace = File.read!(trace_file)
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 1
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops after entering checking and reports checking closeout result" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-checking-closeout-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/usr/bin/env bash
      set -euo pipefail
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        if printf '%s\\n' "$line" | grep -q '"method":"initialize"'; then
          printf '%s\\n' '{"id":1,"result":{}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"thread/start"'; then
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-checking"}}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"turn/start"'; then
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-checking-1"}}}'
          printf '%s\\n' '{"method":"turn/completed"}'
        elif printf '%s\\n' "$line" | grep -q '"method":"thread/resume"'; then
          printf '%s\\n' '{"id":5,"result":{"thread":{"id":"thread-checking","status":{"type":"idle"},"turns":[{"id":"turn-checking-1","status":"completed","items":[],"startedAt":1,"completedAt":2}]}}}'
        fi
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3,
        tracker_active_states: ["Todo", "In Progress", "Checking"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
      )

      issue = %Issue{
        id: "issue-checking-closeout",
        identifier: "MT-572C",
        title: "Stop at checking",
        description: "Run should stop after checking entry",
        state: "In Progress",
        url: "https://example.org/issues/MT-572C",
        labels: []
      }

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: issue.id,
             identifier: issue.identifier,
             title: issue.title,
             description: issue.description,
             state: "Checking"
           }
         ]}
      end

      assert :ok = AgentRunner.run(issue, self(), issue_state_fetcher: state_fetcher)

      assert_receive {:agent_run_result, "issue-checking-closeout", run_result}, 500
      assert run_result.status == :completed
      assert run_result.reason == :issue_entered_checking
      assert run_result.turn_count == 1

      trace = File.read!(trace_file)
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 1
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "checking recheck run stops after one turn even if refreshed issue returns to in progress" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-checking-recheck-single-turn-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/usr/bin/env bash
      set -euo pipefail
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        if printf '%s\\n' "$line" | grep -q '"method":"initialize"'; then
          printf '%s\\n' '{"id":1,"result":{}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"thread/start"'; then
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-checking-recheck"}}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"turn/start"'; then
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-checking-recheck-1"}}}'
          printf '%s\\n' '{"method":"turn/completed"}'
        elif printf '%s\\n' "$line" | grep -q '"method":"thread/resume"'; then
          printf '%s\\n' '{"id":5,"result":{"thread":{"id":"thread-checking-recheck","status":{"type":"idle"},"turns":[{"id":"turn-checking-recheck-1","status":"completed","items":[],"startedAt":1,"completedAt":2}]}}}'
        fi
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3,
        tracker_active_states: ["Todo", "In Progress", "Checking"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
      )

      issue = %Issue{
        id: "issue-checking-recheck-single-turn",
        identifier: "MT-572R",
        title: "Stop checking recheck after one turn",
        description: "Checking recheck must never continue into a second turn",
        state: "Checking",
        url: "https://example.org/issues/MT-572R",
        labels: []
      }

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: issue.id,
             identifier: issue.identifier,
             title: issue.title,
             description: issue.description,
             state: "In Progress"
           }
         ]}
      end

      assert :ok =
               AgentRunner.run(issue, self(),
                 issue_state_fetcher: state_fetcher,
                 run_mode: :checking_recheck
               )

      assert_receive {:agent_run_result, "issue-checking-recheck-single-turn", run_result}, 500
      assert run_result.status == :completed
      assert run_result.reason == :issue_inactive
      assert run_result.turn_count == 1

      trace = File.read!(trace_file)
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 1
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops continuation when refreshed active issue is no longer routed to this worker" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-rerouted-continuation-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/usr/bin/env bash
      set -euo pipefail
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        if printf '%s\\n' "$line" | grep -q '"method":"initialize"'; then
          printf '%s\\n' '{"id":1,"result":{}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"thread/start"'; then
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-rerouted"}}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"turn/start"'; then
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-rerouted-1"}}}'
          printf '%s\\n' '{"method":"turn/completed"}'
        elif printf '%s\\n' "$line" | grep -q '"method":"thread/resume"'; then
          printf '%s\\n' '{"id":5,"result":{"thread":{"id":"thread-rerouted","status":{"type":"idle"},"turns":[{"id":"turn-rerouted-1","status":"completed","items":[],"startedAt":1,"completedAt":2}]}}}'
        fi
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
      )

      issue = %Issue{
        id: "issue-rerouted-continuation",
        identifier: "MT-573",
        title: "Do not continue when rerouted",
        description: "Continuation should honor worker routing gate",
        state: "In Progress",
        url: "https://example.org/issues/MT-573",
        labels: [],
        assigned_to_worker: true
      }

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: issue.id,
             identifier: issue.identifier,
             title: issue.title,
             description: issue.description,
             state: "In Progress",
             assigned_to_worker: false
           }
         ]}
      end

      assert :ok = AgentRunner.run(issue, self(), issue_state_fetcher: state_fetcher)

      assert_receive {:agent_run_result, "issue-rerouted-continuation", run_result}, 500
      assert run_result.status == :completed
      assert run_result.reason == :issue_inactive
      assert run_result.turn_count == 1

      trace = File.read!(trace_file)
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 1
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops continuing once agent.max_turns is reached" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-max-turns-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/usr/bin/env bash
      set -euo pipefail
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      printf 'RUN\\n' >> "$trace_file"
      turn_count=0

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        if printf '%s\\n' "$line" | grep -q '"method":"initialize"'; then
          printf '%s\\n' '{"id":1,"result":{}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"thread/start"'; then
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-max"}}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"turn/start"'; then
          turn_count=$((turn_count + 1))
          if [ "$turn_count" -eq 2 ]; then
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-2"}}}'
          else
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-1"}}}'
          fi
          printf '%s\\n' '{"method":"turn/completed"}'
        elif printf '%s\\n' "$line" | grep -q '"method":"thread/resume"'; then
          if [ "$turn_count" -ge 2 ]; then
            printf '%s\\n' '{"id":5,"result":{"thread":{"id":"thread-max","status":{"type":"idle"},"turns":[{"id":"turn-max-1","status":"completed","items":[],"startedAt":1,"completedAt":2},{"id":"turn-max-2","status":"completed","items":[],"startedAt":3,"completedAt":4}]}}}'
          else
            printf '%s\\n' '{"id":5,"result":{"thread":{"id":"thread-max","status":{"type":"idle"},"turns":[{"id":"turn-max-1","status":"completed","items":[],"startedAt":1,"completedAt":2}]}}}'
          fi
        fi
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: "issue-max-turns",
             identifier: "MT-248",
             title: "Stop at max turns",
             description: "Still active",
             state: "In Progress"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-max-turns",
        identifier: "MT-248",
        title: "Stop at max turns",
        description: "Still active",
        state: "In Progress",
        url: "https://example.org/issues/MT-248",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)

      trace = File.read!(trace_file)
      assert length(String.split(trace, "RUN", trim: true)) == 1
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 2
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner reports continuation_required run result when agent.max_turns is reached" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-max-turns-run-result-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/usr/bin/env bash
      set -euo pipefail
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      turn_count=0

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        if printf '%s\\n' "$line" | grep -q '"method":"initialize"'; then
          printf '%s\\n' '{"id":1,"result":{}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"thread/start"'; then
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-max-result"}}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"turn/start"'; then
          turn_count=$((turn_count + 1))
          if [ "$turn_count" -eq 2 ]; then
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-result-2"}}}'
          else
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-result-1"}}}'
          fi
          printf '%s\\n' '{"method":"turn/completed"}'
        elif printf '%s\\n' "$line" | grep -q '"method":"thread/resume"'; then
          if [ "$turn_count" -ge 2 ]; then
            printf '%s\\n' '{"id":5,"result":{"thread":{"id":"thread-max-result","status":{"type":"idle"},"turns":[{"id":"turn-max-result-1","status":"completed","items":[],"startedAt":1,"completedAt":2},{"id":"turn-max-result-2","status":"completed","items":[],"startedAt":3,"completedAt":4}]}}}'
          else
            printf '%s\\n' '{"id":5,"result":{"thread":{"id":"thread-max-result","status":{"type":"idle"},"turns":[{"id":"turn-max-result-1","status":"completed","items":[],"startedAt":1,"completedAt":2}]}}}'
          fi
        fi
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: "issue-max-turns-result",
             identifier: "MT-565",
             title: "Max turns result",
             description: "Still active",
             state: "In Progress"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-max-turns-result",
        identifier: "MT-565",
        title: "Max turns result",
        description: "Still active",
        state: "In Progress",
        url: "https://example.org/issues/MT-565",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, self(), issue_state_fetcher: state_fetcher)

      assert_receive(
        {:agent_run_result, "issue-max-turns-result",
         %{
           status: :continuation_required,
           reason: :max_turns_reached,
           turn_count: 2
         }},
        500
      )
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner reports failed run result when a turn fails prematurely" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-turn-failed-run-result-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-turn-failed"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-failed-result-1"}}}'
            printf '%s\\n' '{"method":"turn/failed","params":{"message":"turn aborted"}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      issue = %Issue{
        id: "issue-turn-failed-result",
        identifier: "MT-567",
        title: "Turn failed run result",
        description: "The turn fails before run success or crash.",
        state: "In Progress",
        url: "https://example.org/issues/MT-567",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, self())

      assert_receive {:agent_run_result, "issue-turn-failed-result", %{status: :failed, reason: :premature_turn_end, turn_count: 1}},
                     500
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner reports failed run result when a turn is cancelled prematurely" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-turn-cancelled-run-result-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-turn-cancelled"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cancelled-result-1"}}}'
            printf '%s\\n' '{"method":"turn/cancelled","params":{"message":"turn cancelled"}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      issue = %Issue{
        id: "issue-turn-cancelled-result",
        identifier: "MT-571",
        title: "Turn cancelled run result",
        description: "The turn is cancelled before run success or crash.",
        state: "In Progress",
        url: "https://example.org/issues/MT-571",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, self())

      assert_receive {:agent_run_result, "issue-turn-cancelled-result", %{status: :failed, reason: :premature_turn_end, turn_count: 1}},
                     500
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner reports failed run result when turn is cancelled after a provisional completed event" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-completed-then-cancelled-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/usr/bin/env bash
      set -euo pipefail
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        if printf '%s\\n' "$line" | grep -q '"method":"initialize"'; then
          printf '%s\\n' '{"id":1,"result":{}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"thread/start"'; then
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-completed-then-cancelled"}}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"turn/start"'; then
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-completed-then-cancelled"}}}'
          printf '%s\\n' '{"method":"turn/completed"}'
          printf '%s\\n' '{"method":"turn/cancelled","params":{"message":"late cancellation"}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"thread/resume"'; then
          printf '%s\\n' '{"id":5,"result":{"thread":{"id":"thread-completed-then-cancelled","status":{"type":"idle"},"turns":[{"id":"turn-completed-then-cancelled","status":"interrupted","error":{"message":"late cancellation"},"items":[],"startedAt":1,"completedAt":2}]}}}'
        fi
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      issue = %Issue{
        id: "issue-completed-then-cancelled",
        identifier: "MT-CTC",
        title: "Turn cancelled after completed",
        description: "Late cancellation must block continuation",
        state: "In Progress",
        url: "https://example.org/issues/MT-CTC",
        labels: []
      }

      state_fetcher = fn [_issue_id] ->
        send(self(), :issue_state_fetch_called_after_provisional_completion)

        {:ok,
         [
           %Issue{
             id: "issue-completed-then-cancelled",
             identifier: "MT-CTC",
             title: "Turn cancelled after completed",
             description: "Late cancellation must block continuation",
             state: "In Progress"
           }
         ]}
      end

      assert :ok = AgentRunner.run(issue, self(), issue_state_fetcher: state_fetcher)

      assert_receive {:agent_run_result, "issue-completed-then-cancelled", %{status: :failed, reason: :premature_turn_end, turn_count: 1}},
                     500

      refute_receive :issue_state_fetch_called_after_provisional_completion, 200
      refute_receive {:agent_run_result, "issue-completed-then-cancelled", %{status: :continuation_required}}, 200
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner does not continue after completed when resume barrier reports interrupted turn" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-completed-then-interrupted-barrier-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/usr/bin/env bash
      set -euo pipefail
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        if printf '%s\\n' "$line" | grep -q '"method":"initialize"'; then
          printf '%s\\n' '{"id":1,"result":{}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"thread/start"'; then
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-runner-interrupted-barrier"}}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"turn/start"'; then
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-runner-interrupted-barrier"}}}'
          printf '%s\\n' '{"method":"turn/completed"}'
          printf '%s\\n' '{"method":"turn/cancelled","params":{"message":"late cancellation after barrier wait"}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"thread/resume"'; then
          printf '%s\\n' '{"id":5,"result":{"thread":{"id":"thread-runner-interrupted-barrier","status":{"type":"idle"},"turns":[{"id":"turn-runner-interrupted-barrier","status":"interrupted","error":{"message":"late cancellation after barrier wait"},"items":[],"startedAt":1,"completedAt":2}]}}}'
        fi
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      issue = %Issue{
        id: "issue-runner-interrupted-barrier",
        identifier: "MT-RIB",
        title: "Resume barrier interrupted turn",
        description: "Late interrupted barrier result must not continuation",
        state: "In Progress",
        url: "https://example.org/issues/MT-RIB",
        labels: []
      }

      state_fetcher = fn [_issue_id] ->
        send(self(), :issue_state_fetch_called_after_interrupted_barrier)

        {:ok,
         [
           %Issue{
             id: issue.id,
             identifier: issue.identifier,
             title: issue.title,
             description: issue.description,
             state: "In Progress"
           }
         ]}
      end

      assert :ok = AgentRunner.run(issue, self(), issue_state_fetcher: state_fetcher)

      assert_receive {:agent_run_result, "issue-runner-interrupted-barrier", %{status: :failed, reason: :premature_turn_end, turn_count: 1}},
                     500

      refute_receive :issue_state_fetch_called_after_interrupted_barrier, 200
      refute_receive {:agent_run_result, "issue-runner-interrupted-barrier", %{status: :continuation_required}}, 200
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner reports failed run result when a turn times out" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-turn-timeout-run-result-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-turn-timeout"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-timeout-result-1"}}}'
            sleep 1
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        codex_turn_timeout_ms: 50,
        max_turns: 2
      )

      issue = %Issue{
        id: "issue-turn-timeout-result",
        identifier: "MT-573",
        title: "Turn timeout run result",
        description: "The turn times out before run success or crash.",
        state: "In Progress",
        url: "https://example.org/issues/MT-573",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, self())

      assert_receive {:agent_run_result, "issue-turn-timeout-result", %{status: :failed, reason: :turn_timeout, turn_count: 1}},
                     500
    after
      File.rm_rf(test_root)
    end
  end

  test "normal worker exit with failed run result does not allow ordinary redispatch" do
    issue_id = "issue-run-failed-closeout"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :FailedRunCloseoutOrchestrator)
    {:ok, pid} = start_inert_orchestrator(orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-568",
      issue: %Issue{id: issue_id, identifier: "MT-568", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:agent_run_result, issue_id, %{status: :failed, reason: :premature_turn_end, turn_count: 1}})
    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    issue = %Issue{
      id: issue_id,
      identifier: "MT-568",
      title: "Premature turn end hold",
      description: "Should not auto redispatch while still active",
      state: "In Progress",
      labels: []
    }

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.claimed, issue_id)
    assert MapSet.member?(state.completed, issue_id)

    assert %{attempt: 1, due_at_ms: due_at_ms, delay_type: :premature_turn_end_hold} =
             state.retry_attempts[issue_id]

    assert is_integer(due_at_ms)
    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "normal worker exit with timeout run result schedules ordinary retry instead of premature hold" do
    issue_id = "issue-run-timeout-closeout"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :TimeoutRunCloseoutOrchestrator)
    {:ok, pid} = start_inert_orchestrator(orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-574",
      issue: %Issue{id: issue_id, identifier: "MT-574", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:agent_run_result, issue_id, %{status: :failed, reason: :turn_timeout, turn_count: 1}})
    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 1, error: "turn_timeout"} = state.retry_attempts[issue_id]
    refute state.retry_attempts[issue_id].delay_type == :premature_turn_end_hold
    refute MapSet.member?(state.completed, issue_id)
    assert MapSet.member?(state.claimed, issue_id)
    refute Map.has_key?(state.blocked_claims, issue_id)
  end

  test "premature turn end hold converges to a blocked local claim while the issue remains active" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-run-failed-hold"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :FailedRunHoldOrchestrator)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "In Review"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{
        id: issue_id,
        identifier: "MT-569",
        title: "Premature turn end hold",
        description: "Should continue holding while still active",
        state: "In Progress",
        labels: []
      }
    ])

    {:ok, pid} = start_inert_orchestrator(orchestrator_name)

    on_exit(fn ->
      restore_app_env(:memory_tracker_issues, previous_memory_issues)

      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-569",
      issue: %Issue{id: issue_id, identifier: "MT-569", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:max_concurrent_agents, 0)
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:agent_run_result, issue_id, %{status: :failed, reason: :premature_turn_end, turn_count: 1}})
    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)

    assert %{attempt: 1, retry_token: retry_token, delay_type: :premature_turn_end_hold} =
             :sys.get_state(pid).retry_attempts[issue_id]

    send(pid, {:retry_issue, issue_id, retry_token})
    Process.sleep(50)

    assert %{attempt: 2, retry_token: retry_token_2, delay_type: :premature_turn_end_hold} =
             :sys.get_state(pid).retry_attempts[issue_id]

    refute retry_token_2 == retry_token

    send(pid, {:retry_issue, issue_id, retry_token_2})
    Process.sleep(50)

    assert %{attempt: 3, retry_token: retry_token_3, delay_type: :premature_turn_end_hold} =
             :sys.get_state(pid).retry_attempts[issue_id]

    refute retry_token_3 == retry_token_2

    send(pid, {:retry_issue, issue_id, retry_token_3})
    Process.sleep(50)
    state = :sys.get_state(pid)

    issue = %Issue{
      id: issue_id,
      identifier: "MT-569",
      title: "Premature turn end hold",
      description: "Should converge to a blocked local claim while still active",
      state: "In Progress",
      labels: []
    }

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.claimed, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)

    assert %{attempt: 3, reason: :premature_turn_end, issue: %Issue{id: ^issue_id}} =
             state.blocked_claims[issue_id]

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "todo continuation retry releases claim when m3 auto dispatch is disabled" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-todo-continuation-disabled"
    orchestrator_name = Module.concat(__MODULE__, :TodoContinuationDisabledOrchestrator)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      m3_enabled: false,
      tracker_active_states: ["Todo", "In Progress", "In Review"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{
        id: issue_id,
        identifier: "MT-570",
        title: "Todo continuation blocked by m3 opt-in",
        description: "Should release claim instead of implicit redispatch",
        state: "Todo",
        labels: []
      }
    ])

    {:ok, pid} = start_inert_orchestrator(orchestrator_name)

    on_exit(fn ->
      restore_app_env(:memory_tracker_issues, previous_memory_issues)

      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 1,
          identifier: "MT-570",
          retry_token: make_ref(),
          due_at_ms: System.monotonic_time(:millisecond)
        }
      })
    end)

    retry_token = :sys.get_state(pid).retry_attempts[issue_id].retry_token
    send(pid, {:retry_issue, issue_id, retry_token})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute MapSet.member?(state.claimed, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)
    refute Map.has_key?(state.running, issue_id)
  end

  test "blocked premature turn end claim releases once the issue stops being a candidate" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-run-failed-release"
    orchestrator_name = Module.concat(__MODULE__, :FailedRunReleaseOrchestrator)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "In Review"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    {:ok, pid} = start_inert_orchestrator(orchestrator_name)

    on_exit(fn ->
      restore_app_env(:memory_tracker_issues, previous_memory_issues)

      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:blocked_claims, %{
        issue_id => %{
          attempt: 3,
          identifier: "MT-569",
          reason: :premature_turn_end,
          issue: %Issue{
            id: issue_id,
            identifier: "MT-569",
            state: "In Progress",
            title: "Premature turn end hold",
            description: "Should be released once it is no longer a candidate",
            labels: []
          }
        }
      })
    end)

    send(pid, :tick)
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute MapSet.member?(state.claimed, issue_id)
    refute Map.has_key?(state.blocked_claims, issue_id)
  end

  test "blocked todo claim releases when cross-project dependency is the only blocker" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-cross-project-blocked-claim"
    orchestrator_name = Module.concat(__MODULE__, :CrossProjectBlockedClaimOrchestrator)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      m3_enabled: true,
      tracker_project_slug: "alpha",
      tracker_active_states: ["Todo", "In Progress", "In Review"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{
        id: issue_id,
        identifier: "MT-571",
        title: "Cross-project blocked claim",
        description: "Should release claim once structural error is detected",
        state: "Todo",
        blocked_by: [
          %{id: "other-project-done", identifier: "OT-200", state: "Done", project_slug: "beta"}
        ],
        labels: []
      }
    ])

    {:ok, pid} = start_inert_orchestrator(orchestrator_name)

    on_exit(fn ->
      restore_app_env(:memory_tracker_issues, previous_memory_issues)

      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:blocked_claims, %{
        issue_id => %{
          attempt: 3,
          identifier: "MT-571",
          reason: :premature_turn_end,
          issue: %Issue{
            id: issue_id,
            identifier: "MT-571",
            state: "Todo",
            title: "Cross-project blocked claim",
            description: "Should release claim once structural error is detected",
            blocked_by: [
              %{id: "other-project-done", identifier: "OT-200", state: "Done", project_slug: "beta"}
            ],
            labels: []
          }
        }
      })
    end)

    send(pid, :tick)
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute MapSet.member?(state.claimed, issue_id)
    refute Map.has_key?(state.blocked_claims, issue_id)
  end

  test "todo revalidation helper rejects multi-node cyclic dependency when given full candidate set" do
    write_workflow_file!(Workflow.workflow_file_path(),
      m3_enabled: true,
      tracker_project_slug: "alpha",
      tracker_active_states: ["Todo", "In Progress", "In Review"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    )

    issue_a = %Issue{
      id: "issue-cycle-a",
      identifier: "MT-572",
      title: "Cycle A",
      description: "Should not auto dispatch when the Todo graph contains a cycle",
      state: "Todo",
      blocked_by: [%{id: "issue-cycle-b", identifier: "MT-573", state: "Done", project_slug: "alpha"}],
      created_at: ~U[2026-01-01 00:00:00Z],
      labels: []
    }

    issue_b = %Issue{
      id: "issue-cycle-b",
      identifier: "MT-573",
      title: "Cycle B",
      description: "Completes the Todo cycle",
      state: "Todo",
      blocked_by: [%{id: "issue-cycle-a", identifier: "MT-572", state: "Done", project_slug: "alpha"}],
      created_at: ~U[2026-01-02 00:00:00Z],
      labels: []
    }

    assert {:skip, %Issue{id: "issue-cycle-a"}} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(
               issue_a,
               fn ["issue-cycle-a"] -> {:ok, [issue_a]} end,
               fn -> {:ok, [issue_a, issue_b]} end
             )
  end

  test "blocked premature turn end claim releases once the issue reaches a terminal state" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-run-failed-terminal-release"
    issue_identifier = "MT-572"

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-premature-terminal-release-#{System.unique_integer([:positive])}"
      )

    orchestrator_name = Module.concat(__MODULE__, :FailedRunTerminalReleaseOrchestrator)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: test_root,
      tracker_active_states: ["Todo", "In Progress", "In Review"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{
        id: issue_id,
        identifier: issue_identifier,
        title: "Premature turn end terminal release",
        description: "Should release once terminal",
        state: "Closed",
        labels: []
      }
    ])

    workspace = Path.join(test_root, issue_identifier)
    File.mkdir_p!(workspace)

    File.write!(
      Path.join(workspace, @resource_binding_file),
      Jason.encode!(%{
        "issue_id" => issue_id,
        "issue_identifier" => issue_identifier,
        "run_instance_id" => "run-blocked-terminal-release",
        "worker_host" => nil,
        "workspace_path" => workspace,
        "state" => "active",
        "closing_reason" => nil,
        "inserted_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })
    )

    {:ok, pid} = start_inert_orchestrator(orchestrator_name)

    on_exit(fn ->
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)

      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:blocked_claims, %{
        issue_id => %{
          attempt: 3,
          identifier: issue_identifier,
          worker_host: nil,
          run_instance_id: "run-blocked-terminal-release",
          reason: :premature_turn_end,
          issue: %Issue{
            id: issue_id,
            identifier: issue_identifier,
            state: "In Progress",
            title: "Premature turn end hold",
            description: "Should be released once terminal",
            labels: []
          }
        }
      })
    end)

    send(pid, :tick)
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute MapSet.member?(state.claimed, issue_id)
    refute Map.has_key?(state.blocked_claims, issue_id)
    assert File.exists?(workspace)
    assert {:ok, binding} = Workspace.read_resource_binding(workspace)
    assert binding["state"] == "closing"
    assert binding["closing_reason"] == "terminal_blocked_claim_cleanup"
  end

  test "app server starts with workspace cwd and expected startup command" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-77")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/usr/bin/env bash
      set -euo pipefail
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-args.trace}"
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"
      printf 'CWD:%s\\n' \"$PWD\" >> \"$trace_file\"

      while IFS= read -r line; do
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"
        if printf '%s\\n' "$line" | grep -q '"method":"initialize"'; then
          printf '%s\\n' '{"id":1,"result":{}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"thread/start"'; then
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-77"}}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"turn/start"'; then
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-77"}}}'
          printf '%s\\n' '{"method":"turn/completed"}'
        elif printf '%s\\n' "$line" | grep -q '"method":"thread/resume"'; then
          printf '%s\\n' '{"id":5,"result":{"thread":{"id":"thread-77","status":{"type":"idle"},"turns":[{"id":"turn-77","status":"completed","items":[],"startedAt":1,"completedAt":2}]}}}'
          exit 0
        fi
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-args",
        identifier: "MT-77",
        title: "Validate codex args",
        description: "Check startup args and cwd",
        state: "In Progress",
        url: "https://example.org/issues/MT-77",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "app-server")
      refute Enum.any?(lines, &String.contains?(&1, "--yolo"))
      assert cwd_line = Enum.find(lines, fn line -> String.starts_with?(line, "CWD:") end)
      assert String.ends_with?(cwd_line, Path.basename(workspace))

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = "on-request"

                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace
                 end)
               else
                 false
               end
             end)

      expected_turn_sandbox_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [canonical_workspace],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => false,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = "on-request"

                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_sandbox_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup command supports codex args override from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-custom-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-custom-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/usr/bin/env bash
      set -euo pipefail
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-custom-args.trace}"
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"

      while IFS= read -r line; do
        if printf '%s\\n' "$line" | grep -q '"method":"initialize"'; then
          printf '%s\\n' '{"id":1,"result":{}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"thread/start"'; then
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-88"}}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"turn/start"'; then
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-88"}}}'
          printf '%s\\n' '{"method":"turn/completed"}'
        elif printf '%s\\n' "$line" | grep -q '"method":"thread/resume"'; then
          printf '%s\\n' '{"id":5,"result":{"thread":{"id":"thread-88","status":{"type":"idle"},"turns":[{"id":"turn-88","status":"completed","items":[],"startedAt":1,"completedAt":2}]}}}'
          exit 0
        fi
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} --config 'model=\"gpt-5.5\"' app-server"
      )

      issue = %Issue{
        id: "issue-custom-args",
        identifier: "MT-88",
        title: "Validate custom codex args",
        description: "Check startup args override",
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "--config model=\"gpt-5.5\" app-server")
      refute String.contains?(argv_line, "--ask-for-approval never")
      refute String.contains?(argv_line, "--sandbox danger-full-access")
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup payload uses configurable approval and sandbox settings from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-policy-overrides-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-99")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-policy-overrides.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/usr/bin/env bash
      set -euo pipefail
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-policy-overrides.trace}"

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        if printf '%s\\n' "$line" | grep -q '"method":"initialize"'; then
          printf '%s\\n' '{"id":1,"result":{}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"thread/start"'; then
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-99"}}}'
        elif printf '%s\\n' "$line" | grep -q '"method":"turn/start"'; then
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-99"}}}'
          printf '%s\\n' '{"method":"turn/completed"}'
        elif printf '%s\\n' "$line" | grep -q '"method":"thread/resume"'; then
          printf '%s\\n' '{"id":5,"result":{"thread":{"id":"thread-99","status":{"type":"idle"},"turns":[{"id":"turn-99","status":"completed","items":[],"startedAt":1,"completedAt":2}]}}}'
          exit 0
        fi
      done
      """)

      File.chmod!(codex_binary, 0o755)

      workspace_cache = Path.join(Path.expand(workspace), ".cache")
      File.mkdir_p!(workspace_cache)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "on-request",
        codex_thread_sandbox: "workspace-write",
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: [Path.expand(workspace), workspace_cache]
        }
      )

      issue = %Issue{
        id: "issue-policy-overrides",
        identifier: "MT-99",
        title: "Validate codex policy overrides",
        description: "Check startup policy payload overrides",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write"
                 end)
               else
                 false
               end
             end)

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [Path.expand(workspace), workspace_cache]
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  defp assert_eventually(fun, attempts, sleep_ms \\ 25)

  defp assert_eventually(fun, attempts, sleep_ms) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(sleep_ms)
      assert_eventually(fun, attempts - 1, sleep_ms)
    end
  end

  defp assert_eventually(_fun, 0, _sleep_ms), do: flunk("condition not met in time")
end
