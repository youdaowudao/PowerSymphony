defmodule SymphonyElixir.ProjectRegistryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{ProjectConfig, ProjectConfigError, ProjectRegistry, ProjectRegistryLoader}

  @sample_config_path Path.expand("../../../symphony.projects.example.yaml", __DIR__)

  test "builds entries for valid and invalid projects while preserving not_started runtime state" do
    yaml = """
    projects:
      - id: alpha
        name: Alpha
        enabled: false
        worker_port: 4201
        workflow_generated: /tmp/alpha/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/alpha
        logs_root: /tmp/logs/alpha
      - id: Beta
        name: Beta
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

    assert first.project_id == "chatgpt-extension"
    assert second.project_id == "docs-site"
    assert first.validation_result == :valid
    assert second.validation_result == :valid
    assert first.runtime_state == %{status: :not_started}
    assert second.runtime_state == %{status: :not_started}
    assert first.normalized_config.enabled == true
    assert first.normalized_config.worker_port == 4101
    assert second.normalized_config.enabled == true
    assert second.normalized_config.worker_port == 4102
  end

  test "explicit worker_port zero remains valid and keeps runtime_state not_started" do
    yaml = """
    projects:
      - id: alpha
        name: Alpha
        enabled: true
        worker_port: 0
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

  test "loader resolves default config from current working directory" do
    previous_override = Application.get_env(:symphony_elixir, :project_config_path_override)

    on_exit(fn ->
      if is_nil(previous_override) do
        Application.delete_env(:symphony_elixir, :project_config_path_override)
      else
        Application.put_env(:symphony_elixir, :project_config_path_override, previous_override)
      end
    end)

    Application.delete_env(:symphony_elixir, :project_config_path_override)

    config_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-project-registry-loader-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(config_root) end)
    File.mkdir_p!(config_root)

    config_path = Path.join(config_root, "symphony.projects.yaml")
    File.cp!(@sample_config_path, config_path)

    original_cwd = File.cwd!()

    on_exit(fn ->
      File.cd!(original_cwd)
    end)

    File.cd!(config_root)

    assert ProjectRegistryLoader.project_config_path() == config_path
  end

  test "find_entry returns matching entry and nil for unknown id" do
    assert {:ok, registry} = ProjectRegistry.load(@sample_config_path)

    assert %{project_id: "chatgpt-extension"} =
             ProjectRegistry.find_entry(registry, "chatgpt-extension")

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
