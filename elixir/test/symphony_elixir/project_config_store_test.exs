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

    assert Map.take(first, [
             :id,
             :name,
             :enabled,
             :worker_port,
             :workflow_source,
             :workflow_generated,
             :workspace_root,
             :logs_root,
             :project_slug,
             :repo_url
           ]) == %{
             id: "powersymphony",
             name: "PowerSymphony",
             enabled: true,
             worker_port: 4101,
             workflow_source: "/home/user/projects/powersymphony/elixir/WORKFLOW.md",
             workflow_generated: "/home/user/projects/symphony-runtime/powersymphony/WORKFLOW.generated.md",
             workspace_root: "/home/user/projects/symphony-workspaces/powersymphony",
             logs_root: "/home/user/projects/symphony-runtime/powersymphony/logs",
             project_slug: "03b2b4a16461",
             repo_url: "https://github.com/youdaowudao/PowerSymphony.git"
           }

    assert Map.take(second, [
             :id,
             :name,
             :enabled,
             :worker_port,
             :workflow_source,
             :workflow_generated,
             :workspace_root,
             :logs_root,
             :project_slug,
             :repo_url
           ]) == %{
             id: "linear-agents",
             name: "Linear Agents",
             enabled: true,
             worker_port: 4102,
             workflow_source: "/home/user/projects/powersymphony/elixir/WORKFLOW.md",
             workflow_generated: "/home/user/projects/symphony-runtime/linear-agents/WORKFLOW.generated.md",
             workspace_root: "/home/user/projects/symphony-workspaces/linear-agents",
             logs_root: "/home/user/projects/symphony-runtime/linear-agents/logs",
             project_slug: "327e2b00c1cd",
             repo_url: "https://github.com/youdaowudao/linear-agents.git"
           }
  end

  test "renders default templates and preserves project workflow binding fields", %{tmp_dir: tmp_dir} do
    workflow_source = Path.join(tmp_dir, "shared/WORKFLOW.md")
    workflow_generated_template = Path.join(tmp_dir, "generated/{{ project_id }}/WORKFLOW.generated.md")
    workspace_root_template = Path.join(tmp_dir, "workspaces/{{ project_id }}")
    logs_root_template = Path.join(tmp_dir, "logs/{{ project_id }}")

    yaml = """
    defaults:
      workflow_source: #{workflow_source}
      workflow_generated_template: #{workflow_generated_template}
      workspace_root_template: #{workspace_root_template}
      logs_root_template: #{logs_root_template}
    projects:
      - id: alpha
        name: Alpha
        project_slug: slug-alpha
        repo_url: https://example.com/alpha.git
      - id: beta
        name: Beta
        project_slug: slug-beta
        repo_url: https://example.com/beta.git
        worker_port: 4202
    """

    assert {:ok, [first, second]} = ProjectConfigStore.parse_string(yaml)

    assert Map.take(first, [
             :id,
             :name,
             :enabled,
             :worker_port,
             :workflow_source,
             :workflow_generated,
             :workspace_root,
             :logs_root,
             :project_slug,
             :repo_url
           ]) == %{
             id: "alpha",
             name: "Alpha",
             enabled: true,
             worker_port: 4101,
             workflow_source: workflow_source,
             workflow_generated: Path.join(tmp_dir, "generated/alpha/WORKFLOW.generated.md"),
             workspace_root: Path.join(tmp_dir, "workspaces/alpha"),
             logs_root: Path.join(tmp_dir, "logs/alpha"),
             project_slug: "slug-alpha",
             repo_url: "https://example.com/alpha.git"
           }

    assert Map.take(second, [
             :id,
             :name,
             :enabled,
             :worker_port,
             :workflow_source,
             :workflow_generated,
             :workspace_root,
             :logs_root,
             :project_slug,
             :repo_url
           ]) == %{
             id: "beta",
             name: "Beta",
             enabled: true,
             worker_port: 4202,
             workflow_source: workflow_source,
             workflow_generated: Path.join(tmp_dir, "generated/beta/WORKFLOW.generated.md"),
             workspace_root: Path.join(tmp_dir, "workspaces/beta"),
             logs_root: Path.join(tmp_dir, "logs/beta"),
             project_slug: "slug-beta",
             repo_url: "https://example.com/beta.git"
           }
  end

  test "applies enabled and worker_port defaults by project index" do
    yaml = """
    projects:
      - id: alpha
        name: Alpha
        workflow_source: /tmp/shared/WORKFLOW.md
        project_slug: slug-alpha
        repo_url: https://example.com/alpha.git
        workflow_generated: /tmp/alpha/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/alpha
        logs_root: /tmp/logs/alpha
      - id: beta
        name: Beta
        workflow_source: /tmp/shared/WORKFLOW.md
        project_slug: slug-beta
        repo_url: https://example.com/beta.git
        workflow_generated: /tmp/beta/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/beta
        logs_root: /tmp/logs/beta
    """

    assert {:ok, [first, second]} = ProjectConfigStore.parse_string(yaml)

    assert first.enabled == true
    assert first.worker_port == 4101
    assert second.enabled == true
    assert second.worker_port == 4102
  end

  test "preserves explicit enabled and worker_port values" do
    yaml = """
    projects:
      - id: alpha
        name: Alpha
        enabled: false
        worker_port: 0
        workflow_source: /tmp/shared/WORKFLOW.md
        project_slug: slug-alpha
        repo_url: https://example.com/alpha.git
        workflow_generated: /tmp/alpha/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/alpha
        logs_root: /tmp/logs/alpha
    """

    assert {:ok, [project]} = ProjectConfigStore.parse_string(yaml)

    assert project.enabled == false
    assert project.worker_port == 0
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

  test "reports invalid defaults containers" do
    yaml = """
    defaults: nope
    projects:
      - id: alpha
        name: Alpha
        workflow_generated: /tmp/generated/alpha/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/alpha
        logs_root: /tmp/logs/alpha
    """

    assert {:error, errors} = ProjectConfigStore.parse_string(yaml)

    assert Enum.any?(errors, fn error ->
             error.type == :invalid_field and
               error.project_index == nil and
               error.project_id == nil and
               error.field == "defaults"
           end)
  end

  test "reports runtime-only and unknown defaults fields" do
    yaml = """
    defaults:
      worker_status: running
      unexpected: value
    projects:
      - id: alpha
        name: Alpha
        workflow_source: /tmp/shared/WORKFLOW.md
        project_slug: slug-alpha
        repo_url: https://example.com/alpha.git
        workflow_generated: /tmp/generated/alpha/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/alpha
        logs_root: /tmp/logs/alpha
    """

    assert {:error, errors} = ProjectConfigStore.parse_string(yaml)
    assert_error(errors, :invalid_field, nil, nil, "defaults.worker_status")
    assert_error(errors, :invalid_field, nil, nil, "defaults.unexpected")
  end

  test "decode_projects applies defaults to nil and blank values while preserving explicit and invalid ones" do
    yaml = """
    defaults:
      workflow_source: /tmp/shared/WORKFLOW.md
      workflow_generated_template: /tmp/generated/{{ project_id }}/WORKFLOW.generated.md
      workspace_root_template: /tmp/workspaces/{{ project_id }}
      logs_root_template: /tmp/logs/{{ project_id }}
    projects:
      - id: alpha
        name: Alpha
        workflow_source:
        workflow_generated: "   "
        workspace_root: /tmp/custom-workspaces/alpha
        logs_root: 123
        project_slug: slug-alpha
        repo_url: https://example.com/alpha.git
      - id: beta
        name: Beta
        project_slug: slug-beta
        repo_url: https://example.com/beta.git
    """

    assert {:ok, [alpha, beta]} = ProjectConfigStore.decode_projects(yaml)

    assert alpha["workflow_source"] == "/tmp/shared/WORKFLOW.md"
    assert alpha["workflow_generated"] == "/tmp/generated/alpha/WORKFLOW.generated.md"
    assert alpha["workspace_root"] == "/tmp/custom-workspaces/alpha"
    assert alpha["logs_root"] == 123

    assert beta["workflow_source"] == "/tmp/shared/WORKFLOW.md"
    assert beta["workflow_generated"] == "/tmp/generated/beta/WORKFLOW.generated.md"
    assert beta["workspace_root"] == "/tmp/workspaces/beta"
    assert beta["logs_root"] == "/tmp/logs/beta"
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

  test "validate_raw_projects groups duplicate id errors onto each conflicting project" do
    projects = [
      %{
        "id" => "alpha",
        "name" => "Alpha",
        "workflow_source" => "/tmp/shared/WORKFLOW.md",
        "workflow_generated" => "/tmp/alpha/WORKFLOW.generated.md",
        "workspace_root" => "/tmp/workspaces/alpha",
        "logs_root" => "/tmp/logs/alpha",
        "project_slug" => "slug-alpha",
        "repo_url" => "https://example.com/alpha.git"
      },
      %{
        "id" => "alpha",
        "name" => "Alpha Duplicate",
        "workflow_source" => "/tmp/shared/WORKFLOW.md",
        "workflow_generated" => "/tmp/alpha-2/WORKFLOW.generated.md",
        "workspace_root" => "/tmp/workspaces/alpha-2",
        "logs_root" => "/tmp/logs/alpha-2",
        "project_slug" => "slug-alpha-2",
        "repo_url" => "https://example.com/alpha-2.git"
      }
    ]

    assert [
             %{normalized_config: nil, validation_errors: first_errors},
             %{normalized_config: nil, validation_errors: second_errors}
           ] = ProjectConfigStore.validate_raw_projects(projects)

    assert [
             %ProjectConfigError{
               type: :duplicate_project_id,
               field: "id",
               project_index: 0,
               project_id: "alpha"
             }
           ] = first_errors

    assert [
             %ProjectConfigError{
               type: :duplicate_project_id,
               field: "id",
               project_index: 1,
               project_id: "alpha"
             }
           ] = second_errors
  end

  test "validate_raw_projects keeps project validation errors alongside duplicate id errors" do
    projects = [
      %{
        "id" => "alpha",
        "name" => "Alpha",
        "workflow_source" => "/tmp/shared/WORKFLOW.md",
        "workflow_generated" => "/tmp/alpha/WORKFLOW.generated.md",
        "workspace_root" => "/tmp/workspaces/alpha",
        "logs_root" => "/tmp/logs/alpha",
        "project_slug" => "slug-alpha",
        "repo_url" => "https://example.com/alpha.git"
      },
      %{
        "id" => "alpha",
        "name" => "Alpha Duplicate",
        "workflow_source" => "/tmp/shared/WORKFLOW.md",
        "workflow_generated" => "relative/WORKFLOW.generated.md",
        "workspace_root" => "/tmp/workspaces/alpha-2",
        "logs_root" => "/tmp/logs/alpha-2",
        "project_slug" => "slug-alpha-2",
        "repo_url" => "https://example.com/alpha-2.git"
      }
    ]

    assert [
             %{normalized_config: nil, validation_errors: first_errors},
             %{normalized_config: nil, validation_errors: second_errors}
           ] = ProjectConfigStore.validate_raw_projects(projects)

    assert [
             %ProjectConfigError{
               type: :duplicate_project_id,
               field: "id",
               project_index: 0,
               project_id: "alpha"
             }
           ] = first_errors

    assert Enum.any?(second_errors, fn error ->
             error.type == :duplicate_project_id and
               error.field == "id" and
               error.project_index == 1 and
               error.project_id == "alpha"
           end)

    assert Enum.any?(second_errors, fn error ->
             error.type == :invalid_field and
               error.field == "workflow_generated" and
               error.project_index == 1 and
               error.project_id == "alpha"
           end)
  end

  test "validate_raw_projects returns normalized config for a valid project with no errors" do
    projects = [
      %{
        "id" => "alpha",
        "name" => "Alpha",
        "workflow_source" => "/tmp/shared/WORKFLOW.md",
        "workflow_generated" => "/tmp/alpha/WORKFLOW.generated.md",
        "workspace_root" => "/tmp/workspaces/alpha",
        "logs_root" => "/tmp/logs/alpha",
        "project_slug" => "slug-alpha",
        "repo_url" => "https://example.com/alpha.git"
      }
    ]

    assert [
             %{
               normalized_config: %ProjectConfig{
                 id: "alpha",
                 name: "Alpha",
                 enabled: true,
                 worker_port: 4101,
                 workflow_source: "/tmp/shared/WORKFLOW.md",
                 workflow_generated: "/tmp/alpha/WORKFLOW.generated.md",
                 workspace_root: "/tmp/workspaces/alpha",
                 logs_root: "/tmp/logs/alpha",
                 project_slug: "slug-alpha",
                 repo_url: "https://example.com/alpha.git"
               },
               validation_errors: []
             }
           ] = ProjectConfigStore.validate_raw_projects(projects)
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

  test "reports invalid enabled types" do
    yaml = """
    projects:
      - id: alpha
        name: Alpha
        enabled: nope
        workflow_generated: /tmp/alpha/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/alpha
        logs_root: /tmp/logs/alpha
    """

    assert {:error, errors} = ProjectConfigStore.parse_string(yaml)

    assert_error(errors, :invalid_field, 0, "alpha", "enabled")
  end

  test "reports invalid worker_port values" do
    invalid_projects = [
      {"wrong type", "worker_port: nope", :invalid_field},
      {"negative", "worker_port: -1", :invalid_field}
    ]

    Enum.each(invalid_projects, fn {_label, worker_port_line, error_type} ->
      yaml = """
      projects:
        - id: alpha
          name: Alpha
          #{worker_port_line}
          workflow_source: /tmp/shared/WORKFLOW.md
          project_slug: slug-alpha
          repo_url: https://example.com/alpha.git
          workflow_generated: /tmp/alpha/WORKFLOW.generated.md
          workspace_root: /tmp/workspaces/alpha
          logs_root: /tmp/logs/alpha
      """

      assert {:error, errors} = ProjectConfigStore.parse_string(yaml)
      assert_error(errors, error_type, 0, "alpha", "worker_port")
    end)
  end

  test "accepts explicit worker_port 4000 as a valid non-negative integer" do
    yaml = """
    projects:
      - id: alpha
        name: Alpha
        worker_port: 4000
        workflow_source: /tmp/shared/WORKFLOW.md
        project_slug: slug-alpha
        repo_url: https://example.com/alpha.git
        workflow_generated: /tmp/alpha/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/alpha
        logs_root: /tmp/logs/alpha
    """

    assert {:ok, [project]} = ProjectConfigStore.parse_string(yaml)
    assert project.worker_port == 4000
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

  test "rejects unknown root-level fields" do
    yaml = """
    projects:
      - id: alpha
        name: Alpha
        workflow_generated: /tmp/alpha/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/alpha
        logs_root: /tmp/logs/alpha
    extra: true
    """

    assert {:error, errors} = ProjectConfigStore.parse_string(yaml)

    assert_error(errors, :invalid_field, nil, nil, "extra")
  end

  test "rejects runtime-only root-level fields" do
    yaml = """
    projects:
      - id: alpha
        name: Alpha
        workflow_generated: /tmp/alpha/WORKFLOW.generated.md
        workspace_root: /tmp/workspaces/alpha
        logs_root: /tmp/logs/alpha
    health: ok
    """

    assert {:error, errors} = ProjectConfigStore.parse_string(yaml)

    assert_error(errors, :invalid_field, nil, nil, "health")
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
        enabled: true
        worker_port: 4201
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

  test "reports canonicalize failures for non-directory path segments", %{tmp_dir: tmp_dir} do
    blocked_path = Path.join(tmp_dir, "blocked")
    workflow_path = Path.join(blocked_path, "WORKFLOW.generated.md")

    File.write!(blocked_path, "not a directory")

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
        !<tag:yamerl,2012:atom> workflow_source: /tmp/shared/WORKFLOW.md
        !<tag:yamerl,2012:atom> workflow_generated: /tmp/alpha/WORKFLOW.generated.md
        !<tag:yamerl,2012:atom> workspace_root: /tmp/workspaces/alpha
        !<tag:yamerl,2012:atom> logs_root: /tmp/logs/alpha
        !<tag:yamerl,2012:atom> project_slug: slug-alpha
        !<tag:yamerl,2012:atom> repo_url: https://example.com/alpha.git
    """)

    assert {:ok, [project]} = ProjectConfigStore.load(config_path)
    assert project.id == "alpha"
    assert project.name == "Alpha"
    assert project.enabled == true
    assert project.worker_port == 4101
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
