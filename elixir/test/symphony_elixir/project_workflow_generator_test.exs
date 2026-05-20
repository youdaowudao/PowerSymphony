defmodule SymphonyElixir.ProjectWorkflowGeneratorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{ProjectConfig, ProjectWorkflowGenerator, Workflow}

  setup do
    tmp_dir = temp_root!()
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  test "generates a workflow with project-specific bindings and preserves the prompt body", %{tmp_dir: tmp_dir} do
    source_path = Path.join(tmp_dir, "source/WORKFLOW.md")
    output_path = Path.join(tmp_dir, "generated/alpha/WORKFLOW.generated.md")

    File.mkdir_p!(Path.dirname(source_path))

    write_workflow_file!(source_path,
      tracker_project_slug: "source-project",
      workspace_root: Path.join(tmp_dir, "source-workspace"),
      hook_after_create: "git clone --depth 1 https://example.com/source.git .\ncd elixir && mise exec -- mix deps.get",
      prompt: "Prompt line 1\nPrompt line 2"
    )

    project =
      project_config(
        "alpha",
        4101,
        source_path,
        output_path,
        Path.join(tmp_dir, "workspaces/alpha"),
        Path.join(tmp_dir, "logs/alpha"),
        "slug-alpha",
        "https://example.com/alpha.git"
      )

    assert :ok = ProjectWorkflowGenerator.generate(project)
    assert File.regular?(output_path)

    assert {:ok, %{config: generated_config, prompt: prompt}} = Workflow.load(output_path)

    assert get_in(generated_config, ["tracker", "project_slug"]) == "slug-alpha"
    assert get_in(generated_config, ["workspace", "root"]) == Path.join(tmp_dir, "workspaces/alpha")
    assert get_in(generated_config, ["hooks", "after_create"]) =~ "git clone --depth 1 https://example.com/alpha.git ."
    assert get_in(generated_config, ["hooks", "after_create"]) =~ "mise exec -- mix deps.get"
    refute get_in(generated_config, ["hooks", "after_create"]) =~ "https://example.com/source.git"
    assert String.trim(prompt) == "Prompt line 1\nPrompt line 2"
  end

  test "keeps generated workflows isolated across projects", %{tmp_dir: tmp_dir} do
    source_path = Path.join(tmp_dir, "source/WORKFLOW.md")
    alpha_output = Path.join(tmp_dir, "generated/alpha/WORKFLOW.generated.md")
    beta_output = Path.join(tmp_dir, "generated/beta/WORKFLOW.generated.md")

    File.mkdir_p!(Path.dirname(source_path))

    write_workflow_file!(source_path,
      tracker_project_slug: "source-project",
      workspace_root: Path.join(tmp_dir, "source-workspace"),
      hook_after_create: "git clone --depth 1 https://example.com/source.git .",
      prompt: "Shared prompt body"
    )

    alpha =
      project_config(
        "alpha",
        4101,
        source_path,
        alpha_output,
        Path.join(tmp_dir, "workspaces/alpha"),
        Path.join(tmp_dir, "logs/alpha"),
        "slug-alpha",
        "https://example.com/alpha.git"
      )

    beta =
      project_config(
        "beta",
        4102,
        source_path,
        beta_output,
        Path.join(tmp_dir, "workspaces/beta"),
        Path.join(tmp_dir, "logs/beta"),
        "slug-beta",
        "https://example.com/beta.git"
      )

    assert :ok = ProjectWorkflowGenerator.generate(alpha)
    assert :ok = ProjectWorkflowGenerator.generate(beta)

    assert {:ok, %{config: alpha_config}} = Workflow.load(alpha_output)
    assert {:ok, %{config: beta_config}} = Workflow.load(beta_output)

    assert get_in(alpha_config, ["tracker", "project_slug"]) == "slug-alpha"
    assert get_in(beta_config, ["tracker", "project_slug"]) == "slug-beta"
    assert get_in(alpha_config, ["workspace", "root"]) == Path.join(tmp_dir, "workspaces/alpha")
    assert get_in(beta_config, ["workspace", "root"]) == Path.join(tmp_dir, "workspaces/beta")
    assert get_in(alpha_config, ["hooks", "after_create"]) =~ "https://example.com/alpha.git"
    assert get_in(beta_config, ["hooks", "after_create"]) =~ "https://example.com/beta.git"
    refute File.read!(alpha_output) == File.read!(beta_output)
  end

  test "returns missing input errors before generation starts", %{tmp_dir: tmp_dir} do
    source_path = Path.join(tmp_dir, "source/WORKFLOW.md")
    output_path = Path.join(tmp_dir, "generated/alpha/WORKFLOW.generated.md")

    File.mkdir_p!(Path.dirname(source_path))
    write_workflow_file!(source_path)

    project =
      project_config(
        "alpha",
        4101,
        source_path,
        output_path,
        Path.join(tmp_dir, "workspaces/alpha"),
        Path.join(tmp_dir, "logs/alpha"),
        "slug-alpha",
        "https://example.com/alpha.git"
      )

    assert {:error, :missing_workflow_source} =
             ProjectWorkflowGenerator.generate(%{project | workflow_source: nil})

    assert {:error, :missing_project_slug} =
             ProjectWorkflowGenerator.generate(%{project | project_slug: nil})

    assert {:error, :missing_repo_url} =
             ProjectWorkflowGenerator.generate(%{project | repo_url: nil})

    refute File.regular?(output_path)
  end

  test "repository workflow template does not hardcode project-level bindings" do
    workflow_path = Path.expand("../../WORKFLOW.md", __DIR__)
    body = File.read!(workflow_path)

    refute body =~ ~s(project_slug: "03b2b4a16461")
    refute body =~ "https://github.com/youdaowudao/PowerSymphony.git"
  end

  test "returns workflow load errors when the source workflow cannot be read", %{tmp_dir: tmp_dir} do
    source_path = Path.join(tmp_dir, "missing/WORKFLOW.md")
    output_path = Path.join(tmp_dir, "generated/alpha/WORKFLOW.generated.md")

    project =
      project_config(
        "alpha",
        4101,
        source_path,
        output_path,
        Path.join(tmp_dir, "workspaces/alpha"),
        Path.join(tmp_dir, "logs/alpha"),
        "slug-alpha",
        "https://example.com/alpha.git"
      )

    assert {:error, {:missing_workflow_file, ^source_path, :enoent}} =
             ProjectWorkflowGenerator.generate(project)
  end

  test "creates missing nested sections and defaults after_create to the project clone command", %{tmp_dir: tmp_dir} do
    source_path = Path.join(tmp_dir, "source/WORKFLOW.md")
    output_path = Path.join(tmp_dir, "generated/alpha/WORKFLOW.generated.md")

    File.mkdir_p!(Path.dirname(source_path))
    File.write!(source_path, "---\n{}\n---\nPrompt body\n")

    project =
      project_config(
        "alpha",
        4101,
        source_path,
        output_path,
        Path.join(tmp_dir, "workspaces/alpha"),
        Path.join(tmp_dir, "logs/alpha"),
        "slug-alpha",
        "https://example.com/alpha.git"
      )

    assert :ok = ProjectWorkflowGenerator.generate(project)
    assert {:ok, %{config: generated_config, prompt: prompt}} = Workflow.load(output_path)

    assert get_in(generated_config, ["tracker", "project_slug"]) == "slug-alpha"
    assert get_in(generated_config, ["workspace", "root"]) == Path.join(tmp_dir, "workspaces/alpha")
    assert get_in(generated_config, ["hooks", "after_create"]) == "git clone --depth 1 https://example.com/alpha.git ."
    assert prompt == "Prompt body"
  end

  test "replaces clone-only hooks with the current project clone command", %{tmp_dir: tmp_dir} do
    source_path = Path.join(tmp_dir, "source/WORKFLOW.md")
    output_path = Path.join(tmp_dir, "generated/alpha/WORKFLOW.generated.md")

    File.mkdir_p!(Path.dirname(source_path))

    File.write!(source_path, """
    ---
    hooks:
      after_create: "git clone --depth 1 https://example.com/source.git ."
    ---

    Shared prompt body
    """)

    project =
      project_config(
        "alpha",
        4101,
        source_path,
        output_path,
        Path.join(tmp_dir, "workspaces/alpha"),
        Path.join(tmp_dir, "logs/alpha"),
        "slug-alpha",
        "https://example.com/alpha.git"
      )

    assert :ok = ProjectWorkflowGenerator.generate(project)
    assert {:ok, %{config: generated_config}} = Workflow.load(output_path)
    assert get_in(generated_config, ["hooks", "after_create"]) == "git clone --depth 1 https://example.com/alpha.git ."
  end

  defp project_config(id, worker_port, workflow_source, workflow_generated, workspace_root, logs_root, project_slug, repo_url) do
    %ProjectConfig{
      id: id,
      name: String.capitalize(id),
      enabled: true,
      worker_port: worker_port,
      workflow_source: workflow_source,
      workflow_generated: workflow_generated,
      workspace_root: workspace_root,
      logs_root: logs_root,
      project_slug: project_slug,
      repo_url: repo_url
    }
  end

  defp temp_root! do
    root = Path.join(System.tmp_dir!(), "symphony-project-workflow-generator-#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    root
  end
end
