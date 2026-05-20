defmodule SymphonyElixir.ProjectWorkflowGenerator do
  @moduledoc false

  alias SymphonyElixir.{ProjectConfig, Workflow}

  @spec generate(ProjectConfig.t()) :: :ok | {:error, term()}
  def generate(%ProjectConfig{} = project) do
    with {:ok, source_path} <- require_field(project.workflow_source, :missing_workflow_source),
         {:ok, project_slug} <- require_field(project.project_slug, :missing_project_slug),
         {:ok, repo_url} <- require_field(project.repo_url, :missing_repo_url),
         {:ok, %{config: workflow_config, prompt_template: prompt}} <- Workflow.load(source_path) do
      generated_config =
        workflow_config
        |> put_nested(["tracker", "project_slug"], project_slug)
        |> put_nested(["workspace", "root"], project.workspace_root)
        |> put_nested(["hooks", "after_create"], rewrite_after_create(get_in(workflow_config, ["hooks", "after_create"]), repo_url))

      write_generated_workflow(project.workflow_generated, generated_config, prompt)
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp require_field(value, _reason) when is_binary(value) and byte_size(value) > 0, do: {:ok, value}
  defp require_field(_value, reason), do: {:error, reason}

  defp put_nested(config, [key], value) when is_map(config) do
    Map.put(config, key, value)
  end

  defp put_nested(config, [key | rest], value) when is_map(config) do
    nested =
      case Map.get(config, key) do
        current when is_map(current) -> current
        _other -> %{}
      end

    Map.put(config, key, put_nested(nested, rest, value))
  end

  defp rewrite_after_create(existing, repo_url) when is_binary(existing) do
    clone_command = clone_command(repo_url)

    body_lines =
      existing
      |> String.split("\n", trim: false)
      |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "git clone --depth 1 "))

    case body_lines do
      [] ->
        clone_command

      _rest ->
        Enum.join([clone_command | body_lines], "\n")
    end
  end

  defp rewrite_after_create(_existing, repo_url), do: clone_command(repo_url)

  defp clone_command(repo_url), do: "git clone --depth 1 #{repo_url} ."

  defp write_generated_workflow(path, config, prompt) do
    File.mkdir_p!(Path.dirname(path))

    content =
      [
        "---\n",
        Jason.encode!(config),
        "\n---\n\n",
        String.trim_trailing(prompt),
        "\n"
      ]
      |> IO.iodata_to_binary()

    File.write(path, content)
  end
end
