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

  @required_fields ~w(id name workflow_generated workspace_root logs_root)
  @allowed_fields MapSet.new(@required_fields)
  @project_id_regex ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/
  @path_fields ~w(workflow_generated workspace_root logs_root)

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
    with {:ok, decoded} <- decode_yaml(yaml),
         {:ok, projects} <- fetch_projects(decoded) do
      validate_projects(projects)
    end
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

  defp validate_projects(projects) do
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
        duplicate_id_errors(normalized)

    case errors do
      [] -> {:ok, normalized |> Enum.reverse() |> Enum.map(&elem(&1, 0))}
      _ -> {:error, errors}
    end
  end

  defp validate_project(project, index) when is_map(project) do
    project_id = string_or_nil(Map.get(project, "id"))

    errors =
      []
      |> validate_missing_fields(project, index, project_id)
      |> validate_runtime_fields(project, index, project_id)
      |> validate_unknown_fields(project, index, project_id)
      |> validate_project_id(project_id, index)
      |> validate_paths(project, index, project_id)

    case errors do
      [] ->
        {:ok,
         %ProjectConfig{
           id: project_id,
           name: String.trim(project["name"]),
           workflow_generated: canonical_path(project["workflow_generated"]),
           workspace_root: canonical_path(project["workspace_root"]),
           logs_root: canonical_path(project["logs_root"])
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

  defp validate_missing_fields(errors, project, index, _project_id) do
    Enum.reduce(@required_fields, errors, fn field, acc ->
      case Map.get(project, field) do
        value when is_binary(value) ->
          if String.trim(value) == "" do
            acc ++
              [
                %ProjectConfigError{
                  type: :missing_field,
                  field: field,
                  project_index: index,
                  project_id: nil,
                  message: "#{field} is required"
                }
              ]
          else
            acc
          end

        _ ->
          acc ++
            [
              %ProjectConfigError{
                type: :missing_field,
                field: field,
                project_index: index,
                project_id: nil,
                message: "#{field} is required"
              }
            ]
      end
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
                message: "#{field} is not part of the M1 static project schema"
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
      case Map.get(project, field) do
        value when is_binary(value) ->
          if String.trim(value) == "" do
            acc
          else
            expanded = Path.expand(value)

            cond do
              Path.type(value) != :absolute ->
                acc ++ [invalid_path_error(field, index, project_id, "must be an absolute path")]

              path_escape?(value) ->
                acc ++ [unsafe_path_error(field, index, project_id, "must not contain path traversal segments")]

              true ->
                case PathSafety.canonicalize(expanded) do
                  {:ok, _canonical_path} ->
                    acc

                  {:error, {:path_canonicalize_failed, _path, reason}} ->
                    acc ++ [invalid_path_error(field, index, project_id, "failed to canonicalize path: #{inspect(reason)}")]
                end
            end
          end

        _ ->
          acc
      end
    end)
  end

  defp path_escape?(value) when is_binary(value) do
    value
    |> Path.split()
    |> Enum.any?(&(&1 == ".."))
  end

  defp duplicate_id_errors(projects) do
    duplicate_ids =
      projects
      |> Enum.group_by(fn {project, _index} -> project.id end)
      |> Enum.filter(fn {_id, entries} -> length(entries) > 1 end)
      |> Map.new()

    projects
    |> Enum.flat_map(fn {project, index} ->
      if Map.has_key?(duplicate_ids, project.id) do
        [
          %ProjectConfigError{
            type: :duplicate_project_id,
            field: "id",
            project_index: index,
            project_id: project.id,
            message: "duplicate project id: #{project.id}"
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
