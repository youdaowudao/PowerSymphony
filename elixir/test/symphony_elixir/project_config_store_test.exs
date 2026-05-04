defmodule SymphonyElixir.ProjectConfigStoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{ProjectConfig, ProjectConfigError, ProjectConfigStore}

  @sample_config_path Path.expand("../../../symphony.projects.example.yaml", __DIR__)

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
end
