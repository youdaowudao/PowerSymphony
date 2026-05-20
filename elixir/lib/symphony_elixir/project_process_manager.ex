defmodule SymphonyElixir.ProjectProcessManager do
  @moduledoc """
  Control-plane runtime source of truth for per-project worker processes.
  """

  use GenServer

  alias SymphonyElixir.{Config, ProjectRegistry, ProjectRegistryLoader, ProjectWorkflowGenerator, StateReducer}
  alias SymphonyElixir.ProjectRegistry.Entry

  @startup_grace_ms 1_000
  @stop_wait_ms 1_000
  @default_name __MODULE__
  @runtime_filename "runtime.json"
  @pid_filename "worker.pid"
  @stdout_filename "worker.stdout.log"
  @stderr_filename "worker.stderr.log"

  @type runtime_status ::
          :not_started
          | :starting
          | :running
          | :stopping
          | :stopped
          | :crashed
          | :start_failed
          | :disabled
          | :config_invalid
          | :unreachable

  @type lifecycle_status :: :not_started | :starting | :running | :stopping | :stopped | :crashed | :start_failed

  @type health_status :: :unknown | :healthy | :degraded | :unreachable

  @type runtime_state :: %{
          status: lifecycle_status(),
          pid: integer() | nil,
          worker_port: non_neg_integer() | nil,
          started_at: DateTime.t() | nil,
          exit_code: integer() | nil,
          exit_reason: String.t() | nil,
          stdout_path: String.t() | nil,
          stderr_path: String.t() | nil,
          error_summary: String.t() | nil,
          health_status: health_status(),
          last_seen_at: DateTime.t() | nil,
          last_health_check_at: DateTime.t() | nil,
          last_error: String.t() | nil,
          health_check_timeout_ms: pos_integer(),
          run_summaries: [map()]
        }

  @type state :: %{
          name: GenServer.name(),
          command_builder: (Entry.t() -> String.t()),
          runtimes: %{optional(String.t()) => runtime_state()},
          active_ports: %{optional(reference()) => %{project_id: String.t(), port: port()}}
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
    name = Keyword.get(opts, :name, default_name())
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec project_registry() :: ProjectRegistry.t()
  def project_registry do
    project_registry(default_name())
  end

  @spec project_registry(GenServer.name()) :: ProjectRegistry.t()
  def project_registry(server) do
    project_registry(server, include_run_summaries: false)
  end

  @spec project_registry_for_display() :: ProjectRegistry.t()
  def project_registry_for_display do
    project_registry_for_display(default_name())
  end

  @spec project_registry_for_display(GenServer.name()) :: ProjectRegistry.t()
  def project_registry_for_display(server) do
    project_registry(server, include_run_summaries: true)
  end

  @spec project_registry(GenServer.name(), keyword()) :: ProjectRegistry.t()
  def project_registry(server, opts) when is_list(opts) do
    include_run_summaries = Keyword.get(opts, :include_run_summaries, false)
    request = {:project_registry, include_run_summaries: include_run_summaries}

    if alive?(server) do
      GenServer.call(server, request, 15_000)
    else
      project_static_registry()
      |> project_registry_with_runtime(%{}, include_run_summaries: include_run_summaries)
    end
  end

  @spec start_project(String.t()) :: {:ok, runtime_state()} | {:error, term()}
  def start_project(project_id) when is_binary(project_id) do
    start_project(default_name(), project_id)
  end

  @spec start_project(GenServer.name(), String.t()) :: {:ok, runtime_state()} | {:error, term()}
  def start_project(server, project_id) when is_binary(project_id) do
    GenServer.call(server, {:start_project, project_id}, 15_000)
  end

  @spec stop_project(String.t()) :: {:ok, runtime_state()} | {:error, term()}
  def stop_project(project_id) when is_binary(project_id) do
    stop_project(default_name(), project_id)
  end

  @spec stop_project(GenServer.name(), String.t()) :: {:ok, runtime_state()} | {:error, term()}
  def stop_project(server, project_id) when is_binary(project_id) do
    GenServer.call(server, {:stop_project, project_id}, 15_000)
  end

  @spec restart_project(String.t()) :: {:ok, runtime_state()} | {:error, term()}
  def restart_project(project_id) when is_binary(project_id) do
    restart_project(default_name(), project_id)
  end

  @spec restart_project(GenServer.name(), String.t()) :: {:ok, runtime_state()} | {:error, term()}
  def restart_project(server, project_id) when is_binary(project_id) do
    GenServer.call(server, {:restart_project, project_id}, 15_000)
  end

  @spec health_poll_targets(GenServer.name()) :: [
          %{
            project_id: String.t(),
            worker_port: non_neg_integer(),
            health_check_timeout_ms: pos_integer()
          }
        ]
  def health_poll_targets(server \\ default_name()) do
    GenServer.call(server, :health_poll_targets, 15_000)
  end

  @spec record_health_success(GenServer.name(), String.t(), DateTime.t()) :: :ok
  def record_health_success(server \\ default_name(), project_id, %DateTime{} = observed_at)
      when is_binary(project_id) do
    GenServer.call(server, {:record_health_success, project_id, observed_at}, 15_000)
  end

  @spec record_health_failure(GenServer.name(), String.t(), DateTime.t(), String.t()) :: :ok
  def record_health_failure(server \\ default_name(), project_id, %DateTime{} = observed_at, error)
      when is_binary(project_id) and is_binary(error) do
    GenServer.call(server, {:record_health_failure, project_id, observed_at, error}, 15_000)
  end

  @spec worker_port_for_project(GenServer.name(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def worker_port_for_project(server \\ default_name(), project_id) when is_binary(project_id) do
    GenServer.call(server, {:worker_port_for_project, project_id}, 15_000)
  end

  @impl true
  def init(opts) do
    command_builder = Keyword.get(opts, :command_builder, &default_command_builder/1)

    state = %{
      name: Keyword.get(opts, :name, default_name()),
      command_builder: command_builder,
      runtimes: load_persisted_runtimes(),
      active_ports: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:project_registry, opts}, _from, state) do
    include_run_summaries = Keyword.get(opts, :include_run_summaries, false)

    registry =
      project_static_registry()
      |> project_registry_with_runtime(state.runtimes, include_run_summaries: include_run_summaries)

    {:reply, registry, %{state | runtimes: refresh_runtime_truth(state.runtimes, registry)}}
  end

  def handle_call(:health_poll_targets, _from, state) do
    targets =
      project_static_registry()
      |> Map.get(:entries, [])
      |> Enum.flat_map(fn
        %Entry{project_id: project_id} = entry when is_binary(project_id) ->
          runtime_state =
            Map.get(
              state.runtimes,
              project_id,
              default_runtime_state(entry.normalized_config && entry.normalized_config.worker_port)
            )
            |> hydrate_runtime_state(entry.normalized_config && entry.normalized_config.worker_port)

          if runtime_state.status == :running and
               projected_status(entry, runtime_state) == :running and
               is_integer(runtime_state.worker_port) do
            [
              %{
                project_id: project_id,
                worker_port: runtime_state.worker_port,
                health_check_timeout_ms: runtime_state.health_check_timeout_ms
              }
            ]
          else
            []
          end

        _entry ->
          []
      end)

    {:reply, targets, state}
  end

  def handle_call({:start_project, project_id}, _from, state) do
    registry = project_static_registry()

    case find_entry(registry, project_id) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:ok, entry} ->
        case start_project_runtime(entry, state) do
          {{:ok, runtime_state}, next_state} ->
            {:reply, {:ok, runtime_state}, next_state}

          {{:error, reason}, next_state} ->
            {:reply, {:error, reason}, next_state}
        end
    end
  end

  def handle_call({:stop_project, project_id}, _from, state) do
    registry = project_static_registry()

    case find_entry(registry, project_id) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:ok, entry} ->
        case stop_project_runtime(entry, state) do
          {{:ok, runtime_state}, next_state} ->
            {:reply, {:ok, runtime_state}, next_state}

          {{:error, reason}, next_state} ->
            {:reply, {:error, reason}, next_state}
        end
    end
  end

  def handle_call({:restart_project, project_id}, _from, state) do
    registry = project_static_registry()

    case find_entry(registry, project_id) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:ok, entry} ->
        with {{:ok, _stopped_state}, stopped_state} <- stop_project_runtime(entry, state, allow_not_running: true),
             {{:ok, runtime_state}, next_state} <- start_project_runtime(entry, stopped_state) do
          {:reply, {:ok, runtime_state}, next_state}
        else
          {{:error, reason}, next_state} ->
            {:reply, {:error, reason}, next_state}
        end
    end
  end

  def handle_call({:record_health_success, project_id, observed_at}, _from, state) do
    {:reply, :ok, update_health_runtime(state, project_id, &health_success_state(&1, observed_at))}
  end

  def handle_call({:record_health_failure, project_id, observed_at, error}, _from, state) do
    {:reply, :ok, update_health_runtime(state, project_id, &health_failure_state(&1, observed_at, error))}
  end

  def handle_call({:worker_port_for_project, project_id}, _from, state) do
    registry =
      project_static_registry()
      |> project_registry_with_runtime(state.runtimes)

    reply =
      case find_entry(registry, project_id) do
        {:ok, entry} ->
          runtime_state = Map.get(entry, :runtime_state, %{})
          worker_port = Map.get(runtime_state, :worker_port) || (entry.normalized_config && entry.normalized_config.worker_port)

          if is_integer(worker_port) do
            {:ok, worker_port}
          else
            {:error, :worker_port_unavailable}
          end

        {:error, reason} ->
          {:error, reason}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info({port, {:exit_status, exit_status}}, state) when is_port(port) do
    port_key = inspect(port)

    case Map.pop(state.active_ports, port_key) do
      {nil, _ports} ->
        {:noreply, state}

      {%{project_id: project_id}, remaining_ports} ->
        runtime_state = Map.get(state.runtimes, project_id, default_runtime_state())

        next_runtime =
          runtime_state
          |> runtime_exit_state(exit_status)
          |> persist_runtime(project_runtime_dir(project_static_registry(), project_id))

        {:noreply,
         %{
           state
           | active_ports: remaining_ports,
             runtimes: Map.put(state.runtimes, project_id, next_runtime)
         }}
    end
  end

  def handle_info({_port, {:data, _data}}, state), do: {:noreply, state}

  defp start_project_runtime(entry, state) do
    case ensure_workflow_generated(entry) do
      :ok ->
        case projected_status(entry, Map.get(state.runtimes, entry.project_id)) do
          :config_invalid ->
            {{:error, :config_invalid}, state}

          :disabled ->
            {{:error, :disabled}, state}

          status when status in [:starting, :running, :stopping] ->
            {{:error, :already_running}, state}

          _other ->
            do_start_project_runtime(entry, state)
        end

      {:error, :disabled} ->
        {{:error, :disabled}, state}

      {:error, _reason} ->
        {{:error, :config_invalid}, state}
    end
  end

  defp do_start_project_runtime(entry, state) do
    runtime_dir = project_runtime_dir(entry)
    File.mkdir_p!(runtime_dir)

    stdout_path = Path.join(runtime_dir, @stdout_filename)
    stderr_path = Path.join(runtime_dir, @stderr_filename)
    File.write!(stdout_path, "", [:append])
    File.write!(stderr_path, "", [:append])

    starting_state =
      default_runtime_state(entry.normalized_config.worker_port)
      |> Map.merge(%{
        status: :starting,
        stdout_path: stdout_path,
        stderr_path: stderr_path,
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> persist_runtime(runtime_dir)

    state = %{state | runtimes: Map.put(state.runtimes, entry.project_id, starting_state)}

    case open_worker_port(entry, state.command_builder, stdout_path, stderr_path) do
      {:ok, port, os_pid} ->
        case await_startup_outcome(port, os_pid, @startup_grace_ms) do
          :running ->
            running_state =
              starting_state
              |> Map.merge(%{status: :running, pid: os_pid})
              |> persist_runtime(runtime_dir)

            next_state = %{
              state
              | active_ports: Map.put(state.active_ports, inspect(port), %{project_id: entry.project_id, port: port}),
                runtimes: Map.put(state.runtimes, entry.project_id, running_state)
            }

            {{:ok, running_state}, next_state}

          {:exited, exit_code, exit_reason} ->
            failed_state =
              starting_state
              |> Map.merge(%{
                status: :start_failed,
                pid: nil,
                started_at: nil,
                exit_code: exit_code,
                exit_reason: exit_reason,
                error_summary: "worker command exited during startup"
              })
              |> persist_runtime(runtime_dir)

            {{:error, :start_failed}, %{state | runtimes: Map.put(state.runtimes, entry.project_id, failed_state)}}
        end

      {:error, reason} ->
        failed_state =
          starting_state
          |> Map.merge(%{
            status: :start_failed,
            started_at: nil,
            error_summary: "worker failed to start: #{inspect(reason)}"
          })
          |> persist_runtime(runtime_dir)

        {{:error, :start_failed}, %{state | runtimes: Map.put(state.runtimes, entry.project_id, failed_state)}}
    end
  end

  defp stop_project_runtime(entry, state, opts \\ []) do
    runtime_state = Map.get(state.runtimes, entry.project_id, default_runtime_state(entry.normalized_config.worker_port))
    allow_not_running = Keyword.get(opts, :allow_not_running, false)

    cond do
      runtime_state.status in [:running, :starting, :crashed] and is_integer(runtime_state.pid) ->
        do_stop_project_runtime(entry, runtime_state, state)

      allow_not_running ->
        stopped_state =
          runtime_state
          |> Map.merge(%{
            status: :stopped,
            pid: nil,
            started_at: nil,
            exit_reason: runtime_state.exit_reason,
            error_summary: runtime_state.error_summary
          })
          |> persist_runtime(project_runtime_dir(entry))

        {{:ok, stopped_state}, %{state | runtimes: Map.put(state.runtimes, entry.project_id, stopped_state)}}

      true ->
        {{:error, :not_running}, state}
    end
  end

  defp do_stop_project_runtime(entry, runtime_state, state) do
    runtime_dir = project_runtime_dir(entry)

    stopping_state =
      runtime_state
      |> Map.put(:status, :stopping)
      |> persist_runtime(runtime_dir)

    if is_integer(runtime_state.pid) and process_alive?(runtime_state.pid) do
      _ = System.cmd("kill", ["-TERM", Integer.to_string(runtime_state.pid)])

      unless wait_until_dead(runtime_state.pid, @stop_wait_ms) do
        _ = System.cmd("kill", ["-KILL", Integer.to_string(runtime_state.pid)])
        _ = wait_until_dead(runtime_state.pid, @stop_wait_ms)
      end
    end

    remaining_ports =
      Enum.reject(state.active_ports, fn {_key, active} ->
        active.project_id == entry.project_id
      end)
      |> Enum.into(%{})

    stopped_state =
      stopping_state
      |> Map.merge(%{
        status: :stopped,
        pid: nil,
        started_at: nil,
        exit_code: 0,
        exit_reason: "stopped",
        error_summary: nil
      })
      |> persist_runtime(runtime_dir)

    {{:ok, stopped_state}, %{state | active_ports: remaining_ports, runtimes: Map.put(state.runtimes, entry.project_id, stopped_state)}}
  end

  defp open_worker_port(entry, command_builder, stdout_path, stderr_path) do
    executable = System.find_executable("bash")
    runtime_dir = project_runtime_dir(entry)
    command = command_builder.(entry)

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      wrapped_command =
        [
          "mkdir -p #{shell_escape(runtime_dir)}",
          "touch #{shell_escape(stdout_path)} #{shell_escape(stderr_path)}",
          "exec bash -lc #{shell_escape(command)} >> #{shell_escape(stdout_path)} 2>> #{shell_escape(stderr_path)}"
        ]
        |> Enum.join(" && ")

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            args: [~c"-c", String.to_charlist(wrapped_command)]
          ]
        )

      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} when is_integer(os_pid) ->
          File.write!(Path.join(runtime_dir, @pid_filename), Integer.to_string(os_pid))
          {:ok, port, os_pid}

        _other ->
          Port.close(port)
          {:error, :os_pid_unavailable}
      end
    end
  end

  defp runtime_exit_state(runtime_state, exit_status) do
    runtime_state = hydrate_runtime_state(runtime_state)

    base =
      runtime_state
      |> Map.merge(%{
        pid: nil,
        exit_code: exit_status,
        started_at: nil,
        exit_reason: exit_reason(exit_status),
        health_status: :unknown
      })

    case runtime_state.status do
      :stopping ->
        %{base | status: :stopped, error_summary: nil}

      :starting ->
        %{base | status: :start_failed, error_summary: "worker command exited during startup"}

      :running ->
        %{base | status: :crashed, error_summary: "worker exited unexpectedly"}

      _other ->
        %{base | status: :stopped}
    end
  end

  defp find_entry(registry, project_id) do
    case ProjectRegistry.find_entry(registry, project_id) do
      %Entry{} = entry -> {:ok, entry}
      nil -> {:error, :not_found}
    end
  end

  defp project_static_registry do
    ProjectRegistryLoader.load()
  end

  defp project_registry_with_runtime(%ProjectRegistry{} = registry, runtime_map, opts \\ []) do
    include_run_summaries = Keyword.get(opts, :include_run_summaries, false)

    entries =
      Enum.map(registry.entries, fn entry ->
        merged_runtime =
          entry
          |> merge_runtime_state(Map.get(runtime_map, entry.project_id))
          |> maybe_refresh_run_summaries(include_run_summaries)
          |> reconcile_project_runtime(entry)

        %{entry | runtime_state: merged_runtime}
      end)

    %ProjectRegistry{registry | entries: entries}
  end

  defp merge_runtime_state(%Entry{} = entry, runtime_state) do
    runtime_state =
      runtime_state
      |> case do
        nil -> default_runtime_state(entry.normalized_config && entry.normalized_config.worker_port)
        state -> state
      end
      |> hydrate_runtime_state(entry.normalized_config && entry.normalized_config.worker_port)

    base = Map.put(runtime_state, :worker_port, entry.normalized_config && entry.normalized_config.worker_port)

    base
    |> Map.put(:status, projected_status(entry, base))
    |> project_health_status()
  end

  defp reconcile_project_runtime(runtime_state, %Entry{} = entry) do
    runtime_dir = project_runtime_dir(entry)

    cond do
      runtime_state.status in [:config_invalid, :disabled] ->
        runtime_state

      runtime_state.status in [:running, :starting, :stopping] and is_integer(runtime_state.pid) ->
        if process_alive?(runtime_state.pid) do
          persist_runtime(runtime_state, runtime_dir)
        else
          runtime_state
          |> Map.merge(%{
            status: :crashed,
            pid: nil,
            exit_reason: "worker pid no longer exists",
            error_summary: "worker pid no longer exists"
          })
          |> persist_runtime(runtime_dir)
        end

      true ->
        persist_runtime(runtime_state, runtime_dir)
    end
  end

  defp projected_status(%Entry{validation_result: :invalid}, _runtime_state), do: :config_invalid

  defp projected_status(%Entry{normalized_config: %{enabled: false}}, _runtime_state), do: :disabled

  defp projected_status(%Entry{normalized_config: config}, runtime_state) do
    if workflow_available?(config), do: runtime_state.status, else: :config_invalid
  end

  defp ensure_workflow_generated(%Entry{validation_result: :invalid}), do: {:error, :config_invalid}
  defp ensure_workflow_generated(%Entry{normalized_config: %{enabled: false}}), do: {:error, :disabled}

  defp ensure_workflow_generated(%Entry{normalized_config: config}) do
    cond do
      File.regular?(config.workflow_generated) ->
        :ok

      workflow_generatable?(config) ->
        ProjectWorkflowGenerator.generate(config)

      true ->
        {:error, :config_invalid}
    end
  end

  defp workflow_available?(config) do
    File.regular?(config.workflow_generated) or workflow_generatable?(config)
  end

  defp workflow_generatable?(config) do
    is_binary(config.workflow_generated) and
      is_binary(config.workflow_source) and
      is_binary(config.project_slug) and
      is_binary(config.repo_url) and
      File.regular?(config.workflow_source)
  end

  defp project_health_status(%{status: :running, health_status: :unreachable} = runtime_state),
    do: %{runtime_state | status: :unreachable}

  defp project_health_status(runtime_state), do: runtime_state

  defp maybe_refresh_run_summaries(runtime_state, true), do: refresh_run_summaries(runtime_state)
  defp maybe_refresh_run_summaries(runtime_state, false), do: Map.put(runtime_state, :run_summaries, [])

  defp refresh_run_summaries(%{status: status, worker_port: worker_port} = runtime_state)
       when status in [:running, :unreachable] and is_integer(worker_port) do
    case Req.get("http://127.0.0.1:#{worker_port}/api/v1/state",
           retry: false,
           receive_timeout: runtime_state.health_check_timeout_ms
         ) do
      {:ok, %Req.Response{status: http_status, body: body}}
      when http_status in 200..299 and is_map(body) ->
        Map.put(runtime_state, :run_summaries, project_run_summaries_from_state(body))

      _ ->
        Map.put(runtime_state, :run_summaries, [])
    end
  end

  defp refresh_run_summaries(runtime_state), do: Map.put(runtime_state, :run_summaries, [])

  defp project_run_summaries_from_state(body) when is_map(body) do
    running_entries =
      body
      |> loaded_runtime_value(:running)
      |> List.wrap()
      |> Enum.filter(&is_map/1)

    running_entries
    |> Enum.map(&project_run_summary_from_running_entry/1)
    |> Enum.filter(&summary_present?/1)
    |> attach_run_summary_relationships()
  end

  defp project_run_summary_from_running_entry(entry) when is_map(entry) do
    %{
      issue_identifier: loaded_runtime_value(entry, :issue_identifier),
      title: loaded_runtime_value(entry, :title),
      linear_state: loaded_runtime_value(entry, :linear_state),
      issue_url: loaded_runtime_value(entry, :issue_url),
      current_phase: loaded_runtime_value(entry, :current_phase),
      current_action: loaded_runtime_value(entry, :current_action),
      health: loaded_runtime_value(entry, :health),
      run_status: loaded_runtime_value(entry, :run_status),
      session_id: loaded_runtime_value(entry, :session_id),
      thread_id: loaded_runtime_value(entry, :thread_id),
      turn_id: loaded_runtime_value(entry, :turn_id),
      turn_count: loaded_runtime_value(entry, :turn_count),
      last_event_at: loaded_runtime_value(entry, :last_event_at) |> parse_datetime(),
      run_duration_seconds: loaded_runtime_value(entry, :run_duration_seconds),
      last_error: loaded_runtime_value(entry, :last_error),
      approval_pending: loaded_runtime_value(entry, :approval_pending) == true,
      tool_failure: loaded_runtime_value(entry, :tool_failure) == true,
      blocked_by: summary_dependency_list(loaded_runtime_value(entry, :blocked_by))
    }
  end

  defp attach_run_summary_relationships(summaries) when is_list(summaries) do
    Enum.map(summaries, fn summary ->
      summary_with_blocks =
        Map.put(summary, :blocks, reverse_blocks_for_summary(summary, summaries))

      Map.put(summary_with_blocks, :attention_items, attention_items_for_summary(summary_with_blocks))
    end)
  end

  defp summary_dependency_list(value) do
    value
    |> List.wrap()
    |> Enum.map(&summary_dependency/1)
    |> Enum.filter(&summary_present?/1)
  end

  defp summary_dependency(item) when is_map(item) do
    %{
      issue_identifier: loaded_runtime_value(item, :issue_identifier) || loaded_runtime_value(item, :identifier),
      title: loaded_runtime_value(item, :title),
      linear_state: loaded_runtime_value(item, :linear_state) || loaded_runtime_value(item, :state),
      url: loaded_runtime_value(item, :url)
    }
  end

  defp summary_dependency(_item), do: %{}

  defp reverse_blocks_for_summary(summary, summaries) when is_map(summary) and is_list(summaries) do
    target_identifier = Map.get(summary, :issue_identifier)

    summaries
    |> Enum.filter(fn other_summary ->
      other_summary != summary and
        Enum.any?(Map.get(other_summary, :blocked_by, []), fn blocker ->
          Map.get(blocker, :issue_identifier) == target_identifier
        end)
    end)
    |> Enum.map(fn other_summary ->
      %{
        issue_identifier: Map.get(other_summary, :issue_identifier),
        title: Map.get(other_summary, :title),
        linear_state: Map.get(other_summary, :linear_state),
        url: Map.get(other_summary, :issue_url)
      }
    end)
    |> Enum.filter(&summary_present?/1)
  end

  defp attention_items_for_summary(summary) when is_map(summary) do
    health = attention_health(summary)
    blockers = Map.get(summary, :blocked_by, [])
    blocks = Map.get(summary, :blocks, [])

    []
    |> maybe_add_attention(blocking_attention_item(blockers))
    |> maybe_add_attention(blocked_children_attention_item(blocks))
    |> maybe_add_attention(health_attention_item(summary, health))
  end

  defp maybe_add_attention(items, nil), do: items

  defp maybe_add_attention(items, %{} = item), do: items ++ [item]

  defp blocking_attention_item([]), do: nil

  defp blocking_attention_item(blockers) when is_list(blockers) do
    active_blockers = non_terminal_blockers(blockers)

    identifiers =
      active_blockers
      |> Enum.map(&Map.get(&1, :issue_identifier))
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    cond do
      active_blockers == [] ->
        nil

      identifiers == [] ->
        %{kind: "blocked_by", message: "Current blockers are still unresolved."}

      true ->
        %{kind: "blocked_by", message: "Current blockers are still unresolved: #{Enum.join(identifiers, ", ")}."}
    end
  end

  defp blocked_children_attention_item([]), do: nil

  defp blocked_children_attention_item(blocks) when is_list(blocks) do
    identifiers =
      blocks
      |> Enum.map(&Map.get(&1, :issue_identifier))
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    if identifiers == [] do
      %{kind: "blocks", message: "Related blocked issues are still waiting."}
    else
      %{kind: "blocks", message: "Related blocked issues are still waiting: #{Enum.join(identifiers, ", ")}."}
    end
  end

  defp health_attention_item(_summary, "slow"), do: nil
  defp health_attention_item(_summary, "normal"), do: nil
  defp health_attention_item(_summary, "quiet"), do: nil

  defp health_attention_item(_summary, health) do
    message =
      case health do
        "needs_attention" -> "Run requires manual follow-up."
        "possibly_stalled" -> "Run may be stalled and needs a closer look."
        "stalled" -> "Run appears stalled and needs a closer look."
        "tool_blocked" -> "Run is blocked on a tool failure and needs manual follow-up."
        "codex_error" -> "Run ended with an error and needs manual follow-up."
        _ -> nil
      end

    if is_binary(message) do
      %{kind: health, message: message}
    else
      nil
    end
  end

  defp non_terminal_blockers(blockers) when is_list(blockers) do
    terminal_states =
      Config.settings!().tracker.terminal_states
      |> Enum.map(&normalize_issue_state/1)
      |> MapSet.new()

    Enum.reject(blockers, fn blocker ->
      blocker
      |> Map.get(:linear_state, Map.get(blocker, :state))
      |> terminal_issue_state?(terminal_states)
    end)
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_issue_state(_state_name), do: nil

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp attention_health(summary) when is_map(summary) do
    case Map.get(summary, :health) do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        if summary_health_fallback_safe?(summary) do
          config = Config.settings!()

          StateReducer.health_for_summary(
            summary,
            stall_timeout_ms: config.codex.stall_timeout_ms,
            checking_interval_ms: config.polling.checking_interval_ms
          )
        else
          nil
        end
    end
  end

  defp summary_present?(summary) when is_map(summary) do
    Enum.any?(summary, fn
      {_key, true} -> true
      {_key, value} when is_binary(value) -> value != ""
      {_key, value} when is_integer(value) -> true
      {_key, %DateTime{}} -> true
      {_key, value} when is_list(value) -> value != []
      _other -> false
    end)
  end

  defp summary_health_fallback_safe?(summary) when is_map(summary) do
    Map.get(summary, :approval_pending) == true or
      Map.get(summary, :tool_failure) == true or
      present_string?(Map.get(summary, :run_status)) or
      complete_summary_activity_context?(summary)
  end

  defp complete_summary_activity_context?(summary) when is_map(summary) do
    present_string?(Map.get(summary, :linear_state)) and
      present_string?(Map.get(summary, :current_phase)) and
      present_string?(Map.get(summary, :current_action)) and
      match?(%DateTime{}, Map.get(summary, :last_event_at))
  end

  defp present_string?(value) when is_binary(value), do: value != ""
  defp present_string?(_value), do: false

  defp refresh_runtime_truth(runtime_map, %ProjectRegistry{entries: entries}) do
    Enum.reduce(entries, runtime_map, fn
      %Entry{project_id: nil}, acc ->
        acc

      %Entry{} = entry, acc ->
        runtime_state =
          Map.get(acc, entry.project_id, default_runtime_state(entry.normalized_config && entry.normalized_config.worker_port))

        Map.put(acc, entry.project_id, %{runtime_state | worker_port: entry.normalized_config && entry.normalized_config.worker_port})
    end)
  end

  defp load_persisted_runtimes do
    project_static_registry()
    |> Map.get(:entries, [])
    |> Enum.reduce(%{}, fn
      %Entry{project_id: nil}, acc ->
        acc

      %Entry{} = entry, acc ->
        Map.put(acc, entry.project_id, load_runtime_for_entry(entry))
    end)
  end

  defp load_runtime_for_entry(entry) do
    runtime_dir = project_runtime_dir(entry)
    runtime_path = Path.join(runtime_dir, @runtime_filename)
    pid_path = Path.join(runtime_dir, @pid_filename)

    with true <- File.regular?(runtime_path),
         {:ok, json} <- File.read(runtime_path),
         {:ok, decoded} <- Jason.decode(json) do
      decoded
      |> Map.put_new("worker_port", entry.normalized_config && entry.normalized_config.worker_port)
      |> maybe_override_pid_from_file(pid_path)
      |> normalize_loaded_runtime()
      |> reconcile_loaded_runtime(runtime_dir)
    else
      _other ->
        default_runtime_state(entry.normalized_config && entry.normalized_config.worker_port)
    end
  end

  defp maybe_override_pid_from_file(payload, pid_path) do
    case File.read(pid_path) do
      {:ok, raw_pid} ->
        case Integer.parse(String.trim(raw_pid)) do
          {pid, _rest} -> Map.put(payload, "pid", pid)
          :error -> payload
        end

      _other ->
        payload
    end
  end

  defp reconcile_loaded_runtime(runtime_state, runtime_dir) do
    if runtime_state.status in [:running, :starting, :stopping] and is_integer(runtime_state.pid) do
      if process_alive?(runtime_state.pid) do
        persist_runtime(%{runtime_state | status: :running}, runtime_dir)
      else
        runtime_state
        |> Map.merge(%{
          status: :stopped,
          pid: nil,
          exit_reason: "worker pid no longer exists",
          error_summary: nil
        })
        |> persist_runtime(runtime_dir)
      end
    else
      persist_runtime(runtime_state, runtime_dir)
    end
  end

  defp persist_runtime(runtime_state, runtime_dir) do
    runtime_state = hydrate_runtime_state(runtime_state)

    File.mkdir_p!(runtime_dir)
    runtime_path = Path.join(runtime_dir, @runtime_filename)
    pid_path = Path.join(runtime_dir, @pid_filename)

    payload = %{
      status: to_string(runtime_state.status),
      pid: runtime_state.pid,
      worker_port: runtime_state.worker_port,
      started_at: format_datetime(runtime_state.started_at),
      exit_code: runtime_state.exit_code,
      exit_reason: runtime_state.exit_reason,
      stdout_path: runtime_state.stdout_path,
      stderr_path: runtime_state.stderr_path,
      error_summary: runtime_state.error_summary,
      health_status: to_string(runtime_state.health_status),
      last_seen_at: format_datetime(runtime_state.last_seen_at),
      last_health_check_at: format_datetime(runtime_state.last_health_check_at),
      last_error: runtime_state.last_error,
      health_check_timeout_ms: runtime_state.health_check_timeout_ms
    }

    File.write!(runtime_path, Jason.encode!(payload))

    if is_integer(runtime_state.pid) do
      File.write!(pid_path, Integer.to_string(runtime_state.pid))
    else
      File.rm(pid_path)
    end

    runtime_state
  end

  defp normalize_loaded_runtime(runtime_state) when is_map(runtime_state) do
    %{
      status: runtime_state |> loaded_runtime_value(:status) |> normalize_status(),
      pid: loaded_runtime_value(runtime_state, :pid),
      worker_port: loaded_runtime_value(runtime_state, :worker_port),
      started_at: runtime_state |> loaded_runtime_value(:started_at) |> parse_datetime(),
      exit_code: loaded_runtime_value(runtime_state, :exit_code),
      exit_reason: loaded_runtime_value(runtime_state, :exit_reason),
      stdout_path: loaded_runtime_value(runtime_state, :stdout_path),
      stderr_path: loaded_runtime_value(runtime_state, :stderr_path),
      error_summary: loaded_runtime_value(runtime_state, :error_summary),
      health_status: runtime_state |> loaded_runtime_value(:health_status) |> normalize_health_status(),
      last_seen_at: runtime_state |> loaded_runtime_value(:last_seen_at) |> parse_datetime(),
      last_health_check_at: runtime_state |> loaded_runtime_value(:last_health_check_at) |> parse_datetime(),
      last_error: loaded_runtime_value(runtime_state, :last_error),
      health_check_timeout_ms:
        runtime_state
        |> loaded_runtime_value(:health_check_timeout_ms)
        |> normalize_health_check_timeout_ms()
    }
  end

  defp loaded_runtime_value(runtime_state, key) do
    Map.get(runtime_state, key) || Map.get(runtime_state, Atom.to_string(key))
  end

  defp default_runtime_state(worker_port \\ nil) do
    %{
      status: :not_started,
      pid: nil,
      worker_port: worker_port,
      started_at: nil,
      exit_code: nil,
      exit_reason: nil,
      stdout_path: nil,
      stderr_path: nil,
      error_summary: nil,
      health_status: :unknown,
      last_seen_at: nil,
      last_health_check_at: nil,
      last_error: nil,
      health_check_timeout_ms: current_health_check_timeout_ms(),
      run_summaries: []
    }
  end

  defp hydrate_runtime_state(runtime_state, worker_port \\ nil) do
    default_runtime_state(worker_port || Map.get(runtime_state, :worker_port))
    |> Map.merge(runtime_state)
    |> Map.update!(:health_check_timeout_ms, &normalize_health_check_timeout_ms/1)
  end

  defp project_runtime_dir(%Entry{normalized_config: %{logs_root: logs_root}}), do: Path.join(logs_root, "control-plane")

  defp project_runtime_dir(%Entry{project_id: project_id}),
    do: Path.join(System.tmp_dir!(), "symphony-project-process-manager-invalid-#{project_id || "unknown"}")

  defp project_runtime_dir(nil), do: Path.join(System.tmp_dir!(), "symphony-project-process-manager-missing")
  defp project_runtime_dir(%ProjectRegistry{} = registry, project_id), do: registry |> ProjectRegistry.find_entry(project_id) |> project_runtime_dir()

  defp default_name do
    Application.get_env(:symphony_elixir, :project_process_manager_name, @default_name)
  end

  defp default_command_builder(%Entry{normalized_config: config}) do
    "./bin/symphony --logs-root #{shell_escape(config.logs_root)} --port #{config.worker_port} #{shell_escape(config.workflow_generated)}"
  end

  defp alive?(name) do
    case GenServer.whereis(name) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _other -> false
    end
  end

  defp process_alive?(pid) when is_integer(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      _other -> false
    end
  end

  defp wait_until_dead(pid, timeout_ms, started_ms \\ System.monotonic_time(:millisecond))

  defp wait_until_dead(pid, timeout_ms, started_ms) do
    cond do
      not process_alive?(pid) ->
        true

      System.monotonic_time(:millisecond) - started_ms >= timeout_ms ->
        false

      true ->
        Process.sleep(50)
        wait_until_dead(pid, timeout_ms, started_ms)
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end

  defp await_startup_outcome(port, os_pid, timeout_ms, started_ms \\ System.monotonic_time(:millisecond))

  defp await_startup_outcome(port, os_pid, timeout_ms, started_ms) do
    receive do
      {^port, {:exit_status, exit_status}} ->
        {:exited, exit_status, exit_reason(exit_status)}

      {^port, {:data, _data}} ->
        await_startup_outcome(port, os_pid, timeout_ms, started_ms)
    after
      25 ->
        cond do
          not port_open?(port) ->
            {exit_code, exit_reason} = await_exit_status(port)
            {:exited, exit_code, exit_reason}

          not process_alive?(os_pid) ->
            {exit_code, exit_reason} = await_exit_status(port)
            {:exited, exit_code, exit_reason}

          System.monotonic_time(:millisecond) - started_ms >= timeout_ms ->
            receive do
              {^port, {:exit_status, exit_status}} ->
                {:exited, exit_status, exit_reason(exit_status)}

              {^port, {:data, _data}} ->
                await_startup_outcome(port, os_pid, timeout_ms, started_ms)
            after
              100 ->
                if process_alive?(os_pid) and port_open?(port) do
                  :running
                else
                  {exit_code, exit_reason} = await_exit_status(port)
                  {:exited, exit_code, exit_reason}
                end
            end

          true ->
            await_startup_outcome(port, os_pid, timeout_ms, started_ms)
        end
    end
  end

  defp await_exit_status(port) when is_port(port) do
    receive do
      {^port, {:exit_status, exit_status}} -> {exit_status, exit_reason(exit_status)}
      {^port, {:data, _data}} -> await_exit_status(port)
    after
      500 -> {nil, nil}
    end
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp normalize_status("not_started"), do: :not_started
  defp normalize_status("starting"), do: :starting
  defp normalize_status("running"), do: :running
  defp normalize_status("stopping"), do: :stopping
  defp normalize_status("stopped"), do: :stopped
  defp normalize_status("crashed"), do: :crashed
  defp normalize_status("start_failed"), do: :start_failed
  defp normalize_status("disabled"), do: :disabled
  defp normalize_status("config_invalid"), do: :config_invalid
  defp normalize_status(value) when is_binary(value), do: :not_started

  defp normalize_health_status(value) when is_atom(value), do: value
  defp normalize_health_status("healthy"), do: :healthy
  defp normalize_health_status("degraded"), do: :degraded
  defp normalize_health_status("unreachable"), do: :unreachable
  defp normalize_health_status("unknown"), do: :unknown
  defp normalize_health_status(_value), do: :unknown

  defp normalize_health_check_timeout_ms(value) when is_integer(value) and value > 0, do: value
  defp normalize_health_check_timeout_ms(_value), do: current_health_check_timeout_ms()

  defp current_health_check_timeout_ms do
    Config.settings!().control_plane.health_check_timeout_ms
  end

  defp update_health_runtime(state, project_id, updater) do
    registry = project_static_registry()

    case find_entry(registry, project_id) do
      {:error, _reason} ->
        state

      {:ok, entry} ->
        runtime_state =
          Map.get(
            state.runtimes,
            project_id,
            default_runtime_state(entry.normalized_config && entry.normalized_config.worker_port)
          )
          |> hydrate_runtime_state(entry.normalized_config && entry.normalized_config.worker_port)

        next_runtime =
          runtime_state
          |> updater.()
          |> persist_runtime(project_runtime_dir(entry))

        %{state | runtimes: Map.put(state.runtimes, project_id, next_runtime)}
    end
  end

  defp health_success_state(runtime_state, observed_at) do
    case runtime_state.status do
      :running ->
        runtime_state
        |> Map.merge(%{
          health_status: :healthy,
          last_seen_at: observed_at,
          last_health_check_at: observed_at,
          last_error: nil
        })

      _other ->
        %{runtime_state | last_health_check_at: observed_at}
    end
  end

  defp health_failure_state(runtime_state, observed_at, error) do
    next_runtime =
      runtime_state
      |> Map.merge(%{
        last_health_check_at: observed_at,
        last_error: error
      })

    case runtime_state.status do
      :running ->
        reference_time = runtime_state.last_seen_at || runtime_state.started_at

        if timed_out?(reference_time, observed_at, runtime_state.health_check_timeout_ms) do
          %{next_runtime | health_status: :unreachable}
        else
          %{next_runtime | health_status: :degraded}
        end

      _other ->
        next_runtime
    end
  end

  defp timed_out?(nil, _observed_at, _timeout_ms), do: true

  defp timed_out?(%DateTime{} = reference_time, %DateTime{} = observed_at, timeout_ms) do
    DateTime.diff(observed_at, reference_time, :millisecond) >= timeout_ms
  end

  defp exit_reason(0), do: "worker exited with status 0"
  defp exit_reason(status), do: "worker exited with status #{status}"

  defp port_open?(port) when is_port(port), do: Port.info(port) != nil

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end
end
