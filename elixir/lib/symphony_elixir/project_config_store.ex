defmodule SymphonyElixir.ProjectConfigStore do
  @moduledoc """
  Loads static multi-project control-plane config from `symphony.projects.yaml`.
  """

  alias SymphonyElixir.{PathSafety, ProjectConfig, ProjectConfigError}

  @runtime_only_fields MapSet.new([
                         "valid",
                         "invalid",
                         "not_started",
                         "pid",
                         "health",
                         "last_seen",
                         "worker_status"
                       ])

  @root_allowed_fields MapSet.new(["defaults", "projects"])
  @defaults_allowed_fields MapSet.new([
                             "workflow_source",
                             "workflow_generated_template",
                             "workspace_root_template",
                             "logs_root_template"
                           ])
  @required_fields ~w(id name workflow_source workflow_generated workspace_root logs_root project_slug repo_url)
  @optional_fields ~w(enabled worker_port)
  @allowed_fields MapSet.new(@required_fields ++ @optional_fields)
  @project_id_regex ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/
  @path_fields ~w(workflow_source workflow_generated workspace_root logs_root)
  @worker_port_base 4101

  @spec load(Path.t()) :: {:ok, [ProjectConfig.t()]} | {:error, [ProjectConfigError.t()]}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        parse_string(content)

      {:error, reason} ->
        {:error,
         [
           %ProjectConfigError{
             type: :invalid_field,
             field: "config_path",
             message: "failed to read config file: #{inspect(reason)}"
           }
         ]}
    end
  end

  @spec parse_string(String.t()) :: {:ok, [ProjectConfig.t()]} | {:error, [ProjectConfigError.t()]}
  def parse_string(yaml) when is_binary(yaml) do
    with {:ok, projects} <- decode_projects(yaml) do
      validate_projects(projects)
    end
  end

  @spec decode_projects(String.t()) :: {:ok, [map()]} | {:error, [ProjectConfigError.t()]}
  def decode_projects(yaml) when is_binary(yaml) do
    with {:ok, decoded} <- decode_yaml(yaml),
         {:ok, projects} <- fetch_projects(decoded),
         :ok <- validate_root_fields(decoded),
         {:ok, defaults} <- fetch_defaults(decoded) do
      {:ok, resolve_projects(projects, defaults)}
    end
  end

  @spec validate_raw_projects([term()]) ::
          [%{normalized_config: ProjectConfig.t() | nil, validation_errors: [ProjectConfigError.t()]}]
  def validate_raw_projects(projects) when is_list(projects) do
    duplicate_errors_by_index =
      projects
      |> Enum.with_index()
      |> Enum.flat_map(&project_ref/1)
      |> duplicate_id_errors()
      |> Enum.group_by(& &1.project_index)

    projects
    |> Enum.with_index()
    |> Enum.map(fn {project, index} ->
      validation_errors =
        case validate_project(project, index) do
          {:ok, _config} -> []
          {:error, errors} -> errors
        end

      combined_errors = validation_errors ++ Map.get(duplicate_errors_by_index, index, [])

      case combined_errors do
        [] ->
          {:ok, config} = validate_project(project, index)
          %{normalized_config: config, validation_errors: []}

        _ ->
          %{normalized_config: nil, validation_errors: combined_errors}
      end
    end)
  end

  defp decode_yaml(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, decoded} when is_map(decoded) -> {:ok, normalize_keys(decoded)}
      {:ok, _decoded} -> {:error, [yaml_parse_error("projects must decode from a YAML map")]}
      {:error, reason} -> {:error, [yaml_parse_error(inspect(reason))]}
    end
  end

  defp fetch_projects(%{"projects" => projects}) when is_list(projects), do: {:ok, Enum.map(projects, &normalize_keys/1)}

  defp fetch_projects(%{"projects" => _other}) do
    {:error,
     [
       %ProjectConfigError{
         type: :invalid_field,
         field: "projects",
         message: "projects must be a list"
       }
     ]}
  end

  defp fetch_projects(_decoded) do
    {:error,
     [
       %ProjectConfigError{
         type: :missing_field,
         field: "projects",
         message: "projects is required"
       }
     ]}
  end

  defp fetch_defaults(%{"defaults" => defaults}) when is_map(defaults), do: {:ok, defaults}
  defp fetch_defaults(%{"defaults" => _other}), do: {:error, [invalid_defaults_error()]}
  defp fetch_defaults(_decoded), do: {:ok, %{}}

  defp validate_root_fields(decoded) do
    errors =
      Enum.reduce(decoded, [], fn {field, value}, acc ->
        cond do
          field == "defaults" ->
            acc ++ validate_defaults(value)

          MapSet.member?(@root_allowed_fields, field) ->
            acc

          MapSet.member?(@runtime_only_fields, field) ->
            acc ++
              [
                %ProjectConfigError{
                  type: :invalid_field,
                  field: field,
                  message: "#{field} must not appear in static project config"
                }
              ]

          true ->
            acc ++
              [
                %ProjectConfigError{
                  type: :invalid_field,
                  field: field,
                  message: "#{field} is not part of the static project schema"
                }
              ]
        end
      end)

    case errors do
      [] -> :ok
      _ -> {:error, errors}
    end
  end

  defp validate_projects(projects) do
    project_refs =
      projects
      |> Enum.with_index()
      |> Enum.flat_map(&project_ref/1)

    {normalized, errors} =
      projects
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {project, index}, {valid_configs, collected_errors} ->
        case validate_project(project, index) do
          {:ok, config} -> {[{config, index} | valid_configs], collected_errors}
          {:error, project_errors} -> {valid_configs, collected_errors ++ project_errors}
        end
      end)

    errors =
      errors ++
        duplicate_id_errors(project_refs)

    case errors do
      [] -> {:ok, normalized |> Enum.reverse() |> Enum.map(&elem(&1, 0))}
      _ -> {:error, errors}
    end
  end

  defp validate_defaults(defaults) when is_map(defaults) do
    Enum.reduce(defaults, [], fn {field, _value}, acc ->
      cond do
        MapSet.member?(@defaults_allowed_fields, field) ->
          acc

        MapSet.member?(@runtime_only_fields, field) ->
          acc ++
            [
              %ProjectConfigError{
                type: :invalid_field,
                field: "defaults.#{field}",
                message: "#{field} must not appear in static project config"
              }
            ]

        true ->
          acc ++
            [
              %ProjectConfigError{
                type: :invalid_field,
                field: "defaults.#{field}",
                message: "#{field} is not part of the static project defaults schema"
              }
            ]
      end
    end)
  end

  defp validate_defaults(_defaults), do: [invalid_defaults_error()]

  defp resolve_projects(projects, defaults) when is_list(projects) do
    Enum.map(projects, &resolve_project(&1, defaults))
  end

  defp resolve_project(project, defaults) when is_map(project) do
    project_id = string_or_nil(Map.get(project, "id"))

    project
    |> maybe_put_default("workflow_source", string_or_nil(Map.get(defaults, "workflow_source")))
    |> maybe_put_default("workflow_generated", render_project_template(Map.get(defaults, "workflow_generated_template"), project_id))
    |> maybe_put_default("workspace_root", render_project_template(Map.get(defaults, "workspace_root_template"), project_id))
    |> maybe_put_default("logs_root", render_project_template(Map.get(defaults, "logs_root_template"), project_id))
  end

  defp resolve_project(project, _defaults), do: project

  defp validate_project(project, index) when is_map(project) do
    project_id = string_or_nil(Map.get(project, "id"))

    errors =
      []
      |> validate_missing_fields(project, index, project_id)
      |> validate_runtime_fields(project, index, project_id)
      |> validate_unknown_fields(project, index, project_id)
      |> validate_project_id(project_id, index)
      |> validate_paths(project, index, project_id)
      |> validate_enabled(project, index, project_id)
      |> validate_worker_port(project, index, project_id)

    case errors do
      [] ->
        {:ok,
         %ProjectConfig{
           id: project_id,
           name: String.trim(project["name"]),
           enabled: normalized_enabled(project),
           worker_port: normalized_worker_port(project, index),
           workflow_source: canonical_optional_path(Map.get(project, "workflow_source")),
           workflow_generated: canonical_path(project["workflow_generated"]),
           workspace_root: canonical_path(project["workspace_root"]),
           logs_root: canonical_path(project["logs_root"]),
           project_slug: string_or_nil(Map.get(project, "project_slug")),
           repo_url: string_or_nil(Map.get(project, "repo_url"))
         }}

      _ ->
        {:error, errors}
    end
  end

  defp validate_project(_project, index) do
    {:error,
     [
       %ProjectConfigError{
         type: :invalid_field,
         field: "projects",
         project_index: index,
         message: "project entry must be a map"
       }
     ]}
  end

  defp validate_missing_fields(errors, project, index, project_id) do
    Enum.reduce(@required_fields, errors, fn field, acc ->
      acc ++ validate_required_field(Map.fetch(project, field), field, index, project_id)
    end)
  end

  defp validate_runtime_fields(errors, project, index, project_id) do
    Enum.reduce(project, errors, fn {field, _value}, acc ->
      if MapSet.member?(@runtime_only_fields, field) do
        acc ++
          [
            %ProjectConfigError{
              type: :invalid_field,
              field: field,
              project_index: index,
              project_id: project_id,
              message: "#{field} must not appear in static project config"
            }
          ]
      else
        acc
      end
    end)
  end

  defp validate_unknown_fields(errors, project, index, project_id) do
    Enum.reduce(project, errors, fn {field, _value}, acc ->
      cond do
        MapSet.member?(@allowed_fields, field) ->
          acc

        MapSet.member?(@runtime_only_fields, field) ->
          acc

        true ->
          acc ++
            [
              %ProjectConfigError{
                type: :invalid_field,
                field: field,
                project_index: index,
                project_id: project_id,
                message: "#{field} is not part of the static project schema"
              }
            ]
      end
    end)
  end

  defp validate_project_id(errors, nil, _index), do: errors

  defp validate_project_id(errors, project_id, index) do
    if String.match?(project_id, @project_id_regex) do
      errors
    else
      errors ++
        [
          %ProjectConfigError{
            type: :invalid_field,
            field: "id",
            project_index: index,
            project_id: project_id,
            message: "id must match #{inspect(@project_id_regex)}"
          }
        ]
    end
  end

  defp validate_paths(errors, project, index, project_id) do
    Enum.reduce(@path_fields, errors, fn field, acc ->
      acc ++ validate_path_field(Map.get(project, field), field, index, project_id)
    end)
  end

  defp validate_enabled(errors, project, index, project_id) do
    case Map.fetch(project, "enabled") do
      :error -> errors
      {:ok, value} when is_boolean(value) -> errors
      {:ok, _value} -> errors ++ [invalid_enabled_error(index, project_id)]
    end
  end

  defp validate_worker_port(errors, project, index, project_id) do
    case Map.fetch(project, "worker_port") do
      :error ->
        errors

      {:ok, value} when is_integer(value) and value >= 0 ->
        errors

      {:ok, _value} ->
        errors ++ [invalid_worker_port_error(index, project_id)]
    end
  end

  defp validate_required_field(:error, field, index, project_id) do
    [missing_field_error(field, index, project_id)]
  end

  defp validate_required_field({:ok, value}, field, index, project_id) when is_binary(value) do
    if String.trim(value) == "" do
      [missing_field_error(field, index, project_id)]
    else
      []
    end
  end

  defp validate_required_field({:ok, _value}, field, index, project_id) do
    [invalid_required_field_error(field, index, project_id)]
  end

  defp validate_path_field(value, field, index, project_id) when is_binary(value) do
    cond do
      String.trim(value) == "" ->
        []

      Path.type(value) != :absolute ->
        [invalid_path_error(field, index, project_id, "must be an absolute path")]

      path_escape?(value) ->
        [unsafe_path_error(field, index, project_id, "must not contain path traversal segments")]

      true ->
        canonicalize_path_error(Path.expand(value), field, index, project_id)
    end
  end

  defp validate_path_field(_value, _field, _index, _project_id), do: []

  defp canonicalize_path_error(expanded, field, index, project_id) do
    case PathSafety.canonicalize(expanded) do
      {:ok, _canonical_path} ->
        []

      {:error, {:path_canonicalize_failed, _path, reason}} ->
        [invalid_path_error(field, index, project_id, "failed to canonicalize path: #{inspect(reason)}")]
    end
  end

  defp path_escape?(value) when is_binary(value) do
    value
    |> Path.split()
    |> Enum.any?(&(&1 == ".."))
  end

  defp project_ref({project, index}) when is_map(project) do
    case string_or_nil(Map.get(project, "id")) do
      nil -> []
      project_id -> [{project_id, index}]
    end
  end

  defp project_ref({_project, _index}), do: []

  defp duplicate_id_errors(projects) do
    duplicate_ids =
      projects
      |> Enum.group_by(fn {project_id, _index} -> project_id end)
      |> Enum.filter(fn {_id, entries} -> length(entries) > 1 end)
      |> Map.new()

    projects
    |> Enum.flat_map(fn {project_id, index} ->
      if Map.has_key?(duplicate_ids, project_id) do
        [
          %ProjectConfigError{
            type: :duplicate_project_id,
            field: "id",
            project_index: index,
            project_id: project_id,
            message: "duplicate project id: #{project_id}"
          }
        ]
      else
        []
      end
    end)
  end

  defp canonical_path(value) do
    {:ok, canonical} = value |> Path.expand() |> PathSafety.canonicalize()
    canonical
  end

  defp canonical_optional_path(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: canonical_path(value)
  end

  defp canonical_optional_path(_value), do: nil

  defp normalized_enabled(project) do
    Map.get(project, "enabled", true)
  end

  defp normalized_worker_port(project, index) do
    Map.get(project, "worker_port", @worker_port_base + index)
  end

  defp maybe_put_default(project, _field, nil), do: project

  defp maybe_put_default(project, field, value) do
    case Map.fetch(project, field) do
      :error ->
        Map.put(project, field, value)

      {:ok, nil} ->
        Map.put(project, field, value)

      {:ok, existing} when is_binary(existing) ->
        if String.trim(existing) == "" do
          Map.put(project, field, value)
        else
          project
        end

      _ ->
        project
    end
  end

  defp render_project_template(value, project_id) when is_binary(value) and is_binary(project_id) do
    value
    |> String.replace("{{ project_id }}", project_id)
    |> String.replace("{{project_id}}", project_id)
  end

  defp render_project_template(_value, _project_id), do: nil

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      Map.put(acc, normalize_key(key), normalize_keys(nested))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp string_or_nil(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp string_or_nil(_value), do: nil

  defp yaml_parse_error(message) do
    %ProjectConfigError{
      type: :yaml_parse_error,
      field: "projects",
      message: message
    }
  end

  defp invalid_defaults_error do
    %ProjectConfigError{
      type: :invalid_field,
      field: "defaults",
      message: "defaults must be a map"
    }
  end

  defp missing_field_error(field, index, project_id) do
    %ProjectConfigError{
      type: :missing_field,
      field: field,
      project_index: index,
      project_id: project_id,
      message: "#{field} is required"
    }
  end

  defp invalid_required_field_error(field, index, project_id) do
    %ProjectConfigError{
      type: :invalid_field,
      field: field,
      project_index: index,
      project_id: project_id,
      message: "#{field} must be a non-empty string"
    }
  end

  defp invalid_enabled_error(index, project_id) do
    %ProjectConfigError{
      type: :invalid_field,
      field: "enabled",
      project_index: index,
      project_id: project_id,
      message: "enabled must be a boolean"
    }
  end

  defp invalid_worker_port_error(index, project_id) do
    %ProjectConfigError{
      type: :invalid_field,
      field: "worker_port",
      project_index: index,
      project_id: project_id,
      message: "worker_port must be a non-negative integer"
    }
  end

  defp invalid_path_error(field, index, project_id, message) do
    %ProjectConfigError{
      type: :invalid_field,
      field: field,
      project_index: index,
      project_id: project_id,
      message: message
    }
  end

  defp unsafe_path_error(field, index, project_id, message) do
    %ProjectConfigError{
      type: :unsafe_path,
      field: field,
      project_index: index,
      project_id: project_id,
      message: message
    }
  end
end
