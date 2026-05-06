defmodule SymphonyElixir.ProjectRegistry do
  @moduledoc """
  M1 project registry for the control plane.
  """

  alias SymphonyElixir.{ProjectConfig, ProjectConfigError, ProjectConfigStore}

  defmodule Entry do
    @moduledoc false

    @enforce_keys [
      :project_id,
      :project_name,
      :normalized_config,
      :validation_result,
      :validation_errors,
      :runtime_state
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            project_id: String.t() | nil,
            project_name: String.t() | nil,
            normalized_config: ProjectConfig.t() | nil,
            validation_result: :valid | :invalid,
            validation_errors: [ProjectConfigError.t()],
            runtime_state: %{status: :not_started}
          }
  end

  @enforce_keys [:entries]
  defstruct @enforce_keys

  @type t :: %__MODULE__{entries: [Entry.t()]}

  @spec load(Path.t()) :: {:ok, t()} | {:error, [ProjectConfigError.t()]}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, yaml} -> build(yaml)
      {:error, reason} -> file_read_error(reason)
    end
  end

  @spec build(String.t()) :: {:ok, t()} | {:error, [ProjectConfigError.t()]}
  def build(yaml) when is_binary(yaml) do
    with {:ok, projects} <- ProjectConfigStore.decode_projects(yaml) do
      {:ok, %__MODULE__{entries: build_entries(projects)}}
    end
  end

  @spec invalid_registry([ProjectConfigError.t()]) :: t()
  def invalid_registry(errors) when is_list(errors) do
    %__MODULE__{
      entries: [
        %Entry{
          project_id: nil,
          project_name: nil,
          normalized_config: nil,
          validation_result: :invalid,
          validation_errors: errors,
          runtime_state: %{status: :not_started}
        }
      ]
    }
  end

  @spec entries(t()) :: [Entry.t()]
  def entries(%__MODULE__{entries: entries}), do: entries

  @spec find_entry(t(), String.t()) :: Entry.t() | nil
  def find_entry(%__MODULE__{} = registry, project_id) when is_binary(project_id) do
    Enum.find(entries(registry), &(&1.project_id == project_id))
  end

  defp build_entries(projects) do
    projects
    |> ProjectConfigStore.validate_raw_projects()
    |> Enum.zip(projects)
    |> Enum.map(fn {validation, project} ->
      %Entry{
        project_id: project_id(project),
        project_name: project_name(project),
        normalized_config: validation.normalized_config,
        validation_result: validation_result(validation.validation_errors),
        validation_errors: validation.validation_errors,
        runtime_state: %{status: :not_started}
      }
    end)
  end

  defp validation_result([]), do: :valid
  defp validation_result(_errors), do: :invalid

  defp project_id(%{} = project), do: string_or_nil(Map.get(project, "id"))
  defp project_id(_project), do: nil

  defp project_name(%{} = project), do: string_or_nil(Map.get(project, "name"))
  defp project_name(_project), do: nil

  defp string_or_nil(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp string_or_nil(_value), do: nil

  defp file_read_error(reason) do
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
