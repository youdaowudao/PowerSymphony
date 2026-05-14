defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, RunTrace, Tracker, Workspace}

  @type worker_host :: String.t() | nil
  @type run_result_status :: :completed | :continuation_required | :failed
  @type run_result_reason ::
          :issue_inactive
          | :issue_still_active
          | :issue_entered_checking
          | :max_turns_reached
          | :premature_turn_end
          | :turn_timeout
  @type run_result :: %{
          status: run_result_status(),
          reason: run_result_reason(),
          turn_count: pos_integer(),
          run_instance_id: String.t() | nil
        }

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    run_instance_id = Keyword.get(opts, :run_instance_id)

    trace =
      case Keyword.get(opts, :run_trace) do
        %RunTrace{} = existing_trace ->
          existing_trace

        nil ->
          case RunTrace.start(issue, worker_host: worker_host) do
            {:ok, new_trace} ->
              new_trace

            {:error, reason} ->
              Logger.warning("Run trace initialization failed for #{issue_context(issue)}: #{inspect(reason)}")
              nil
          end
      end

    RunTrace.with_context(trace, fn ->
      RunTrace.record(trace, :agent_runner, %{
        event: :worker_attempt_started,
        summary: "agent_runner:worker_attempt_started",
        run_instance_id: run_instance_id,
        payload: %{worker_host: worker_host}
      })

      case Workspace.create_for_issue(issue, worker_host) do
        {:ok, workspace} ->
          trace = RunTrace.update(trace, %{workspace_path: workspace})

          RunTrace.record(trace, :agent_runner, %{
            event: :workspace_prepared,
            summary: "agent_runner:workspace_prepared",
            run_instance_id: run_instance_id,
            payload: %{workspace_path: workspace, worker_host: worker_host}
          })

          send_worker_runtime_info(codex_update_recipient, issue, run_instance_id, worker_host, workspace)

          try do
            with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
              run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host, run_instance_id)
            end
          after
            Workspace.run_after_run_hook(workspace, issue, worker_host)
          end

        {:error, reason} ->
          RunTrace.record(trace, :agent_runner, %{
            event: :workspace_prepare_failed,
            summary: "agent_runner:workspace_prepare_failed",
            run_instance_id: run_instance_id,
            payload: %{worker_host: worker_host, reason: inspect(reason)}
          })

          {:error, reason}
      end
    end)
  end

  defp codex_message_handler(recipient, issue, run_instance_id) do
    fn message ->
      send_codex_update(recipient, issue, run_instance_id, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, run_instance_id, message)
       when is_binary(issue_id) and is_pid(recipient) do
    message = put_run_instance_id(message, run_instance_id)
    RunTrace.record(:codex, message)
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, run_instance_id, message) do
    message = put_run_instance_id(message, run_instance_id)
    RunTrace.record(:codex, message)
    :ok
  end

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, run_instance_id, worker_host, workspace)
       when is_binary(issue_id) and is_binary(workspace) do
    RunTrace.record(:agent_runner, %{
      event: :worker_runtime_info,
      summary: "agent_runner:worker_runtime_info",
      run_instance_id: run_instance_id,
      payload: %{worker_host: worker_host, workspace_path: workspace}
    })

    if is_pid(recipient) do
      send(
        recipient,
        {:worker_runtime_info, issue_id,
         %{
           run_instance_id: run_instance_id,
           worker_host: worker_host,
           workspace_path: workspace
         }}
      )
    end

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _run_instance_id, _worker_host, _workspace), do: :ok

  defp send_run_result(recipient, %Issue{id: issue_id}, run_instance_id, %{
         status: status,
         reason: reason,
         turn_count: turn_count
       })
       when is_binary(issue_id) and is_atom(status) and is_atom(reason) and is_integer(turn_count) and turn_count > 0 do
    RunTrace.record(:agent_runner, %{
      event: :run_result,
      summary: "agent_runner:run_result",
      run_instance_id: run_instance_id,
      payload: %{status: status, reason: reason, turn_count: turn_count}
    })

    if is_pid(recipient) do
      send(
        recipient,
        {:agent_run_result, issue_id,
         %{
           status: status,
           reason: reason,
           turn_count: turn_count,
           run_instance_id: run_instance_id
         }}
      )
    end

    :ok
  end

  defp send_run_result(_recipient, _issue, _run_instance_id, _run_result), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host, run_instance_id) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    run_mode = Keyword.get(opts, :run_mode, :normal)

    turn_context = %{
      codex_update_recipient: codex_update_recipient,
      opts: opts,
      issue_state_fetcher: issue_state_fetcher,
      run_mode: run_mode,
      max_turns: max_turns,
      run_instance_id: run_instance_id
    }

    with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
      try do
        do_run_codex_turns(session, workspace, issue, turn_context, 1)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(app_session, workspace, issue, turn_context, turn_number) do
    %{
      codex_update_recipient: codex_update_recipient,
      opts: opts,
      issue_state_fetcher: issue_state_fetcher,
      run_mode: run_mode,
      max_turns: max_turns,
      run_instance_id: run_instance_id
    } = turn_context

    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    case AppServer.run_turn(
           app_session,
           prompt,
           issue,
           on_message: codex_message_handler(codex_update_recipient, issue, run_instance_id)
         ) do
      {:ok, turn_session} ->
        Logger.info("Completed agent turn for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

        case continue_with_issue?(issue, issue_state_fetcher, run_mode) do
          {:continue, refreshed_issue} when turn_number < max_turns ->
            send_run_result(codex_update_recipient, issue, run_instance_id, %{
              status: :continuation_required,
              reason: :issue_still_active,
              turn_count: turn_number
            })

            Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

            do_run_codex_turns(
              app_session,
              workspace,
              refreshed_issue,
              turn_context,
              turn_number + 1
            )

          {:continue, refreshed_issue} ->
            send_run_result(codex_update_recipient, issue, run_instance_id, %{
              status: :continuation_required,
              reason: :max_turns_reached,
              turn_count: turn_number
            })

            Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

            :ok

          {:done, _refreshed_issue, reason} ->
            send_run_result(codex_update_recipient, issue, run_instance_id, %{
              status: :completed,
              reason: reason,
              turn_count: turn_number
            })

            :ok

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        handle_turn_error(reason, issue, codex_update_recipient, run_instance_id, turn_number)
    end
  end

  defp handle_turn_error({error_type, _details} = reason, issue, codex_update_recipient, run_instance_id, turn_number)
       when error_type in [:turn_failed, :turn_cancelled] do
    send_run_result(codex_update_recipient, issue, run_instance_id, %{
      status: :failed,
      reason: :premature_turn_end,
      turn_count: turn_number
    })

    Logger.warning("Agent turn ended prematurely for #{issue_context(issue)} turn=#{turn_number} reason=#{inspect(reason)}")

    :ok
  end

  defp handle_turn_error(:turn_timeout, issue, codex_update_recipient, run_instance_id, turn_number) do
    send_run_result(codex_update_recipient, issue, run_instance_id, %{
      status: :failed,
      reason: :turn_timeout,
      turn_count: turn_number
    })

    Logger.warning("Agent turn timed out for #{issue_context(issue)} turn=#{turn_number}")

    :ok
  end

  defp handle_turn_error(reason, _issue, _codex_update_recipient, _run_instance_id, _turn_number) do
    {:error, reason}
  end

  defp put_run_instance_id(message, run_instance_id) when is_map(message) and is_binary(run_instance_id) do
    Map.put(message, :run_instance_id, run_instance_id)
  end

  defp put_run_instance_id(message, _run_instance_id), do: message

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher, run_mode) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        continue_with_refreshed_issue(refreshed_issue, run_mode)

      {:ok, []} ->
        {:done, issue, :issue_inactive}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher, _run_mode), do: {:done, issue, :issue_inactive}

  defp continue_with_refreshed_issue(%Issue{} = refreshed_issue, :checking_recheck) do
    {:done, refreshed_issue, checking_recheck_completion_reason(refreshed_issue)}
  end

  defp continue_with_refreshed_issue(%Issue{} = refreshed_issue, _run_mode) do
    cond do
      checking_issue_state?(refreshed_issue.state) ->
        {:done, refreshed_issue, :issue_entered_checking}

      retry_candidate_issue?(refreshed_issue) ->
        {:continue, refreshed_issue}

      true ->
        {:done, refreshed_issue, :issue_inactive}
    end
  end

  defp checking_recheck_completion_reason(%Issue{} = refreshed_issue) do
    if checking_issue_state?(refreshed_issue.state), do: :issue_entered_checking, else: :issue_inactive
  end

  defp retry_candidate_issue?(%Issue{} = issue) do
    issue_routable_to_worker?(issue) and
      active_issue_state?(issue.state) and
      !issue_blocked_by_non_terminal?(issue)
  end

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  defp issue_blocked_by_non_terminal?(%Issue{blocked_by: blockers}) when is_list(blockers) do
    terminal_states = terminal_state_set()

    Enum.any?(blockers, fn
      %{state: blocker_state} when is_binary(blocker_state) ->
        !MapSet.member?(terminal_states, normalize_issue_state(blocker_state))

      _ ->
        true
    end)
  end

  defp issue_blocked_by_non_terminal?(_issue), do: false

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp checking_issue_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == "checking"
  end

  defp checking_issue_state?(_state_name), do: false

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
