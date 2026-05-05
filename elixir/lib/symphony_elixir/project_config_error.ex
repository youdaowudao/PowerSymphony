defmodule SymphonyElixir.ProjectConfigError do
  @moduledoc false

  @enforce_keys [:type, :message]
  defstruct [:type, :message, :field, :project_index, :project_id]

  @type error_type ::
          :yaml_parse_error
          | :missing_field
          | :invalid_field
          | :duplicate_project_id
          | :unsafe_path

  @type t :: %__MODULE__{
          type: error_type(),
          message: String.t(),
          field: String.t() | nil,
          project_index: non_neg_integer() | nil,
          project_id: String.t() | nil
        }
end
