defmodule SymphonyElixir.ProjectRegistryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{ProjectConfig, ProjectConfigError, ProjectRegistry, ProjectRegistryLoader}

  @sample_config_path Path.expand("../../../bin/symphony.projects.example.yaml", __DIR__)

  test "builds entries for valid and invalid projects while preserving not_started runtime state" do
    yaml = """
    projects:
      - id: alpha
        name: Alpha
        enabled: false
        worker_port: 4201
        workflow_source: /tmp/shared/WORKFLOW.md
        project_slug: slug-alpha
        repo_url: https://example.com/alpha.git
        workflow_generated: /tmp/alpha/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/alpha
        logs_root: /tmp/logs/alpha
      - id: Beta
        name: Beta
        workflow_source: /tmp/shared/WORKFLOW.md
        project_slug: slug-beta
        repo_url: https://example.com/beta.git
        workflow_generated: /tmp/beta/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/beta
        logs_root: /tmp/logs/beta
    """

    assert {:ok, registry} = ProjectRegistry.build(yaml)

    assert [
             %{
               project_id: "alpha",
               project_name: "Alpha",
               validation_result: :valid,
               validation_errors: [],
               runtime_state: %{status: :not_started},
               normalized_config: %ProjectConfig{
                 id: "alpha",
                 enabled: false,
                 worker_port: 4201
               }
             },
             %{
               project_id: "Beta",
               project_name: "Beta",
               validation_result: :invalid,
               validation_errors: [%ProjectConfigError{field: "id"}],
               runtime_state: %{status: :not_started},
               normalized_config: nil
             }
           ] = ProjectRegistry.entries(registry)
  end

  test "keeps validation state isolated between two valid projects" do
    assert {:ok, registry} = ProjectRegistry.load(@sample_config_path)
    [first, second] = ProjectRegistry.entries(registry)

    assert first.project_id == "powersymphony"
    assert second.project_id == "linear-agents"
    assert first.validation_result == :valid
    assert second.validation_result == :valid
    assert first.runtime_state == %{status: :not_started}
    assert second.runtime_state == %{status: :not_started}
    assert first.normalized_config.enabled == true
    assert first.normalized_config.worker_port == 4101
    assert second.normalized_config.enabled == true
    assert second.normalized_config.worker_port == 4102

    assert Map.take(first.normalized_config, [:workflow_source, :project_slug, :repo_url]) == %{
             workflow_source: "/home/user/projects/powersymphony/elixir/WORKFLOW.md",
             project_slug: "03b2b4a16461",
             repo_url: "https://github.com/youdaowudao/PowerSymphony.git"
           }

    assert Map.take(second.normalized_config, [:workflow_source, :project_slug, :repo_url]) == %{
             workflow_source: "/home/user/projects/powersymphony/elixir/WORKFLOW.md",
             project_slug: "327e2b00c1cd",
             repo_url: "https://github.com/youdaowudao/linear-agents.git"
           }
  end

  test "build preserves workflow source, project slug, and repo url in normalized configs" do
    yaml = """
    defaults:
      workflow_source: /tmp/shared/WORKFLOW.md
      workflow_generated_template: /tmp/generated/{{ project_id }}/WORKFLOW.generated.md
      workspace_root_template: /tmp/workspaces/{{ project_id }}
      logs_root_template: /tmp/logs/{{ project_id }}
    projects:
      - id: alpha
        name: Alpha
        project_slug: slug-alpha
        repo_url: https://example.com/alpha.git
      - id: beta
        name: Beta
        project_slug: slug-beta
        repo_url: https://example.com/beta.git
    """

    assert {:ok, registry} = ProjectRegistry.build(yaml)

    assert [
             %{
               project_id: "alpha",
               normalized_config: alpha_config,
               validation_result: :valid,
               runtime_state: %{status: :not_started}
             },
             %{
               project_id: "beta",
               normalized_config: beta_config,
               validation_result: :valid,
               runtime_state: %{status: :not_started}
             }
           ] = ProjectRegistry.entries(registry)

    assert Map.take(alpha_config, [:workflow_source, :project_slug, :repo_url]) == %{
             workflow_source: "/tmp/shared/WORKFLOW.md",
             project_slug: "slug-alpha",
             repo_url: "https://example.com/alpha.git"
           }

    assert Map.take(beta_config, [:workflow_source, :project_slug, :repo_url]) == %{
             workflow_source: "/tmp/shared/WORKFLOW.md",
             project_slug: "slug-beta",
             repo_url: "https://example.com/beta.git"
           }
  end

  test "explicit worker_port zero remains valid and keeps runtime_state not_started" do
    yaml = """
    projects:
      - id: alpha
        name: Alpha
        enabled: true
        worker_port: 0
        workflow_source: /tmp/shared/WORKFLOW.md
        project_slug: slug-alpha
        repo_url: https://example.com/alpha.git
        workflow_generated: /tmp/alpha/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/alpha
        logs_root: /tmp/logs/alpha
    """

    assert {:ok, registry} = ProjectRegistry.build(yaml)

    assert [
             %{
               project_id: "alpha",
               project_name: "Alpha",
               normalized_config: %ProjectConfig{
                 id: "alpha",
                 enabled: true,
                 worker_port: 0
               },
               validation_result: :valid,
               validation_errors: [],
               runtime_state: %{status: :not_started}
             }
           ] = ProjectRegistry.entries(registry)
  end

  test "loader resolves override path when provided" do
    previous_override = Application.get_env(:symphony_elixir, :project_config_path_override)

    on_exit(fn ->
      if is_nil(previous_override) do
        Application.delete_env(:symphony_elixir, :project_config_path_override)
      else
        Application.put_env(:symphony_elixir, :project_config_path_override, previous_override)
      end
    end)

    Application.put_env(:symphony_elixir, :project_config_path_override, @sample_config_path)

    assert ProjectRegistryLoader.project_config_path() == @sample_config_path
    assert %ProjectRegistry{entries: [_, _]} = ProjectRegistryLoader.load()
  end

  test "loader resolves default config from bin/symphony.projects.yaml" do
    previous_override = Application.get_env(:symphony_elixir, :project_config_path_override)

    on_exit(fn ->
      if is_nil(previous_override) do
        Application.delete_env(:symphony_elixir, :project_config_path_override)
      else
        Application.put_env(:symphony_elixir, :project_config_path_override, previous_override)
      end
    end)

    Application.delete_env(:symphony_elixir, :project_config_path_override)
    assert ProjectRegistryLoader.project_config_path() ==
             Path.expand("../../../bin/symphony.projects.yaml", __DIR__)
  end

  test "find_entry returns matching entry and nil for unknown id" do
    assert {:ok, registry} = ProjectRegistry.load(@sample_config_path)

    assert %{project_id: "powersymphony"} =
             ProjectRegistry.find_entry(registry, "powersymphony")

    assert ProjectRegistry.find_entry(registry, "missing-project") == nil
  end

  test "load returns config_path error when file cannot be read" do
    missing_path =
      Path.join(
        System.tmp_dir!(),
        "missing-project-registry-#{System.unique_integer([:positive])}.yaml"
      )

    assert {:error,
            [
              %ProjectConfigError{
                type: :invalid_field,
                field: "config_path",
                message: message
              }
            ]} = ProjectRegistry.load(missing_path)

    assert message =~ "failed to read config file"
    assert message =~ "enoent"
  end

  test "build preserves nil project id and name for non-map project entries" do
    yaml = """
    projects:
      - not-a-map
    """

    assert {:ok, registry} = ProjectRegistry.build(yaml)

    assert [
             %{
               project_id: nil,
               project_name: nil,
               normalized_config: nil,
               validation_result: :invalid,
               validation_errors: [%ProjectConfigError{field: "projects"}],
               runtime_state: %{status: :not_started}
             }
           ] = ProjectRegistry.entries(registry)
  end

  test "build trims blank and non-string project id and name to nil" do
    yaml = """
    projects:
      - id: "   "
        name: "   "
        workflow_generated: /tmp/alpha/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/alpha
        logs_root: /tmp/logs/alpha
      - id: 123
        name: 456
        workflow_generated: /tmp/beta/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/beta
        logs_root: /tmp/logs/beta
    """

    assert {:ok, registry} = ProjectRegistry.build(yaml)

    assert [
             %{
               project_id: nil,
               project_name: nil,
               normalized_config: nil,
               validation_result: :invalid,
               runtime_state: %{status: :not_started}
             },
             %{
               project_id: nil,
               project_name: nil,
               normalized_config: nil,
               validation_result: :invalid,
               runtime_state: %{status: :not_started}
             }
           ] = ProjectRegistry.entries(registry)
  end

  test "loader exposes invalid registry entry when override path does not exist" do
    previous_override = Application.get_env(:symphony_elixir, :project_config_path_override)

    on_exit(fn ->
      if is_nil(previous_override) do
        Application.delete_env(:symphony_elixir, :project_config_path_override)
      else
        Application.put_env(:symphony_elixir, :project_config_path_override, previous_override)
      end
    end)

    missing_path =
      Path.join(
        System.tmp_dir!(),
        "missing-loader-project-registry-#{System.unique_integer([:positive])}.yaml"
      )

    Application.put_env(:symphony_elixir, :project_config_path_override, missing_path)

    assert ProjectRegistryLoader.project_config_path() == missing_path

    assert %ProjectRegistry{
             entries: [
               %ProjectRegistry.Entry{
                 project_id: nil,
                 project_name: nil,
                 normalized_config: nil,
                 validation_result: :invalid,
                 runtime_state: %{status: :not_started},
                 validation_errors: [%ProjectConfigError{field: "config_path", message: message}]
               }
             ]
           } = ProjectRegistryLoader.load()

    assert message =~ "failed to read config file"
    assert message =~ "enoent"
  end

  test "loader exposes invalid override config as an invalid registry entry" do
    previous_override = Application.get_env(:symphony_elixir, :project_config_path_override)

    on_exit(fn ->
      if is_nil(previous_override) do
        Application.delete_env(:symphony_elixir, :project_config_path_override)
      else
        Application.put_env(:symphony_elixir, :project_config_path_override, previous_override)
      end
    end)

    config_path =
      Path.join(
        System.tmp_dir!(),
        "invalid-loader-project-registry-#{System.unique_integer([:positive])}.yaml"
      )

    on_exit(fn -> File.rm_rf!(config_path) end)
    File.write!(config_path, "projects: [\n")

    Application.put_env(:symphony_elixir, :project_config_path_override, config_path)

    assert ProjectRegistryLoader.project_config_path() == config_path

    assert %ProjectRegistry{
             entries: [
               %ProjectRegistry.Entry{
                 project_id: nil,
                 project_name: nil,
                 normalized_config: nil,
                 validation_result: :invalid,
                 runtime_state: %{status: :not_started},
                 validation_errors: [%ProjectConfigError{field: field, message: message}]
               }
             ]
           } = ProjectRegistryLoader.load()

    assert field == "projects"
    assert message =~ "yaml"
  end
end
