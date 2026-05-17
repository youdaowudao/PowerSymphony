defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety, RunTrace, SSH}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"
  @remote_json_marker "__SYMPHONY_JSON__"
  @remote_path_marker "__SYMPHONY_PATH__"
  @resource_binding_file ".symphony-resource.json"
  @invalidation_record_file ".symphony-invalidation.json"

  @type worker_host :: String.t() | nil

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host),
           :ok <- validate_workspace_binding_takeover(workspace, issue_context, worker_host, created?),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?, worker_host),
           :ok <- bind_workspace_resource(workspace, issue_context, worker_host) do
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace, nil) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_workspace(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  defp validate_workspace_binding_takeover(workspace, issue_context, nil, created?)
       when is_binary(workspace) and is_map(issue_context) do
    case read_resource_binding(workspace) do
      {:ok, binding} ->
        invalidation = read_optional_json(invalidation_record_path(workspace), nil)

        if resource_binding_takeover_allowed?(binding, invalidation, issue_context.run_instance_id) do
          :ok
        else
          {:error, {:workspace_resource_owned_by_other_run, binding}}
        end

      {:error, :enoent} ->
        allow_unbound_workspace?(workspace, nil, created?)

      {:error, :enotdir} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_workspace_binding_takeover(workspace, issue_context, worker_host, created?)
       when is_binary(workspace) and is_map(issue_context) and is_binary(worker_host) do
    case read_resource_binding(workspace, worker_host) do
      {:ok, binding} ->
        invalidation = read_optional_json(invalidation_record_path(workspace), worker_host)

        if resource_binding_takeover_allowed?(binding, invalidation, issue_context.run_instance_id) do
          :ok
        else
          {:error, {:workspace_resource_owned_by_other_run, binding}}
        end

      {:error, :enoent} ->
        allow_unbound_workspace?(workspace, worker_host, created?)

      {:error, :enotdir} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp bind_workspace_resource(workspace, issue_context, nil) when is_binary(workspace) and is_map(issue_context) do
    binding =
      case read_resource_binding(workspace) do
        {:ok, existing_binding} -> existing_binding
        _ -> nil
      end

    binding
    |> merge_active_resource_binding(workspace, issue_context, nil)
    |> write_resource_binding(workspace)

    clear_invalidation_record(workspace)
    :ok
  end

  defp bind_workspace_resource(workspace, issue_context, worker_host)
       when is_binary(workspace) and is_map(issue_context) and is_binary(worker_host) do
    binding =
      case read_resource_binding(workspace, worker_host) do
        {:ok, existing_binding} -> existing_binding
        _ -> nil
      end

    binding
    |> merge_active_resource_binding(workspace, issue_context, worker_host)
    |> write_resource_binding(workspace, worker_host)

    clear_invalidation_record(workspace, worker_host)
    :ok
  end

  defp allow_unbound_workspace?(_workspace, _worker_host, true), do: :ok

  defp allow_unbound_workspace?(workspace, worker_host, false) do
    {:error,
     {:workspace_resource_owned_by_other_run,
      %{
        "workspace_path" => workspace,
        "worker_host" => worker_host,
        "state" => "preparing",
        "run_instance_id" => nil
      }}}
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, nil) do
          :ok ->
            maybe_run_before_remove_hook(workspace, nil)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    maybe_run_before_remove_hook(workspace, worker_host)

    script =
      [
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(identifier, worker_host) when is_binary(identifier) and is_binary(worker_host) do
    safe_id = safe_identifier(identifier)

    case workspace_path_for_issue(safe_id, worker_host) do
      {:ok, workspace} ->
        remove_legacy_issue_workspace(identifier, workspace, worker_host)

      {:error, _reason} ->
        :ok
    end

    :ok
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        remove_local_issue_workspace(identifier)

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(identifier, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host) do
    :ok
  end

  defp remove_local_issue_workspace(identifier) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)

    case workspace_path_for_issue(safe_id, nil) do
      {:ok, workspace} -> remove_legacy_issue_workspace(identifier, workspace, nil)
      {:error, _reason} -> :ok
    end
  end

  defp remove_legacy_issue_workspace(identifier, workspace, worker_host)
       when is_binary(identifier) and is_binary(workspace) do
    if lifecycle_metadata_present?(workspace, worker_host) do
      cleanup_issue_workspace(identifier,
        worker_host: worker_host,
        mode: :terminal_cleanup,
        delete_evidence: :no_live_owner,
        closing_reason: "legacy_remove_issue_workspaces"
      )
    else
      remove(workspace, worker_host)
      :ok
    end
  end

  @spec cleanup_issue_workspace(String.t(), keyword()) :: :ok
  def cleanup_issue_workspace(identifier, opts \\ []) when is_binary(identifier) do
    worker_host = Keyword.get(opts, :worker_host)
    mode = Keyword.get(opts, :mode, :terminal_cleanup)
    run_instance_id = Keyword.get(opts, :run_instance_id)
    closing_reason = Keyword.get(opts, :closing_reason, to_string(mode))
    delete_evidence = Keyword.get(opts, :delete_evidence, :none)
    safe_id = safe_identifier(identifier)

    case workspace_path_for_issue(safe_id, worker_host) do
      {:ok, workspace} ->
        fenced_cleanup_workspace(
          workspace,
          identifier,
          worker_host,
          mode,
          run_instance_id,
          closing_reason,
          delete_evidence
        )

      {:error, _reason} ->
        :ok
    end
  end

  @spec read_resource_binding(Path.t()) :: {:ok, map()} | {:error, term()}
  def read_resource_binding(workspace) when is_binary(workspace) do
    workspace
    |> resource_binding_path()
    |> read_json_file()
  end

  @spec read_resource_binding(Path.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def read_resource_binding(workspace, worker_host)
      when is_binary(workspace) and is_binary(worker_host) do
    workspace
    |> resource_binding_path()
    |> read_remote_json_file(worker_host)
  end

  @spec workspace_lifecycle_info(Path.t(), worker_host()) :: map()
  def workspace_lifecycle_info(workspace, worker_host \\ nil) when is_binary(workspace) do
    %{
      binding: read_optional_json(resource_binding_path(workspace), worker_host),
      invalidation: read_optional_json(invalidation_record_path(workspace), worker_host)
    }
  end

  @spec validate_workspace_owner(Path.t(), String.t() | nil, worker_host()) ::
          :ok | {:error, {:workspace_lifecycle_invalid, map()}}
  def validate_workspace_owner(workspace, run_instance_id, worker_host \\ nil) when is_binary(workspace) do
    %{binding: binding, invalidation: invalidation} = workspace_lifecycle_info(workspace, worker_host)

    case workspace_lifecycle_error(binding, invalidation, run_instance_id, workspace) do
      nil -> :ok
      error -> error
    end
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host)
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host)
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    Config.settings!().workspace.root
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host) when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(Config.settings!().workspace.root, safe_id)}
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
    hooks = Config.settings!().hooks

    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create", worker_host)
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, nil) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove",
              nil
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host) when is_binary(worker_host) do
    hooks = Config.settings!().hooks

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        script =
          [
            remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms)
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
        |> ignore_hook_failure()
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, nil) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    RunTrace.record(:workspace_hook, %{
      event: :hook_started,
      summary: "workspace_hook:#{hook_name}:started",
      payload: %{hook_name: hook_name, workspace: workspace}
    })

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        RunTrace.record(:workspace_hook, %{
          event: :hook_timed_out,
          summary: "workspace_hook:#{hook_name}:timed_out",
          payload: %{hook_name: hook_name, timeout_ms: timeout_ms, workspace: workspace}
        })

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host) when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    RunTrace.record(:workspace_hook, %{
      event: :hook_started,
      summary: "workspace_hook:#{hook_name}:started",
      payload: %{hook_name: hook_name, workspace: workspace, worker_host: worker_host}
    })

    case run_remote_command(worker_host, "cd #{shell_escape(workspace)} && #{command}", timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, _name, timeout_ms} = reason} ->
        RunTrace.record(:workspace_hook, %{
          event: :hook_timed_out,
          summary: "workspace_hook:#{hook_name}:timed_out",
          payload: %{hook_name: hook_name, timeout_ms: timeout_ms, workspace: workspace, worker_host: worker_host}
        })

        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_hook_command_result({_output, 0}, workspace, _issue_id, hook_name) do
    RunTrace.record(:workspace_hook, %{
      event: :hook_succeeded,
      summary: "workspace_hook:#{hook_name}:succeeded",
      payload: %{hook_name: hook_name, workspace: workspace}
    })

    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    RunTrace.record(:workspace_hook, %{
      event: :hook_failed,
      summary: "workspace_hook:#{hook_name}:failed",
      payload: %{hook_name: hook_name, workspace: workspace, status: status, output: output}
    })

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_path(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp fenced_cleanup_workspace(
         workspace,
         identifier,
         worker_host,
         mode,
         run_instance_id,
         closing_reason,
         delete_evidence
       ) do
    binding = read_optional_json(resource_binding_path(workspace), worker_host)
    invalidation = read_optional_json(invalidation_record_path(workspace), worker_host)
    workspace_exists? = workspace_present?(workspace, worker_host)

    cond do
      active_binding_owned_by_other_run?(binding, run_instance_id) ->
        if mode == :startup_sweep do
          maybe_record_startup_reap_candidate(
            workspace,
            identifier,
            worker_host,
            run_instance_id,
            binding,
            invalidation,
            delete_evidence
          )
        end

        :ok

      workspace_exists? and mode == :startup_sweep ->
        handle_startup_sweep_cleanup(
          workspace,
          identifier,
          worker_host,
          run_instance_id,
          binding,
          invalidation,
          delete_evidence
        )

        :ok

      workspace_exists? ->
        closing_binding =
          merge_closing_resource_binding(binding, workspace, identifier, worker_host, run_instance_id, closing_reason)

        write_resource_binding(closing_binding, workspace, worker_host)

        write_invalidation_record(
          workspace,
          worker_host,
          build_invalidation_record(
            closing_binding,
            identifier,
            run_instance_id,
            workspace,
            worker_host,
            closing_reason
          )
        )

        maybe_delete_workspace(
          workspace,
          identifier,
          worker_host,
          mode,
          run_instance_id,
          closing_binding,
          invalidation,
          delete_evidence
        )

        :ok

      delete_allowed?(mode, binding, invalidation, delete_evidence) ->
        maybe_delete_workspace(
          workspace,
          identifier,
          worker_host,
          mode,
          run_instance_id,
          binding,
          invalidation,
          delete_evidence
        )

        :ok

      true ->
        :ok
    end
  end

  defp handle_startup_sweep_cleanup(
         workspace,
         identifier,
         worker_host,
         run_instance_id,
         binding,
         invalidation,
         delete_evidence
       ) do
    if delete_allowed?(:startup_sweep, binding, invalidation, delete_evidence) do
      handle_authorized_startup_sweep_cleanup(
        workspace,
        identifier,
        worker_host,
        run_instance_id,
        binding,
        invalidation,
        delete_evidence
      )
    else
      maybe_record_startup_reap_candidate(
        workspace,
        identifier,
        worker_host,
        run_instance_id,
        binding,
        invalidation,
        delete_evidence
      )
    end
  end

  defp handle_authorized_startup_sweep_cleanup(
         workspace,
         identifier,
         worker_host,
         run_instance_id,
         binding,
         invalidation,
         delete_evidence
       ) do
    deleted? =
      maybe_delete_workspace(
        workspace,
        identifier,
        worker_host,
        :startup_sweep,
        run_instance_id,
        binding,
        invalidation,
        delete_evidence
      )

    if not deleted? do
      write_invalidation_record(
        workspace,
        worker_host,
        build_invalidation_record(
          binding,
          identifier,
          run_instance_id,
          workspace,
          worker_host,
          "startup_reap_ambiguous"
        )
      )
    end
  end

  defp maybe_delete_workspace(
         workspace,
         identifier,
         worker_host,
         mode,
         run_instance_id,
         binding,
         invalidation,
         delete_evidence
       ) do
    if delete_allowed?(mode, binding, invalidation, delete_evidence) do
      prepare_workspace_for_delete(workspace, identifier, worker_host, mode, run_instance_id, binding)
      remove_workspace_with_cleanup(workspace, worker_host)
    else
      false
    end
  end

  defp prepare_workspace_for_delete(workspace, identifier, worker_host, :startup_sweep, run_instance_id, binding) do
    removed_pending_binding =
      merge_removed_pending_resource_binding(binding, workspace, identifier, worker_host, run_instance_id)

    write_resource_binding(removed_pending_binding, workspace, worker_host)

    write_invalidation_record(
      workspace,
      worker_host,
      build_invalidation_record(binding, identifier, run_instance_id, workspace, worker_host, "workspace_removed")
    )
  end

  defp prepare_workspace_for_delete(_workspace, _identifier, _worker_host, _mode, _run_instance_id, _binding), do: :ok

  defp remove_workspace_with_cleanup(workspace, worker_host) do
    case remove(workspace, worker_host) do
      {:ok, _} ->
        clear_invalidation_record(workspace, worker_host)
        true

      {:error, _reason, _output} ->
        false
    end
  end

  defp delete_allowed?(:startup_sweep, binding, invalidation, delete_evidence),
    do:
      delete_evidence == :startup_no_live_owner and
        startup_reap_evidence?(binding, invalidation)

  defp delete_allowed?(:terminal_cleanup, binding, _invalidation, delete_evidence),
    do: removable_binding_state?(binding) and delete_evidence in [:no_live_owner, :task_down_confirmed]

  defp delete_allowed?(_mode, _binding, _invalidation, _delete_evidence), do: false

  defp removable_binding_state?(%{"state" => state}) when state in ["active", "closing", "removed-pending"],
    do: true

  defp removable_binding_state?(_binding), do: false

  defp removed_pending_binding?(%{"state" => "removed-pending"}), do: true
  defp removed_pending_binding?(_binding), do: false

  defp active_binding_owned_by_other_run?(%{"state" => "active"} = binding, run_instance_id) do
    binding_run_instance_id = Map.get(binding, "run_instance_id")
    not same_run_instance_id?(binding_run_instance_id, run_instance_id)
  end

  defp active_binding_owned_by_other_run?(_binding, _run_instance_id), do: false

  defp resource_binding_takeover_allowed?(%{"state" => "active"} = binding, _invalidation, run_instance_id) do
    same_run_instance_id?(Map.get(binding, "run_instance_id"), run_instance_id)
  end

  defp resource_binding_takeover_allowed?(%{"state" => "closing"} = binding, invalidation, run_instance_id) do
    same_run_instance_id?(Map.get(binding, "run_instance_id"), run_instance_id) or
      false_closing_takeover_guard(binding, invalidation)
  end

  defp resource_binding_takeover_allowed?(%{"state" => "removed-pending"} = binding, invalidation, run_instance_id) do
    same_run_instance_id?(Map.get(binding, "run_instance_id"), run_instance_id) or
      stale_removed_binding?(binding, invalidation)
  end

  defp resource_binding_takeover_allowed?(_binding, _invalidation, _run_instance_id), do: false

  defp stale_removed_binding?(binding, invalidation) when is_map(binding) and is_map(invalidation) do
    Map.get(binding, "state") == "removed-pending" and
      matching_invalidation_scope?(binding, invalidation) and
      Map.get(invalidation, "reason") == "workspace_removed"
  end

  defp stale_removed_binding?(_binding, _invalidation), do: false

  defp matching_invalidation_scope?(binding, invalidation) do
    Map.get(invalidation, "issue_identifier") == Map.get(binding, "issue_identifier") and
      Map.get(invalidation, "run_instance_id") == Map.get(binding, "run_instance_id") and
      Map.get(invalidation, "workspace_path") == Map.get(binding, "workspace_path")
  end

  defp startup_reap_evidence?(binding, invalidation) do
    removed_pending_binding?(binding) and
      matching_invalidation_scope?(binding, invalidation) and
      Map.get(invalidation, "reason") == "workspace_removed"
  end

  defp lifecycle_metadata_present?(workspace, worker_host) do
    is_map(read_optional_json(resource_binding_path(workspace), worker_host)) or
      is_map(read_optional_json(invalidation_record_path(workspace), worker_host))
  end

  defp maybe_record_startup_reap_candidate(
         workspace,
         identifier,
         worker_host,
         run_instance_id,
         binding,
         invalidation,
         delete_evidence
       ) do
    if delete_evidence == :startup_no_live_owner and removable_binding_state?(binding) and
         not delete_allowed?(:startup_sweep, binding, invalidation, delete_evidence) do
      write_invalidation_record(
        workspace,
        worker_host,
        build_invalidation_record(
          binding,
          identifier,
          run_instance_id,
          workspace,
          worker_host,
          "startup_reap_ambiguous"
        )
      )
    else
      :ok
    end
  end

  defp false_closing_takeover_guard(_binding, _invalidation), do: false

  defp same_run_instance_id?(binding_run_instance_id, run_instance_id)
       when is_binary(binding_run_instance_id) and is_binary(run_instance_id) do
    binding_run_instance_id == run_instance_id
  end

  defp same_run_instance_id?(nil, nil), do: true
  defp same_run_instance_id?(binding_run_instance_id, run_instance_id), do: binding_run_instance_id == run_instance_id

  defp binding_lifecycle_error(%{"state" => "active"} = binding, run_instance_id, workspace) do
    if same_run_instance_id?(Map.get(binding, "run_instance_id"), run_instance_id) do
      nil
    else
      {:error, {:workspace_lifecycle_invalid, lifecycle_details(:resource_owned_by_other_run, binding, workspace)}}
    end
  end

  defp binding_lifecycle_error(%{"state" => state} = binding, _run_instance_id, workspace)
       when state in ["closing", "removed-pending"] do
    {:error, {:workspace_lifecycle_invalid, lifecycle_details(:resource_closing, binding, workspace)}}
  end

  defp binding_lifecycle_error(_binding, _run_instance_id, _workspace), do: nil

  defp invalidation_lifecycle_error(invalidation, workspace) when is_map(invalidation) do
    {:error,
     {:workspace_lifecycle_invalid,
      %{
        reason: :resource_invalidated,
        run_instance_id: Map.get(invalidation, "run_instance_id"),
        closing_reason: Map.get(invalidation, "reason"),
        binding_state: Map.get(invalidation, "state"),
        workspace_path: Map.get(invalidation, "workspace_path") || workspace
      }}}
  end

  defp invalidation_lifecycle_error(_invalidation, _workspace), do: nil

  defp lifecycle_details(reason, binding, workspace) do
    %{
      reason: reason,
      run_instance_id: Map.get(binding, "run_instance_id"),
      closing_reason: Map.get(binding, "closing_reason"),
      binding_state: Map.get(binding, "state"),
      workspace_path: Map.get(binding, "workspace_path") || workspace
    }
  end

  defp workspace_lifecycle_error(binding, invalidation, run_instance_id, workspace) do
    binding_lifecycle_error(binding, run_instance_id, workspace) ||
      invalidation_lifecycle_error(invalidation, workspace)
  end

  defp merge_active_resource_binding(binding, workspace, issue_context, worker_host) do
    binding = binding || %{}

    %{
      "issue_id" => issue_context.issue_id,
      "issue_identifier" => issue_context.issue_identifier,
      "run_instance_id" => issue_context.run_instance_id,
      "worker_host" => worker_host,
      "workspace_path" => workspace,
      "state" => "active",
      "closing_reason" => nil,
      "inserted_at" => Map.get(binding, "inserted_at") || timestamp_now(),
      "updated_at" => timestamp_now()
    }
  end

  defp merge_closing_resource_binding(binding, workspace, identifier, worker_host, run_instance_id, closing_reason) do
    binding = binding || %{}

    %{
      "issue_id" => Map.get(binding, "issue_id"),
      "issue_identifier" => Map.get(binding, "issue_identifier") || identifier,
      "run_instance_id" => run_instance_id || Map.get(binding, "run_instance_id"),
      "worker_host" => worker_host || Map.get(binding, "worker_host"),
      "workspace_path" => workspace,
      "state" => "closing",
      "closing_reason" => closing_reason,
      "inserted_at" => Map.get(binding, "inserted_at") || timestamp_now(),
      "updated_at" => timestamp_now()
    }
  end

  defp merge_removed_pending_resource_binding(binding, workspace, identifier, worker_host, run_instance_id) do
    binding = binding || %{}

    %{
      "issue_id" => Map.get(binding, "issue_id"),
      "issue_identifier" => Map.get(binding, "issue_identifier") || identifier,
      "run_instance_id" => run_instance_id || Map.get(binding, "run_instance_id"),
      "worker_host" => worker_host || Map.get(binding, "worker_host"),
      "workspace_path" => workspace,
      "state" => "removed-pending",
      "closing_reason" => "workspace_removed",
      "inserted_at" => Map.get(binding, "inserted_at") || timestamp_now(),
      "updated_at" => timestamp_now()
    }
  end

  defp write_resource_binding(binding, workspace, worker_host \\ nil)

  defp write_resource_binding(binding, workspace, nil) when is_map(binding) and is_binary(workspace) do
    write_json_file(resource_binding_path(workspace), binding)
  end

  defp write_resource_binding(binding, workspace, worker_host)
       when is_map(binding) and is_binary(workspace) and is_binary(worker_host) do
    write_remote_json_file(resource_binding_path(workspace), binding, worker_host)
  end

  defp clear_invalidation_record(workspace, worker_host \\ nil)

  defp clear_invalidation_record(workspace, nil) when is_binary(workspace) do
    case File.rm(invalidation_record_path(workspace)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp clear_invalidation_record(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("file", invalidation_record_path(workspace)),
        "rm -f \"$file\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {_output, _status}} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp resource_binding_path(workspace) when is_binary(workspace),
    do: Path.join(workspace, @resource_binding_file)

  defp invalidation_record_path(workspace) when is_binary(workspace),
    do: Path.join(workspace, @invalidation_record_file)

  defp read_optional_json(path, nil) when is_binary(path) do
    case read_json_file(path) do
      {:ok, payload} -> payload
      {:error, _reason} -> nil
    end
  end

  defp read_optional_json(path, worker_host) when is_binary(path) and is_binary(worker_host) do
    case read_remote_json_file(path, worker_host) do
      {:ok, payload} -> payload
      {:error, _reason} -> nil
    end
  end

  defp read_json_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{} = payload} -> {:ok, payload}
          {:ok, other} -> {:error, {:invalid_resource_json, path, other}}
          {:error, reason} -> {:error, {:invalid_resource_json, path, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_json_file(path, payload) when is_binary(path) and is_map(payload) do
    temp_path = path <> ".tmp"
    encoded = Jason.encode_to_iodata!(payload)
    File.write!(temp_path, encoded)
    File.rename!(temp_path, path)
    :ok
  end

  defp workspace_present?(workspace, nil) when is_binary(workspace), do: File.exists?(workspace)

  defp workspace_present?(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    case remote_path_exists?(workspace, worker_host) do
      {:ok, exists?} -> exists?
      {:error, _reason} -> false
    end
  end

  defp build_invalidation_record(binding, identifier, run_instance_id, workspace, worker_host, reason) do
    %{
      "issue_id" => Map.get(binding || %{}, "issue_id"),
      "issue_identifier" => Map.get(binding || %{}, "issue_identifier") || identifier,
      "run_instance_id" => run_instance_id || Map.get(binding || %{}, "run_instance_id"),
      "worker_host" => worker_host || Map.get(binding || %{}, "worker_host"),
      "workspace_path" => workspace,
      "state" => Map.get(binding || %{}, "state"),
      "reason" => reason,
      "updated_at" => timestamp_now()
    }
  end

  defp write_invalidation_record(workspace, nil, payload) when is_binary(workspace) and is_map(payload) do
    write_json_file(invalidation_record_path(workspace), payload)
  end

  defp write_invalidation_record(workspace, worker_host, payload)
       when is_binary(workspace) and is_binary(worker_host) and is_map(payload) do
    write_remote_json_file(invalidation_record_path(workspace), payload, worker_host)
  end

  defp read_remote_json_file(path, worker_host) when is_binary(path) and is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("file", path),
        "if [ -f \"$file\" ]; then",
        "  printf '%s\\t1\\t' '#{@remote_json_marker}'",
        "  cat \"$file\"",
        "  printf '\\n'",
        "else",
        "  printf '%s\\t0\\n' '#{@remote_json_marker}'",
        "fi"
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_json_output(output, path)

      {:ok, {output, status}} ->
        {:error, {:remote_json_read_failed, worker_host, path, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_remote_json_file(path, payload, worker_host)
       when is_binary(path) and is_map(payload) and is_binary(worker_host) do
    encoded = Jason.encode!(payload)

    script =
      [
        "set -eu",
        remote_shell_assign("file", path),
        "dir=$(dirname \"$file\")",
        "mkdir -p \"$dir\"",
        "tmp=\"$file.tmp.$$\"",
        "printf '%s' #{shell_escape(encoded)} > \"$tmp\"",
        "mv \"$tmp\" \"$file\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> {:error, {:remote_json_write_failed, worker_host, path, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remote_path_exists?(path, worker_host) when is_binary(path) and is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("target", path),
        "if [ -e \"$target\" ]; then",
        "  printf '%s\\t1\\n' '#{@remote_path_marker}'",
        "else",
        "  printf '%s\\t0\\n' '#{@remote_path_marker}'",
        "fi"
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} -> parse_remote_exists_output(output)
      {:ok, {output, status}} -> {:error, {:remote_path_exists_failed, worker_host, path, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_remote_json_output(output, path) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    case Enum.find_value(lines, &parse_remote_json_line/1) do
      {:payload, payload} -> decode_remote_json_payload(payload, path)
      :missing -> {:error, :enoent}
      marker -> remote_json_marker_result(marker, path, output)
    end
  end

  defp parse_remote_exists_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    case Enum.find_value(lines, &parse_remote_exists_line/1) do
      {:ok, exists?} -> {:ok, exists?}
      marker -> remote_exists_marker_result(marker, output)
    end
  end

  defp parse_remote_json_line(line) do
    case String.split(line, "\t", parts: 3) do
      [@remote_json_marker, "1", payload] -> {:payload, payload}
      [@remote_json_marker, "0"] -> :missing
      _ -> nil
    end
  end

  defp parse_remote_exists_line(line) do
    case String.split(line, "\t", parts: 2) do
      [@remote_path_marker, "1"] -> {:ok, true}
      [@remote_path_marker, "0"] -> {:ok, false}
      _ -> nil
    end
  end

  defp decode_remote_json_payload(payload, path) do
    case Jason.decode(payload) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      {:ok, other} -> {:error, {:invalid_resource_json, path, other}}
      {:error, reason} -> {:error, {:invalid_resource_json, path, reason}}
    end
  end

  defp remote_json_marker_result(_marker, path, output) do
    {:error, {:remote_json_read_failed, :invalid_output, path, output}}
  end

  defp remote_exists_marker_result(_marker, output) do
    {:error, {:remote_path_exists_failed, :invalid_output, output}}
  end

  defp timestamp_now do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  defp issue_context(%{id: issue_id, identifier: identifier, run_instance_id: run_instance_id}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      run_instance_id: run_instance_id
    }
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      run_instance_id: nil
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier,
      run_instance_id: nil
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue",
      run_instance_id: nil
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
