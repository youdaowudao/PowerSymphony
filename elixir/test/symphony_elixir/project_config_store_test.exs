defmodule SymphonyElixir.ProjectConfigStoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{ProjectConfig, ProjectConfigError, ProjectConfigStore}

  @sample_config_path Path.expand("../../../symphony.projects.example.yaml", __DIR__)

  setup do
    tmp_dir = create_tmp_dir()
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  test "loads and normalizes two projects from the sample config" do
    assert {:ok, [first, second]} = ProjectConfigStore.load(@sample_config_path)

    assert first == %ProjectConfig{
             id: "chatgpt-extension",
             name: "ChatGPT Extension",
             workflow_generated: "/home/user/code/chatgpt-extension/WORKFLOW.generated.md",
             workspace_root: "/home/user/.symphony/workspaces/chatgpt-extension",
             logs_root: "/home/user/.symphony/logs/chatgpt-extension"
           }

    assert second == %ProjectConfig{
             id: "docs-site",
             name: "Docs Site",
             workflow_generated: "/home/user/code/docs-site/WORKFLOW.generated.md",
             workspace_root: "/home/user/.symphony/workspaces/docs-site",
             logs_root: "/home/user/.symphony/logs/docs-site"
           }
  end

  test "reports yaml parse errors with a stable structured error" do
    assert {:error, [%ProjectConfigError{} = error]} =
             ProjectConfigStore.parse_string("projects: [")

    assert error.type == :yaml_parse_error
    assert error.field == "projects"
    assert error.project_index == nil
    assert error.project_id == nil
  end

  test "reports missing required fields per project" do
    yaml = """
    projects:
      - id: alpha
        workflow_generated: /tmp/alpha/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/alpha
        logs_root: /tmp/logs/alpha
    """

    assert {:error, errors} = ProjectConfigStore.parse_string(yaml)

    assert_error(errors, :missing_field, 0, "alpha", "name")
  end

  test "reports invalid project ids" do
    yaml = """
    projects:
      - id: Alpha
        name: Alpha
        workflow_generated: /tmp/alpha/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/alpha
        logs_root: /tmp/logs/alpha
    """

    assert {:error, errors} = ProjectConfigStore.parse_string(yaml)

    assert_error(errors, :invalid_field, 0, "Alpha", "id")
  end

  test "reports duplicate project ids for every conflicting project" do
    yaml = """
    projects:
      - id: alpha
        name: Alpha
        workflow_generated: /tmp/alpha/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/alpha
        logs_root: /tmp/logs/alpha
      - id: alpha
        name: Alpha Duplicate
        workflow_generated: /tmp/alpha-2/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/alpha-2
        logs_root: /tmp/logs/alpha-2
    """

    assert {:error, errors} = ProjectConfigStore.parse_string(yaml)

    assert Enum.count(errors, &(&1.type == :duplicate_project_id)) == 2
    assert_error(errors, :duplicate_project_id, 0, "alpha", "id")
    assert_error(errors, :duplicate_project_id, 1, "alpha", "id")
  end

  test "reports duplicate project ids even when a conflicting project has other errors" do
    yaml = """
    projects:
      - id: alpha
        name: Alpha
        workflow_generated: /tmp/alpha/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/alpha
        logs_root: /tmp/logs/alpha
      - id: alpha
        name: Alpha Duplicate
        workflow_generated: relative/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/alpha-2
        logs_root: /tmp/logs/alpha-2
    """

    assert {:error, errors} = ProjectConfigStore.parse_string(yaml)

    assert Enum.count(errors, &(&1.type == :duplicate_project_id)) == 2
    assert_error(errors, :duplicate_project_id, 0, "alpha", "id")
    assert_error(errors, :duplicate_project_id, 1, "alpha", "id")
    assert_error(errors, :invalid_field, 1, "alpha", "workflow_generated")
  end

  test "reports invalid_field for required fields with the wrong type" do
    yaml = """
    projects:
      - id: alpha
        name: 123
        workflow_generated: /tmp/alpha/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/alpha
        logs_root: /tmp/logs/alpha
    """

    assert {:error, errors} = ProjectConfigStore.parse_string(yaml)

    assert_error(errors, :invalid_field, 0, "alpha", "name")
    refute_error(errors, :missing_field, 0, "alpha", "name")
  end

  test "reports invalid path fields" do
    yaml = """
    projects:
      - id: alpha
        name: Alpha
        workflow_generated: relative/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/alpha
        logs_root: /tmp/logs/alpha
    """

    assert {:error, errors} = ProjectConfigStore.parse_string(yaml)

    assert_error(errors, :invalid_field, 0, "alpha", "workflow_generated")
  end

  test "reports unsafe path traversal attempts" do
    yaml = """
    projects:
      - id: alpha
        name: Alpha
        workflow_generated: /tmp/alpha/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/../escape
        logs_root: /tmp/logs/alpha
    """

    assert {:error, errors} = ProjectConfigStore.parse_string(yaml)

    assert_error(errors, :unsafe_path, 0, "alpha", "workspace_root")
  end

  test "rejects runtime status fields in project yaml" do
    yaml = """
    projects:
      - id: alpha
        name: Alpha
        workflow_generated: /tmp/alpha/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/alpha
        logs_root: /tmp/logs/alpha
        worker_status: running
    """

    assert {:error, errors} = ProjectConfigStore.parse_string(yaml)

    assert_error(errors, :invalid_field, 0, "alpha", "worker_status")
  end

  test "reports config file read failures" do
    missing_path = Path.join(System.tmp_dir!(), "missing-project-config-#{System.unique_integer([:positive])}.yaml")

    assert {:error, [%ProjectConfigError{} = error]} = ProjectConfigStore.load(missing_path)

    assert error.type == :invalid_field
    assert error.field == "config_path"
    assert error.project_index == nil
    assert error.project_id == nil
    assert error.message =~ "failed to read config file"
  end

  test "rejects yaml documents that decode to a non-map" do
    assert {:error, [%ProjectConfigError{} = error]} =
             ProjectConfigStore.parse_string("- alpha\n- beta\n")

    assert error.type == :yaml_parse_error
    assert error.field == "projects"
    assert error.message == "projects must decode from a YAML map"
  end

  test "reports projects field shape errors" do
    assert {:error, [invalid_projects]} = ProjectConfigStore.parse_string("projects: alpha\n")
    assert invalid_projects.type == :invalid_field
    assert invalid_projects.field == "projects"
    assert invalid_projects.message == "projects must be a list"

    assert {:error, [missing_projects]} = ProjectConfigStore.parse_string("version: 1\n")
    assert missing_projects.type == :missing_field
    assert missing_projects.field == "projects"
    assert missing_projects.message == "projects is required"
  end

  test "reports non-map project entries" do
    yaml = """
    projects:
      - alpha
    """

    assert {:error, errors} = ProjectConfigStore.parse_string(yaml)

    assert_error(errors, :invalid_field, 0, nil, "projects")
  end

  test "reports unknown static schema fields" do
    yaml = """
    projects:
      - id: alpha
        name: Alpha
        workflow_generated: /tmp/alpha/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/alpha
        logs_root: /tmp/logs/alpha
        unexpected: true
    """

    assert {:error, errors} = ProjectConfigStore.parse_string(yaml)

    assert_error(errors, :invalid_field, 0, "alpha", "unexpected")
  end

  test "preserves duplicate id reporting when conflicting ids are blank or non-binary" do
    yaml = """
    projects:
      - id: "   "
        name: Alpha
        workflow_generated: /tmp/alpha/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/alpha
        logs_root: /tmp/logs/alpha
      - id: 123
        name: Beta
        workflow_generated: /tmp/beta/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/beta
        logs_root: /tmp/logs/beta
      - nope
    """

    assert {:error, errors} = ProjectConfigStore.parse_string(yaml)

    assert_error(errors, :missing_field, 0, nil, "id")
    assert_error(errors, :invalid_field, 1, nil, "id")
    assert_error(errors, :invalid_field, 2, nil, "projects")
    refute Enum.any?(errors, &(&1.type == :duplicate_project_id))
  end

  test "accepts blank optional path values without path validation errors" do
    yaml = """
    projects:
      - id: alpha
        name: Alpha
        workflow_generated: "   "
        workspace_root: /tmp/workspaces/alpha
        logs_root: /tmp/logs/alpha
    """

    assert {:error, errors} = ProjectConfigStore.parse_string(yaml)

    assert_error(errors, :missing_field, 0, "alpha", "workflow_generated")
    refute_error(errors, :invalid_field, 0, "alpha", "workflow_generated")
    refute_error(errors, :unsafe_path, 0, "alpha", "workflow_generated")
  end

  test "ignores non-binary path field values after reporting required-field type errors" do
    yaml = """
    projects:
      - id: alpha
        name: Alpha
        workflow_generated: 123
        workspace_root: /tmp/workspaces/alpha
        logs_root: /tmp/logs/alpha
    """

    assert {:error, errors} = ProjectConfigStore.parse_string(yaml)

    assert_error(errors, :invalid_field, 0, "alpha", "workflow_generated")

    refute Enum.any?(errors, fn error ->
             error.field == "workflow_generated" and
               error.message =~ "absolute path"
           end)
  end

  test "reports canonicalize failures for unreadable path segments", %{tmp_dir: tmp_dir} do
    blocked_dir = Path.join(tmp_dir, "blocked")
    workflow_path = Path.join(blocked_dir, "WORKFLOW.generated.md")

    File.mkdir_p!(blocked_dir)
    File.chmod!(blocked_dir, 0o000)

    on_exit(fn ->
      File.chmod!(blocked_dir, 0o755)
    end)

    yaml = """
    projects:
      - id: alpha
        name: Alpha
        workflow_generated: #{workflow_path}
        workspace_root: /tmp/workspaces/alpha
        logs_root: /tmp/logs/alpha
    """

    assert {:error, errors} = ProjectConfigStore.parse_string(yaml)

    assert_error(errors, :invalid_field, 0, "alpha", "workflow_generated")
    assert Enum.any?(errors, &String.contains?(&1.message, "failed to canonicalize path"))
  end

  test "normalizes atom keys when loading a yaml file", %{tmp_dir: tmp_dir} do
    config_path = Path.join(tmp_dir, "atom-keys.yaml")

    previous_node_mods = :yamerl_app.get_param(:node_mods)
    :yamerl_app.set_param(:node_mods, [:yamerl_node_erlang_atom])

    on_exit(fn ->
      :yamerl_app.set_param(:node_mods, previous_node_mods)
    end)

    File.write!(config_path, """
    projects:
      - !<tag:yamerl,2012:atom> id: alpha
        !<tag:yamerl,2012:atom> name: Alpha
        !<tag:yamerl,2012:atom> workflow_generated: /tmp/alpha/WORKFLOW.generated.md
        !<tag:yamerl,2012:atom> workspace_root: /tmp/workspaces/alpha
        !<tag:yamerl,2012:atom> logs_root: /tmp/logs/alpha
    """)

    assert {:ok, [project]} = ProjectConfigStore.load(config_path)
    assert project.id == "alpha"
    assert project.name == "Alpha"
  end

  defp assert_error(errors, type, project_index, project_id, field) do
    assert Enum.any?(errors, fn error ->
             error.type == type and
               error.project_index == project_index and
               error.project_id == project_id and
               error.field == field
           end)
  end

  defp refute_error(errors, type, project_index, project_id, field) do
    refute Enum.any?(errors, fn error ->
             error.type == type and
               error.project_index == project_index and
               error.project_id == project_id and
               error.field == field
           end)
  end

  defp create_tmp_dir do
    unique = :erlang.unique_integer([:positive, :monotonic])
    dir = Path.join(System.tmp_dir!(), "project-config-store-test-#{unique}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end
end
