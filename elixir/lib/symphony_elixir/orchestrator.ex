defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{AgentRunner, Config, RunStateStore, RunTrace, StatusDashboard, Tracker, Workspace}
  alias SymphonyElixir.Linear.Issue

  @continuation_retry_delay_ms 1_000
  @premature_turn_end_recheck_delay_ms 1_000
  @premature_turn_end_hold_limit 3
  @failure_retry_base_ms 10_000
  @checking_recheck_delay_type :checking_recheck
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    @type t :: %__MODULE__{
            poll_interval_ms: non_neg_integer() | nil,
            max_concurrent_agents: non_neg_integer() | nil,
            next_poll_due_at_ms: integer() | nil,
            poll_check_in_progress: boolean() | nil,
            tick_timer_ref: reference() | nil,
            tick_token: reference() | nil,
            running: map(),
            completed: MapSet.t(String.t()),
            claimed: MapSet.t(String.t()),
            blocked_claims: map(),
            retry_attempts: map(),
            codex_totals: map() | nil,
            codex_rate_limits: map() | nil
          }

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      blocked_claims: %{},
      retry_attempts: %{},
      codex_totals: nil,
      codex_rate_limits: nil
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()

    state = %State{
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      codex_totals: @empty_codex_totals,
      codex_rate_limits: nil
    }

    run_terminal_workspace_cleanup()
    state = schedule_tick(state, 0)

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_dispatch(state)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        cancel_stop_grace_timer(running_entry)
        session_id = running_entry_session_id(running_entry)

        state =
          handle_worker_exit_after_pop(state, issue_id, running_entry, session_id, reason)

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        if current_generation?(running_entry, runtime_info) do
          updated_running_entry =
            running_entry
            |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
            |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])

          notify_dashboard()
          {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
        else
          {:noreply, state}
        end
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        if current_generation?(running_entry, update) do
          {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

          state =
            state
            |> apply_codex_token_delta(token_delta)
            |> apply_codex_rate_limits(update)

          notify_dashboard()
          {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
        else
          {:noreply, state}
        end
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:agent_run_result, issue_id, run_result}, %{running: running} = state)
      when is_binary(issue_id) and is_map(run_result) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        if current_generation?(running_entry, run_result) do
          updated_running_entry = Map.put(running_entry, :run_result, run_result)
          {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
        else
          {:noreply, state}
        end
    end
  end

  def handle_info({:agent_run_result, _issue_id, _run_result}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info({:stop_grace_timeout, issue_id, run_instance_id}, %{running: running} = state)
      when is_binary(issue_id) and is_binary(run_instance_id) do
    case Map.get(running, issue_id) do
      %{run_instance_id: ^run_instance_id} = running_entry ->
        state =
          if pending_stall_stop_without_terminal_evidence?(running_entry) do
            block_unconfirmed_stall_stop(state, issue_id, running_entry)
          else
            state
          end

        notify_dashboard()
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp current_generation?(running_entry, message) when is_map(running_entry) and is_map(message) do
    expected = Map.get(running_entry, :run_instance_id)
    actual = Map.get(message, :run_instance_id) || Map.get(message, "run_instance_id")

    cond do
      is_binary(expected) and is_binary(actual) -> expected == actual
      is_nil(expected) and is_nil(actual) -> true
      true -> false
    end
  end

  defp current_generation?(_running_entry, _message), do: false

  defp maybe_dispatch(%State{} = state) do
    state =
      state
      |> reconcile_running_issues()
      |> reconcile_blocked_claims()

    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_candidate_issues(),
         true <- available_slots(state) > 0 do
      choose_issues(issues, state)
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Linear project slug missing in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
        state

      false ->
        state
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set(), [issue])
  end

  @doc false
  @spec prepare_issue_for_dispatch_for_test(
          Issue.t(),
          ([String.t()] -> {:ok, [Issue.t()]} | {:error, term()}),
          (String.t(), String.t() -> :ok | {:error, term()})
        ) :: {:ok, Issue.t()} | {:error, term()} | {:skip, term()}
  def prepare_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher, issue_state_updater)
      when is_function(issue_fetcher, 1) and is_function(issue_state_updater, 2) do
    prepare_issue_for_dispatch_for_test(
      issue,
      issue_fetcher,
      issue_state_updater,
      fn -> {:ok, [issue]} end
    )
  end

  @spec prepare_issue_for_dispatch_for_test(
          Issue.t(),
          ([String.t()] -> {:ok, [Issue.t()]} | {:error, term()}),
          (String.t(), String.t() -> :ok | {:error, term()}),
          (-> {:ok, [Issue.t()]} | {:error, term()})
        ) :: {:ok, Issue.t()} | {:error, term()} | {:skip, term()}
  def prepare_issue_for_dispatch_for_test(
        %Issue{} = issue,
        issue_fetcher,
        issue_state_updater,
        candidate_fetcher
      )
      when is_function(issue_fetcher, 1) and is_function(issue_state_updater, 2) and
             is_function(candidate_fetcher, 0) do
    _ = issue_state_updater

    prepare_issue_for_dispatch(
      issue,
      issue_fetcher,
      candidate_fetcher,
      terminal_state_set()
    )
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch_for_test(issue, issue_fetcher, fn -> {:ok, [issue]} end)
  end

  @spec revalidate_issue_for_dispatch_for_test(
          Issue.t(),
          ([String.t()] -> term()),
          (-> {:ok, [Issue.t()]} | {:error, term()})
        ) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher, candidate_fetcher)
      when is_function(issue_fetcher, 1) and is_function(candidate_fetcher, 0) do
    revalidate_issue_for_dispatch_for_test(
      issue,
      issue_fetcher,
      candidate_fetcher,
      terminal_state_set()
    )
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  @doc false
  @spec schedule_issue_retry_for_test(State.t(), String.t(), integer(), map()) :: State.t()
  def schedule_issue_retry_for_test(%State{} = state, issue_id, attempt, metadata)
      when is_binary(issue_id) and is_integer(attempt) and is_map(metadata) do
    schedule_issue_retry(state, issue_id, attempt, metadata)
  end

  @doc false
  @spec retry_delay_for_test(integer(), map()) :: non_neg_integer()
  def retry_delay_for_test(attempt, metadata) when is_integer(attempt) and is_map(metadata) do
    retry_delay(attempt, metadata)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        worker_host = Map.get(running_entry, :worker_host)

        if cleanup_workspace do
          cleanup_issue_workspace(identifier, worker_host)
        end

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            blocked_claims: Map.delete(state.blocked_claims, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().codex.stall_timeout_ms

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    cond do
      stall_interrupt_pending?(running_entry) ->
        state

      is_integer(elapsed_ms) and elapsed_ms > timeout_ms ->
        identifier = Map.get(running_entry, :identifier, issue_id)
        session_id = running_entry_session_id(running_entry)

        Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; requesting cooperative interrupt")

        next_attempt = next_retry_attempt_from_running(running_entry)

        request_stalled_issue_interrupt(state, issue_id, running_entry, %{
          next_attempt: next_attempt,
          identifier: identifier,
          error: "stalled for #{elapsed_ms}ms without codex activity",
          worker_host: Map.get(running_entry, :worker_host),
          workspace_path: Map.get(running_entry, :workspace_path),
          run_trace: Map.get(running_entry, :run_trace),
          run_instance_id: run_instance_id_from_metadata(running_entry)
        })

      true ->
        state
    end
  end

  defp stall_interrupt_pending?(%{release_state: %{status: :stall_interrupt_requested}}), do: true
  defp stall_interrupt_pending?(_running_entry), do: false

  defp request_stalled_issue_interrupt(%State{} = state, issue_id, running_entry, retry_metadata) do
    run_instance_id = run_instance_id_from_metadata(running_entry)
    timer_ref = Process.send_after(self(), {:stop_grace_timeout, issue_id, run_instance_id}, stop_grace_timeout_ms())

    case Map.get(running_entry, :pid) do
      pid when is_pid(pid) ->
        send(pid, {:interrupt_codex_turn, run_instance_id, :stall_detected})

      _ ->
        :ok
    end

    updated_running_entry =
      Map.put(running_entry, :release_state, %{
        status: :stall_interrupt_requested,
        reason: :stall_detected,
        requested_at: DateTime.utc_now(),
        retry_metadata: retry_metadata
      })
      |> Map.put(:stop_grace_timer_ref, timer_ref)
      |> Map.put_new(:turn_terminal_seen?, false)

    %{state | running: Map.put(state.running, issue_id, updated_running_entry)}
  end

  defp stop_grace_timeout_ms do
    max(Config.settings!().codex.stall_timeout_ms, 1)
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()
    dispatchable_issue_ids = dispatchable_issue_ids(issues, state, active_states, terminal_states)

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if should_dispatch_issue?(
           issue,
           state_acc,
           active_states,
           terminal_states,
           issues,
           dispatchable_issue_ids
         ) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {issue_created_at_sort_key(nil), ""}
    end)
  end

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{} = state,
         active_states,
         terminal_states,
         candidate_issues
       ) do
    should_dispatch_issue?(
      issue,
      state,
      active_states,
      terminal_states,
      candidate_issues,
      dispatchable_issue_ids(candidate_issues, state, active_states, terminal_states)
    )
  end

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed} = state,
         active_states,
         terminal_states,
         _candidate_issues,
         dispatchable_issue_ids
       ) do
    MapSet.member?(dispatchable_issue_ids, issue.id) and
      candidate_issue?(issue, active_states, terminal_states) and
      checking_issue_dispatch_allowed?(issue, state) and
      !issue_blocked_by_non_terminal?(issue, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running) and
      worker_slots_available?(state)
  end

  defp should_dispatch_issue?(
         _issue,
         _state,
         _active_states,
         _terminal_states,
         _candidate_issues,
         _dispatchable_issue_ids
       ),
       do: false

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp checking_issue_dispatch_allowed?(%Issue{state: state_name} = issue, %State{} = state)
       when is_binary(state_name) do
    if normalize_issue_state(state_name) == "checking" do
      checking_issue_retry_due?(issue, state)
    else
      true
    end
  end

  defp checking_issue_dispatch_allowed?(_issue, _state), do: false

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  defp issue_blocked_by_non_terminal?(%Issue{blocked_by: blockers}, terminal_states)
       when is_list(blockers) do
    Enum.any?(blockers, fn
      %{state: blocker_state} when is_binary(blocker_state) ->
        !terminal_issue_state?(blocker_state, terminal_states)

      _ ->
        true
    end)
  end

  defp issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp dispatch_candidate_issue?(
         %Issue{} = issue,
         active_states,
         terminal_states,
         candidate_issues,
         state,
         dispatched_todos
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      todo_issue_dispatch_allowed?(issue, candidate_issues, state, dispatched_todos)
  end

  defp dispatch_candidate_issue?(%Issue{} = issue, active_states, terminal_states, candidate_issues, state) do
    candidate_issue?(issue, active_states, terminal_states) and
      todo_issue_dispatch_allowed?(issue, candidate_issues, state)
  end

  defp todo_issue_dispatch_allowed?(
         %Issue{state: state_name} = issue,
         candidate_issues,
         %State{},
         dispatched_todos
       )
       when is_binary(state_name) and is_list(candidate_issues) do
    case normalize_issue_state(state_name) do
      "todo" -> todo_issue_selected_for_dispatch?(issue, dispatched_todos)
      _other -> true
    end
  end

  defp todo_issue_dispatch_allowed?(_issue, _candidate_issues, _state, _dispatched_todos), do: false

  defp todo_issue_dispatch_allowed?(%Issue{state: state_name} = issue, candidate_issues, %State{} = state)
       when is_binary(state_name) and is_list(candidate_issues) do
    case normalize_issue_state(state_name) do
      "todo" -> todo_issue_selected_for_dispatch?(issue, candidate_issues, state)
      _other -> true
    end
  end

  defp todo_issue_dispatch_allowed?(_issue, _candidate_issues, _state), do: false

  defp dispatchable_issue_ids(candidate_issues, %State{} = state, active_states, terminal_states)
       when is_list(candidate_issues) do
    dispatchable_issues_for_state(candidate_issues, state, active_states, terminal_states)
    |> Enum.flat_map(fn
      %Issue{id: id} when is_binary(id) -> [id]
      _ -> []
    end)
    |> MapSet.new()
  end

  defp dispatchable_issues_for_state(candidate_issues, %State{} = state, active_states, terminal_states)
       when is_list(candidate_issues) do
    dispatched_todos = dispatched_todo_lookup(candidate_issues, state)

    candidate_issues
    |> sort_issues_for_dispatch()
    |> Enum.filter(fn
      %Issue{} = issue ->
        common_checks? =
          dispatch_candidate_issue?(
            issue,
            active_states,
            terminal_states,
            candidate_issues,
            state,
            dispatched_todos
          ) and
            !issue_blocked_by_non_terminal?(issue, terminal_states) and
            !MapSet.member?(state.claimed, issue.id) and
            !Map.has_key?(state.running, issue.id) and
            available_slots(state) > 0 and
            state_slots_available?(issue, state.running) and
            worker_slots_available?(state)

        common_checks? and
          (non_todo_issue?(issue) or MapSet.member?(dispatched_todos, issue_dispatch_key(issue)))

      _ ->
        false
    end)
  end

  defp dispatched_todo_lookup(candidate_issues, %State{} = state) when is_list(candidate_issues) do
    SymphonyElixir.M3Precheck.run(candidate_issues, %{
      current_project_slug: Config.settings!().tracker.project_slug,
      current_project_id: nil,
      m3_enabled: Config.m3_enabled?(),
      max_concurrent_agents: Config.settings!().agent.max_concurrent_agents,
      current_work: current_work(state.running),
      terminal_states: Config.settings!().tracker.terminal_states
    }).dispatched_todos
    |> Enum.map(&issue_dispatch_key/1)
    |> MapSet.new()
  end

  defp todo_issue_selected_for_dispatch?(%Issue{} = issue, %MapSet{} = dispatched_todos),
    do: MapSet.member?(dispatched_todos, issue_dispatch_key(issue))

  defp todo_issue_selected_for_dispatch?(%Issue{} = issue, candidate_issues, %State{} = state)
       when is_list(candidate_issues) do
    MapSet.member?(dispatched_todo_lookup(candidate_issues, state), issue_dispatch_key(issue))
  end

  defp todo_issue_selected_for_dispatch?(_issue, _candidate_issues, _state), do: false

  defp non_todo_issue?(%Issue{state: state_name}) when is_binary(state_name) do
    normalize_issue_state(state_name) != "todo"
  end

  defp non_todo_issue?(_issue), do: false

  defp issue_dispatch_key(%Issue{id: id}) when is_binary(id), do: {:id, id}
  defp issue_dispatch_key(%Issue{id: _id, identifier: identifier}) when is_binary(identifier), do: {:identifier, identifier}
  defp issue_dispatch_key(_issue), do: :unknown

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil, retry_metadata \\ %{}) do
    transition_context = %{
      issue_fetcher: &Tracker.fetch_issue_states_by_ids/1,
      issue_state_updater: &Tracker.update_issue_state/2,
      candidate_fetcher: &Tracker.fetch_candidate_issues/0,
      terminal_states: terminal_state_set()
    }

    case prepare_issue_for_dispatch(
           issue,
           transition_context.issue_fetcher,
           transition_context.candidate_fetcher,
           transition_context.terminal_states
         ) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host, transition_context, retry_metadata)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp prepare_issue_for_dispatch(
         %Issue{} = issue,
         issue_fetcher,
         candidate_fetcher,
         terminal_states
       )
       when is_function(issue_fetcher, 1) and is_function(candidate_fetcher, 0) do
    prepare_issue_candidate(issue, issue_fetcher, candidate_fetcher, terminal_states)
  end

  defp prepare_issue_candidate(%Issue{} = issue, issue_fetcher, candidate_fetcher, terminal_states) do
    case revalidate_issue_for_dispatch(issue, issue_fetcher, candidate_fetcher, terminal_states) do
      {:ok, %Issue{} = refreshed_issue} -> {:ok, refreshed_issue}
      {:skip, reason} -> {:skip, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec m3_precheck() :: {:ok, map()} | {:error, term()}
  def m3_precheck, do: m3_precheck(__MODULE__)

  @spec m3_precheck(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def m3_precheck(orchestrator_name) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        {:ok,
         SymphonyElixir.M3Precheck.run(issues, %{
           current_project_slug: Config.settings!().tracker.project_slug,
           current_project_id: nil,
           m3_enabled: Config.m3_enabled?(),
           max_concurrent_agents: Config.settings!().agent.max_concurrent_agents,
           current_work: current_work(snapshot_running_map(orchestrator_name)),
           terminal_states: Config.settings!().tracker.terminal_states
         })}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp snapshot_running_map(orchestrator_name) do
    case Process.whereis(orchestrator_name) do
      pid when is_pid(pid) ->
        case :sys.get_state(pid) do
          %State{running: running} when is_map(running) -> running
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp current_work(running) when is_map(running) do
    entries =
      running
      |> Enum.map(fn
        {_issue_id, %{issue: %Issue{} = issue} = running_entry} ->
          entry = %{
            issue_id: issue.id,
            issue_identifier: issue.identifier,
            state: issue.state
          }

          entry
          |> maybe_put_current_work_value(:worker_host, Map.get(running_entry, :worker_host))
          |> maybe_put_current_work_value(:workspace_path, Map.get(running_entry, :workspace_path))

        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)

    %{count: length(entries), entries: entries}
  end

  defp current_work(_running), do: %{count: 0, entries: []}

  defp maybe_put_current_work_value(entry, _key, nil), do: entry
  defp maybe_put_current_work_value(entry, key, value), do: Map.put(entry, key, value)

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host, transition_context, retry_metadata) do
    recipient = self()

    case select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        state

      worker_host ->
        retry_workspace_path = retry_workspace_path(state, issue.id)
        retry_trace = retry_trace(state, issue.id, retry_metadata)
        run_trace = resolve_dispatch_run_trace(retry_trace, issue, worker_host, retry_workspace_path)
        run_instance_id = new_run_instance_id()

        RunTrace.record(run_trace, :orchestrator, %{
          event: :dispatch_started,
          summary: "orchestrator:dispatch_started",
          run_instance_id: run_instance_id,
          payload: %{attempt: attempt, worker_host: worker_host, workspace_path: retry_workspace_path}
        })

        spawn_issue_on_worker_host(
          state,
          issue,
          attempt,
          recipient,
          worker_host,
          retry_workspace_path,
          transition_context
          |> Map.put(:run_trace, run_trace)
          |> Map.put(:run_instance_id, run_instance_id),
          run_trace,
          run_instance_id
        )
    end
  end

  defp new_run_instance_id do
    "run-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp retry_workspace_path(%State{} = state, issue_id) do
    case Map.get(state.retry_attempts, issue_id) do
      %{workspace_path: workspace_path} -> workspace_path
      _ -> nil
    end
  end

  defp retry_trace(%State{} = state, issue_id, retry_metadata) do
    Map.get(retry_metadata, :run_trace) ||
      state.retry_attempts |> Map.get(issue_id, %{}) |> Map.get(:run_trace)
  end

  defp resolve_dispatch_run_trace(%RunTrace{} = trace, _issue, _worker_host, _retry_workspace_path), do: trace

  defp resolve_dispatch_run_trace(_retry_trace, issue, worker_host, retry_workspace_path) do
    case RunTrace.start(issue, worker_host: worker_host, workspace_path: retry_workspace_path) do
      {:ok, trace} ->
        trace

      {:error, reason} ->
        Logger.warning("Run trace initialization failed for #{issue_context(issue)}: #{inspect(reason)}")
        nil
    end
  end

  defp spawn_issue_on_worker_host(
         %State{} = state,
         issue,
         attempt,
         recipient,
         worker_host,
         retry_workspace_path,
         transition_context,
         run_trace,
         run_instance_id
       ) do
    run_mode = dispatch_run_mode(state, issue)

    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           AgentRunner.run(issue, recipient,
             attempt: attempt,
             worker_host: worker_host,
             run_trace: run_trace,
             run_mode: run_mode,
             run_instance_id: run_instance_id
           )
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        transition_result = maybe_transition_spawned_todo_to_in_progress(issue, transition_context)

        handle_spawned_issue_transition_result(
          transition_result,
          state,
          %{
            issue: issue,
            attempt: attempt,
            pid: pid,
            ref: ref,
            run_mode: run_mode,
            worker_host: worker_host,
            retry_workspace_path: retry_workspace_path,
            transition_context: transition_context,
            run_trace: run_trace,
            run_instance_id: run_instance_id
          }
        )

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: "failed to spawn agent: #{inspect(reason)}",
          worker_host: worker_host,
          run_trace: run_trace,
          run_instance_id: run_instance_id
        })
    end
  end

  defp handle_spawned_issue_transition_result(
         {:ok, running_issue},
         %State{} = state,
         %{
           attempt: attempt,
           pid: pid,
           ref: ref,
           run_mode: run_mode,
           worker_host: worker_host,
           retry_workspace_path: retry_workspace_path,
           run_trace: run_trace,
           run_instance_id: run_instance_id
         }
       ) do
    RunTrace.record(run_trace, :orchestrator, %{
      event: :dispatch_accepted,
      summary: "orchestrator:dispatch_accepted",
      run_instance_id: run_instance_id,
      payload: %{attempt: attempt, worker_host: worker_host, workspace_path: retry_workspace_path}
    })

    Logger.info("Dispatching issue to agent: #{issue_context(running_issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

    running =
      Map.put(state.running, running_issue.id, %{
        pid: pid,
        ref: ref,
        identifier: running_issue.identifier,
        issue: running_issue,
        run_instance_id: run_instance_id,
        worker_host: worker_host,
        workspace_path: retry_workspace_path,
        thread_id: nil,
        turn_id: nil,
        session_id: nil,
        last_codex_message: nil,
        last_codex_timestamp: nil,
        last_codex_event: nil,
        codex_app_server_pid: nil,
        codex_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0,
        codex_last_reported_input_tokens: 0,
        codex_last_reported_output_tokens: 0,
        codex_last_reported_total_tokens: 0,
        turn_count: 0,
        run_result: nil,
        run_mode: run_mode,
        run_trace: run_trace,
        retry_attempt: normalize_retry_attempt(attempt),
        started_at: DateTime.utc_now()
      })

    %{
      state
      | running: running,
        claimed: MapSet.put(state.claimed, running_issue.id),
        blocked_claims: Map.delete(state.blocked_claims, running_issue.id),
        retry_attempts: Map.delete(state.retry_attempts, running_issue.id)
    }
  end

  defp handle_spawned_issue_transition_result(
         {:error, reason},
         %State{} = state,
         %{
           issue: issue,
           attempt: attempt,
           pid: pid,
           ref: ref,
           run_mode: _run_mode,
           worker_host: worker_host,
           retry_workspace_path: retry_workspace_path,
           transition_context: transition_context,
           run_trace: run_trace,
           run_instance_id: run_instance_id
         }
       ) do
    Process.demonitor(ref, [:flush])
    terminate_task(pid)
    rollback_result = rollback_spawned_todo_transition(issue, transition_context)

    RunTrace.record(run_trace, :orchestrator, %{
      event: :dispatch_transition_failed,
      summary: "orchestrator:dispatch_transition_failed",
      run_instance_id: run_instance_id,
      payload: %{
        attempt: attempt,
        worker_host: worker_host,
        reason: inspect(reason),
        rollback: inspect(rollback_result)
      }
    })

    Logger.warning("Rolling back spawned dispatch for #{issue_context(issue)}: #{inspect(reason)} rollback=#{inspect(rollback_result)}")

    next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

    schedule_issue_retry(state, issue.id, next_attempt, %{
      identifier: issue.identifier,
      error: "failed to transition spawned issue: #{inspect(reason)}; rollback=#{inspect(rollback_result)}",
      worker_host: worker_host,
      workspace_path: retry_workspace_path,
      run_trace: run_trace,
      run_instance_id: run_instance_id
    })
  end

  defp maybe_transition_spawned_todo_to_in_progress(
         %Issue{state: state_name} = issue,
         %{
           issue_fetcher: issue_fetcher,
           issue_state_updater: issue_state_updater,
           candidate_fetcher: candidate_fetcher,
           terminal_states: terminal_states,
           run_trace: run_trace,
           run_instance_id: run_instance_id
         }
       )
       when is_binary(state_name) and is_function(issue_fetcher, 1) and
              is_function(issue_state_updater, 2) and is_function(candidate_fetcher, 0) do
    if normalize_issue_state(state_name) == "todo" do
      with :ok <- issue_state_updater.(issue.id, "In Progress"),
           {:ok, [%Issue{} = refreshed_issue | _]} <- issue_fetcher.([issue.id]),
           true <- normalize_issue_state(refreshed_issue.state) == "in progress",
           {:ok, candidate_issues} <- candidate_fetcher.(),
           true <- retry_candidate_issue?(refreshed_issue, terminal_states, candidate_issues) do
        RunTrace.record(run_trace, :orchestrator, %{
          event: :spawned_todo_transition_succeeded,
          summary: "orchestrator:spawned_todo_transition_succeeded",
          run_instance_id: run_instance_id,
          payload: %{issue_id: issue.id}
        })

        {:ok, refreshed_issue}
      else
        false ->
          record_spawned_todo_transition_failure(run_trace, issue.id, run_instance_id, :issue_not_in_progress_after_update)
          {:error, :issue_not_in_progress_after_update}

        {:ok, []} ->
          record_spawned_todo_transition_failure(run_trace, issue.id, run_instance_id, :issue_missing_after_update)
          {:error, :issue_missing_after_update}

        {:error, reason} ->
          record_spawned_todo_transition_failure(run_trace, issue.id, run_instance_id, reason)
          {:error, reason}

        other ->
          record_spawned_todo_transition_failure(run_trace, issue.id, run_instance_id, other)
          {:error, other}
      end
    else
      {:ok, issue}
    end
  end

  defp maybe_transition_spawned_todo_to_in_progress(issue, _transition_context), do: {:ok, issue}

  defp rollback_spawned_todo_transition(
         %Issue{state: state_name, id: issue_id},
         %{issue_state_updater: issue_state_updater}
       )
       when is_binary(state_name) and is_binary(issue_id) and is_function(issue_state_updater, 2) do
    if normalize_issue_state(state_name) == "todo" do
      case issue_state_updater.(issue_id, "Todo") do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    else
      :noop
    end
  end

  defp rollback_spawned_todo_transition(_issue, _transition_context), do: :noop

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, candidate_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) and is_function(candidate_fetcher, 0) do
    do_revalidate_issue_for_dispatch(issue_id, issue_fetcher, candidate_fetcher, terminal_states)
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _candidate_fetcher, _terminal_states),
    do: {:ok, issue}

  defp revalidate_issue_for_dispatch_for_test(
         %Issue{id: issue_id},
         issue_fetcher,
         candidate_fetcher,
         terminal_states
       )
       when is_binary(issue_id) and is_function(issue_fetcher, 1) and is_function(candidate_fetcher, 0) do
    do_revalidate_issue_for_dispatch(issue_id, issue_fetcher, candidate_fetcher, terminal_states)
  end

  defp revalidate_issue_for_dispatch_for_test(issue, _issue_fetcher, _candidate_fetcher, _terminal_states),
    do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id, opts \\ []) do
    state = %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        blocked_claims: Map.delete(state.blocked_claims, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }

    if Keyword.get(opts, :release_claim?, false) do
      release_issue_claim(state, issue_id)
    else
      state
    end
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)
    run_trace = pick_retry_run_trace(previous_retry, metadata)
    delay_type = pick_retry_delay_type(previous_retry, metadata)
    run_instance_id = pick_retry_run_instance_id(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    RunTrace.record(run_trace, :orchestrator, %{
      event: :retry_scheduled,
      summary: "orchestrator:retry_scheduled",
      run_instance_id: run_instance_id,
      payload: %{attempt: next_attempt, error: error, delay_type: delay_type}
    })

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            error: error,
            delay_type: delay_type,
            worker_host: worker_host,
            workspace_path: workspace_path,
            run_trace: run_trace,
            run_instance_id: run_instance_id
          })
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          delay_type: Map.get(retry_entry, :delay_type),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          run_trace: Map.get(retry_entry, :run_trace),
          run_instance_id: Map.get(retry_entry, :run_instance_id)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    if terminal_issue_state?(issue.state, terminal_states) do
      handle_terminal_retry_issue(state, issue, issue_id, metadata)
    else
      handle_non_terminal_retry_issue(state, issue, issue_id, attempt, metadata, terminal_states)
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_identifier, _worker_host), do: :ok

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            cleanup_issue_workspace(identifier)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    if metadata[:delay_type] == :premature_turn_end_hold do
      if attempt >= @premature_turn_end_hold_limit do
        Logger.warning("Issue remains active after repeated premature turn end: #{issue_context(issue)}; converging to blocked local claim")

        RunTrace.record(metadata[:run_trace], :orchestrator, %{
          event: :retry_converged_to_blocked_claim,
          summary: "orchestrator:retry_converged_to_blocked_claim",
          run_instance_id: run_instance_id_from_metadata(metadata),
          payload: %{attempt: attempt, issue_id: issue.id}
        })

        {:noreply,
         block_issue_claim(state, issue.id, %{
           attempt: attempt,
           identifier: issue.identifier,
           worker_host: metadata[:worker_host],
           workspace_path: metadata[:workspace_path],
           reason: :premature_turn_end,
           issue: issue,
           run_trace: metadata[:run_trace],
           run_instance_id: run_instance_id_from_metadata(metadata)
         })}
      else
        Logger.debug("Issue remains active after premature turn end: #{issue_context(issue)}; holding claim")

        {:noreply,
         schedule_issue_retry(
           state,
           issue.id,
           attempt + 1,
           Map.merge(metadata, %{
             identifier: issue.identifier,
             delay_type: :premature_turn_end_hold
           })
         )}
      end
    else
      retry_or_reschedule_active_issue(state, issue, attempt, metadata)
    end
  end

  defp block_issue_claim(%State{} = state, issue_id, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    blocked_claim = %{
      attempt: metadata[:attempt],
      identifier: metadata[:identifier] || issue_id,
      worker_host: metadata[:worker_host],
      workspace_path: metadata[:workspace_path],
      reason: metadata[:reason] || :premature_turn_end,
      issue: metadata[:issue],
      run_trace: metadata[:run_trace],
      run_instance_id: metadata[:run_instance_id]
    }

    %{
      state
      | claimed: MapSet.put(state.claimed, issue_id),
        blocked_claims: Map.put(state.blocked_claims, issue_id, blocked_claim),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{
      state
      | claimed: MapSet.delete(state.claimed, issue_id),
        blocked_claims: Map.delete(state.blocked_claims, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    cond do
      metadata[:delay_type] == :continuation and attempt == 1 ->
        @continuation_retry_delay_ms

      metadata[:delay_type] == :premature_turn_end_hold ->
        @premature_turn_end_recheck_delay_ms

      metadata[:delay_type] == @checking_recheck_delay_type ->
        Config.settings!().polling.checking_interval_ms

      true ->
        failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp pick_retry_run_trace(previous_retry, metadata) do
    metadata[:run_trace] || Map.get(previous_retry, :run_trace)
  end

  defp pick_retry_delay_type(previous_retry, metadata) do
    metadata[:delay_type] || Map.get(previous_retry, :delay_type)
  end

  defp pick_retry_run_instance_id(previous_retry, metadata) do
    metadata[:run_instance_id] || Map.get(previous_retry, :run_instance_id)
  end

  defp run_instance_id_from_metadata(metadata) when is_map(metadata) do
    Map.get(metadata, :run_instance_id)
  end

  defp run_instance_id_from_metadata(_metadata), do: nil

  defp dispatch_run_mode(%State{} = state, %Issue{id: issue_id, state: state_name})
       when is_binary(issue_id) and is_binary(state_name) do
    cond do
      normalize_issue_state(state_name) == "checking" ->
        :checking_recheck

      match?(%{delay_type: @checking_recheck_delay_type}, Map.get(state.retry_attempts, issue_id)) ->
        :checking_recheck

      true ->
        :normal
    end
  end

  defp dispatch_run_mode(_state, _issue), do: :normal

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp reconcile_blocked_claims(%State{blocked_claims: blocked_claims} = state)
       when blocked_claims == %{} do
    state
  end

  defp reconcile_blocked_claims(%State{} = state) do
    blocked_issue_ids = Map.keys(state.blocked_claims)

    case Tracker.fetch_issue_states_by_ids(blocked_issue_ids) do
      {:ok, issues} ->
        state
        |> reconcile_blocked_claim_issue_states(issues)
        |> reconcile_missing_blocked_claim_issue_ids(blocked_issue_ids, issues)

      {:error, reason} ->
        Logger.debug("Failed to refresh blocked claim issue states: #{inspect(reason)}; keeping blocked claims")
        state
    end
  end

  defp reconcile_blocked_claim_issue_states(%State{} = state, issues) when is_list(issues) do
    terminal_states = terminal_state_set()

    Enum.reduce(issues, state, fn
      %Issue{} = issue, state_acc ->
        reconcile_blocked_claim_issue_state(state_acc, issue, terminal_states)

      _, state_acc ->
        state_acc
    end)
  end

  defp reconcile_missing_blocked_claim_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        Logger.info("Blocked claim issue no longer visible: issue_id=#{issue_id}; releasing claim")
        release_issue_claim(state_acc, issue_id)
      end
    end)
  end

  defp reconcile_blocked_claim_issue_state(%State{} = state, %Issue{} = issue, terminal_states) do
    if Map.has_key?(state.blocked_claims, issue.id) do
      reconcile_existing_blocked_claim_issue(state, issue, terminal_states)
    else
      state
    end
  end

  defp do_revalidate_issue_for_dispatch(issue_id, issue_fetcher, candidate_fetcher, terminal_states) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        revalidate_refreshed_issue(refreshed_issue, candidate_fetcher, terminal_states)

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_refreshed_issue(refreshed_issue, candidate_fetcher, terminal_states) do
    case candidate_fetcher.() do
      {:ok, candidate_issues} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states, candidate_issues) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_terminal_retry_issue(state, issue, issue_id, metadata) do
    Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

    cleanup_issue_workspace(issue.identifier, metadata[:worker_host])
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp handle_non_terminal_retry_issue(state, issue, issue_id, attempt, metadata, terminal_states) do
    case Tracker.fetch_candidate_issues() do
      {:ok, candidate_issues} ->
        if retry_candidate_issue?(issue, terminal_states, candidate_issues) do
          handle_active_retry(state, issue, attempt, metadata)
        else
          Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")
          {:noreply, release_issue_claim(state, issue_id)}
        end

      {:error, reason} ->
        Logger.warning("Failed to fetch candidate issues during retry evaluation for #{issue_context(issue)}: #{inspect(reason)}")
        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp retry_or_reschedule_active_issue(state, issue, attempt, metadata) do
    case Tracker.fetch_candidate_issues() do
      {:ok, candidate_issues} ->
        state = release_retry_claim_for_handoff(state, issue)

        if can_dispatch_retried_issue?(issue, state, metadata, candidate_issues) do
          {:noreply, dispatch_issue(state, issue, attempt, metadata[:worker_host], metadata)}
        else
          Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

          {:noreply,
           schedule_issue_retry(
             state,
             issue.id,
             attempt + 1,
             Map.merge(metadata, %{
               identifier: issue.identifier,
               error: "no available orchestrator slots"
             })
           )}
        end

      {:error, reason} ->
        Logger.warning("Failed to fetch candidate issues before retry dispatch for #{issue_context(issue)}: #{inspect(reason)}")
        {:noreply, release_issue_claim(state, issue.id)}
    end
  end

  defp release_retry_claim_for_handoff(%State{} = state, %Issue{id: issue_id}) when is_binary(issue_id) do
    if Map.has_key?(state.blocked_claims, issue_id) or Map.has_key?(state.running, issue_id) do
      state
    else
      release_issue_claim(state, issue_id)
    end
  end

  defp release_retry_claim_for_handoff(state, _issue), do: state

  defp can_dispatch_retried_issue?(issue, state, metadata, candidate_issues) do
    retry_candidate_issue?(issue, terminal_state_set(), candidate_issues) and
      retry_ownership_gate_open?(issue, state) and
      dispatch_slots_available?(issue, state) and
      worker_slots_available?(state, metadata[:worker_host])
  end

  defp retry_ownership_gate_open?(%Issue{id: issue_id}, %State{} = state) when is_binary(issue_id) do
    not MapSet.member?(state.claimed, issue_id) and
      not Map.has_key?(state.blocked_claims, issue_id) and
      not Map.has_key?(state.running, issue_id)
  end

  defp retry_ownership_gate_open?(_issue, _state), do: false

  defp reconcile_existing_blocked_claim_issue(state, issue, terminal_states) do
    if terminal_issue_state?(issue.state, terminal_states) do
      release_terminal_blocked_claim_issue(state, issue)
    else
      reconcile_active_blocked_claim_issue(state, issue, terminal_states)
    end
  end

  defp release_terminal_blocked_claim_issue(state, issue) do
    Logger.info("Blocked claim issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; releasing claim")

    cleanup_issue_workspace(issue.identifier, blocked_claim_worker_host(state, issue.id))
    release_issue_claim(state, issue.id)
  end

  defp reconcile_active_blocked_claim_issue(state, issue, terminal_states) do
    case Tracker.fetch_candidate_issues() do
      {:ok, candidate_issues} ->
        if retry_candidate_issue?(issue, terminal_states, candidate_issues) do
          put_blocked_claim_issue(state, issue.id, issue)
        else
          Logger.info("Blocked claim issue is no longer a retry candidate: #{issue_context(issue)} state=#{issue.state}; releasing claim")

          release_issue_claim(state, issue.id)
        end

      {:error, reason} ->
        Logger.warning("Failed to fetch candidate issues for blocked claim reconciliation #{issue_context(issue)}: #{inspect(reason)}")

        put_blocked_claim_issue(state, issue.id, issue)
    end
  end

  defp put_blocked_claim_issue(%State{} = state, issue_id, %Issue{} = issue) do
    update_in(state.blocked_claims[issue_id], fn
      nil -> nil
      blocked_claim -> Map.put(blocked_claim, :issue, issue)
    end)
  end

  defp blocked_claim_worker_host(%State{} = state, issue_id) do
    state.blocked_claims
    |> Map.get(issue_id, %{})
    |> Map.get(:worker_host)
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        summary =
          metadata
          |> Map.put(:issue_id, issue_id)
          |> RunStateStore.summary_for_running_entry(now: now)

        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          title: metadata.issue.title,
          state: metadata.issue.state,
          linear_state: summary.linear_state,
          current_phase: summary.current_phase,
          current_action: summary.current_action,
          health: summary.health,
          thread_id: summary.thread_id,
          turn_id: summary.turn_id,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: summary.last_event_at || metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: summary.last_event_type || metadata.last_codex_event,
          runtime_seconds: running_seconds(metadata.started_at, now),
          last_error: summary.last_error
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path)
        }
      end)

    blocked =
      state.blocked_claims
      |> Enum.map(fn {issue_id, blocked_claim} ->
        %{
          issue_id: issue_id,
          attempt: Map.get(blocked_claim, :attempt),
          due_in_ms: nil,
          identifier: Map.get(blocked_claim, :identifier),
          error: Atom.to_string(Map.get(blocked_claim, :reason, :premature_turn_end)),
          worker_host: Map.get(blocked_claim, :worker_host),
          workspace_path: Map.get(blocked_claim, :workspace_path)
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying ++ blocked,
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        thread_id: id_for_update(Map.get(running_entry, :thread_id), update, :thread_id),
        turn_id: id_for_update(Map.get(running_entry, :turn_id), update, :turn_id),
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update),
        turn_terminal_seen?: turn_terminal_seen_for_update(running_entry, event)
      }),
      token_delta
    }
  end

  defp turn_terminal_seen_for_update(running_entry, event) do
    Map.get(running_entry, :turn_terminal_seen?, false) or
      event in [:turn_completed, :turn_failed, :turn_cancelled]
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp id_for_update(existing, update, key) do
    case Map.get(update, key) || Map.get(update, Atom.to_string(key)) do
      value when is_binary(value) -> value
      _ -> existing
    end
  end

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp checking_issue_retry_due?(%Issue{id: issue_id} = issue, %State{} = state) when is_binary(issue_id) do
    case Map.get(state.retry_attempts, issue_id) do
      %{due_at_ms: due_at_ms} when is_integer(due_at_ms) ->
        due_at_ms <= System.monotonic_time(:millisecond)

      _ ->
        checking_issue_cooldown_elapsed?(issue)
    end
  end

  defp checking_issue_retry_due?(_issue, _state), do: false

  defp checking_issue_cooldown_elapsed?(%Issue{updated_at: %DateTime{} = updated_at}) do
    DateTime.diff(DateTime.utc_now(), updated_at, :millisecond) >=
      Config.settings!().polling.checking_interval_ms
  end

  defp checking_issue_cooldown_elapsed?(_issue), do: false

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp handle_worker_exit_after_pop(state, issue_id, running_entry, session_id, reason) do
    cond do
      pending_stall_stop_without_terminal_evidence?(running_entry) ->
        block_unconfirmed_stall_stop(state, issue_id, running_entry)

      reason == :normal ->
        handle_normal_worker_exit(state, issue_id, running_entry, session_id)

      true ->
        handle_abnormal_worker_exit(state, issue_id, running_entry, session_id, reason)
    end
  end

  defp handle_abnormal_worker_exit(state, issue_id, running_entry, session_id, reason) do
    run_trace = Map.get(running_entry, :run_trace)

    RunTrace.record(run_trace, :orchestrator, %{
      event: :worker_exit_abnormal,
      summary: "orchestrator:worker_exit_abnormal",
      run_instance_id: run_instance_id_from_metadata(running_entry),
      payload: %{issue_id: issue_id, session_id: session_id, reason: inspect(reason)}
    })

    Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

    next_attempt = next_retry_attempt_from_running(running_entry)

    schedule_issue_retry(state, issue_id, next_attempt, %{
      identifier: running_entry.identifier,
      error: "agent exited: #{inspect(reason)}",
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      run_trace: run_trace,
      run_instance_id: run_instance_id_from_metadata(running_entry)
    })
  end

  defp pending_stall_stop_without_terminal_evidence?(running_entry) do
    stall_interrupt_pending?(running_entry) and not Map.get(running_entry, :turn_terminal_seen?, false)
  end

  defp block_unconfirmed_stall_stop(%State{} = state, issue_id, running_entry) do
    cancel_stop_grace_timer(running_entry)

    state =
      case Map.get(state.running, issue_id) do
        nil -> state
        _ -> %{state | running: Map.delete(state.running, issue_id)}
      end

    terminate_running_process(running_entry)

    retry_metadata = get_in(running_entry, [:release_state, :retry_metadata]) || %{}

    block_issue_claim(state, issue_id, %{
      attempt: retry_metadata[:next_attempt],
      identifier: retry_metadata[:identifier] || Map.get(running_entry, :identifier, issue_id),
      worker_host: retry_metadata[:worker_host] || Map.get(running_entry, :worker_host),
      workspace_path: retry_metadata[:workspace_path] || Map.get(running_entry, :workspace_path),
      reason: :remote_stop_unconfirmed,
      issue: Map.get(running_entry, :issue),
      run_trace: retry_metadata[:run_trace] || Map.get(running_entry, :run_trace),
      run_instance_id: retry_metadata[:run_instance_id] || run_instance_id_from_metadata(running_entry)
    })
  end

  defp terminate_running_process(running_entry) do
    case Map.get(running_entry, :pid) do
      pid when is_pid(pid) -> terminate_task(pid)
      _ -> :ok
    end

    case Map.get(running_entry, :ref) do
      ref when is_reference(ref) -> Process.demonitor(ref, [:flush])
      _ -> :ok
    end
  end

  defp cancel_stop_grace_timer(running_entry) do
    case Map.get(running_entry, :stop_grace_timer_ref) do
      ref when is_reference(ref) -> Process.cancel_timer(ref)
      _ -> :ok
    end
  end

  defp handle_normal_worker_exit(state, issue_id, running_entry, session_id) do
    run_trace = Map.get(running_entry, :run_trace)

    RunTrace.record(run_trace, :orchestrator, %{
      event: :worker_exit_normal,
      summary: "orchestrator:worker_exit_normal",
      run_instance_id: run_instance_id_from_metadata(running_entry),
      payload: %{
        issue_id: issue_id,
        session_id: session_id,
        run_result: inspect(Map.get(running_entry, :run_result))
      }
    })

    if recovered_stall_stop_with_terminal_evidence?(running_entry) do
      retry_stalled_issue_after_terminal_stop(state, issue_id, running_entry)
    else
      case Map.get(running_entry, :run_result) do
        %{status: :continuation_required} = run_result ->
          Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id} run_result=#{inspect(run_result)}; scheduling active-state continuation check")

          state
          |> complete_issue(issue_id)
          |> schedule_issue_retry(issue_id, 1, %{
            identifier: running_entry.identifier,
            delay_type: :continuation,
            worker_host: Map.get(running_entry, :worker_host),
            workspace_path: Map.get(running_entry, :workspace_path),
            run_trace: run_trace,
            run_instance_id: run_instance_id_from_metadata(running_entry)
          })

        %{status: :completed} = run_result ->
          if run_result.reason == :issue_entered_checking do
            Logger.info("Agent task entered checking for issue_id=#{issue_id} session_id=#{session_id} run_result=#{inspect(run_result)}; scheduling checking recheck")

            state
            |> complete_issue(issue_id)
            |> schedule_issue_retry(issue_id, 1, %{
              identifier: running_entry.identifier,
              delay_type: @checking_recheck_delay_type,
              worker_host: Map.get(running_entry, :worker_host),
              workspace_path: Map.get(running_entry, :workspace_path),
              run_trace: run_trace,
              run_instance_id: run_instance_id_from_metadata(running_entry)
            })
          else
            Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id} run_result=#{inspect(run_result)}; no continuation scheduled")

            complete_issue(state, issue_id, release_claim?: true)
          end

        %{status: :failed, reason: :premature_turn_end} = run_result ->
          Logger.warning("Agent task closed with premature turn end for issue_id=#{issue_id} session_id=#{session_id} run_result=#{inspect(run_result)}; holding claim for state recheck")

          state
          |> complete_issue(issue_id)
          |> schedule_issue_retry(issue_id, 1, %{
            identifier: running_entry.identifier,
            delay_type: :premature_turn_end_hold,
            error: "premature turn end",
            worker_host: Map.get(running_entry, :worker_host),
            workspace_path: Map.get(running_entry, :workspace_path),
            run_trace: run_trace,
            run_instance_id: run_instance_id_from_metadata(running_entry)
          })

        %{status: :failed, reason: :turn_timeout} = run_result ->
          Logger.warning("Agent task timed out for issue_id=#{issue_id} session_id=#{session_id} run_result=#{inspect(run_result)}; scheduling ordinary retry")

          next_attempt = next_retry_attempt_from_running(running_entry)

          schedule_issue_retry(state, issue_id, next_attempt, %{
            identifier: running_entry.identifier,
            error: "turn_timeout",
            worker_host: Map.get(running_entry, :worker_host),
            workspace_path: Map.get(running_entry, :workspace_path),
            run_trace: run_trace,
            run_instance_id: run_instance_id_from_metadata(running_entry)
          })

        _ ->
          Logger.warning("Agent task exited normally for issue_id=#{issue_id} session_id=#{session_id} without run_result; scheduling retry")

          next_attempt = next_retry_attempt_from_running(running_entry)

          schedule_issue_retry(state, issue_id, next_attempt, %{
            identifier: running_entry.identifier,
            error: "agent exited normally without run_result",
            worker_host: Map.get(running_entry, :worker_host),
            workspace_path: Map.get(running_entry, :workspace_path),
            run_trace: run_trace,
            run_instance_id: run_instance_id_from_metadata(running_entry)
          })
      end
    end
  end

  defp recovered_stall_stop_with_terminal_evidence?(running_entry) do
    stall_interrupt_pending?(running_entry) and Map.get(running_entry, :turn_terminal_seen?, false)
  end

  defp retry_stalled_issue_after_terminal_stop(state, issue_id, running_entry) do
    retry_metadata = get_in(running_entry, [:release_state, :retry_metadata]) || %{}
    next_attempt = retry_metadata[:next_attempt] || next_retry_attempt_from_running(running_entry)

    Logger.info("Recovered stalled issue after cooperative stop: issue_id=#{issue_id} issue_identifier=#{running_entry.identifier}; scheduling retry")

    state
    |> complete_issue(issue_id)
    |> schedule_issue_retry(issue_id, next_attempt, %{
      identifier: retry_metadata[:identifier] || running_entry.identifier,
      error: retry_metadata[:error] || "stalled cooperative stop completed",
      worker_host: retry_metadata[:worker_host] || Map.get(running_entry, :worker_host),
      workspace_path: retry_metadata[:workspace_path] || Map.get(running_entry, :workspace_path),
      run_trace: retry_metadata[:run_trace] || Map.get(running_entry, :run_trace),
      run_instance_id: retry_metadata[:run_instance_id] || run_instance_id_from_metadata(running_entry)
    })
  end

  defp record_spawned_todo_transition_failure(run_trace, issue_id, run_instance_id, reason) do
    RunTrace.record(run_trace, :orchestrator, %{
      event: :spawned_todo_transition_failed,
      summary: "orchestrator:spawned_todo_transition_failed",
      run_instance_id: run_instance_id,
      payload: %{issue_id: issue_id, reason: inspect(reason)}
    })
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states, candidate_issues) when is_list(candidate_issues) do
    dispatch_candidate_issue?(issue, active_state_set(), terminal_states, candidate_issues, %State{}) and
      !issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp retry_candidate_issue?(_issue, _terminal_states, _candidate_issues), do: false

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
