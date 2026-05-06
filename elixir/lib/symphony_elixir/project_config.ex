defmodule SymphonyElixir.ProjectConfig do
  @moduledoc false

  @enforce_keys [:id, :name, :enabled, :worker_port, :workflow_generated, :workspace_root, :logs_root]
  defstruct [:id, :name, :enabled, :worker_port, :workflow_generated, :workspace_root, :logs_root]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          enabled: boolean(),
          worker_port: non_neg_integer(),
          workflow_generated: String.t(),
          workspace_root: String.t(),
          logs_root: String.t()
        }
end
