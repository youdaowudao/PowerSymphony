defmodule Mix.Tasks.Workspace.BeforeRemove do
  use Mix.Task

  @shortdoc "Close open GitHub PRs for the current branch before workspace removal"

  @moduledoc """
  Closes open pull requests for the current Git branch.

  This task is intended for use from the `before_remove` workspace hook.

  Usage:

      mix workspace.before_remove
      mix workspace.before_remove --branch feature/my-branch
      mix workspace.before_remove --repo openai/symphony
  """

  @default_repo "openai/symphony"
  @github_api_script Path.expand("../../../../.codex/skills/github_api.py", __DIR__)

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [branch: :string, help: :boolean, repo: :string],
        aliases: [h: :help]
      )

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        repo = opts[:repo] || @default_repo
        branch = opts[:branch] || current_branch()

        maybe_close_open_pull_requests(repo, branch)
    end
  end

  defp maybe_close_open_pull_requests(_repo, nil), do: :ok

  defp maybe_close_open_pull_requests(repo, branch) do
    if github_helper_available?() do
      repo
      |> list_open_pull_request_numbers(branch)
      |> Enum.each(&close_pull_request(repo, branch, &1))
    end

    :ok
  end

  defp github_helper_available? do
    File.exists?(@github_api_script) and not is_nil(System.find_executable("python3"))
  end

  defp list_open_pull_request_numbers(repo, branch) do
    case run_github_helper([
           "list-prs",
           "--repo",
           repo,
           "--branch",
           branch,
           "--state",
           "open"
         ]) do
      {:ok, output} ->
        decode_pull_request_numbers(output)

      {:error, _reason} ->
        []
    end
  end

  defp decode_pull_request_numbers(output) do
    case Jason.decode(output) do
      {:ok, prs} when is_list(prs) ->
        Enum.map(prs, fn pr -> to_string(pr["number"]) end)

      _ ->
        []
    end
  end

  defp close_pull_request(repo, branch, pr_number) do
    case run_github_helper([
           "close-pr",
           "--repo",
           repo,
           "--number",
           pr_number,
           "--comment",
           closing_comment(branch)
         ]) do
      {:ok, _output} ->
        Mix.shell().info("Closed PR ##{pr_number} for branch #{branch}")

      {:error, {status, output}} ->
        trimmed_output = String.trim(output)

        Mix.shell().error("Failed to close PR ##{pr_number} for branch #{branch}: exit #{status}#{format_output(trimmed_output)}")
    end
  end

  defp closing_comment(branch) do
    "Closing because the Linear issue for branch #{branch} entered a terminal state without merge."
  end

  defp format_output(""), do: ""
  defp format_output(output), do: " output=#{inspect(output)}"

  defp current_branch do
    case run_command("git", ["branch", "--show-current"]) do
      {:ok, output} ->
        case String.trim(output) do
          "" -> nil
          branch -> branch
        end

      {:error, _reason} ->
        nil
    end
  end

  defp run_github_helper(args) do
    run_command("python3", [@github_api_script | args])
  end

  defp run_command(command, args) do
    case System.find_executable(command) do
      nil ->
        {:error, {:enoent, ""}}

      path ->
        case System.cmd(path, args, stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {output, status} -> {:error, {status, output}}
        end
    end
  end
end
