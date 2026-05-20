defmodule SymphonyElixir.ProjectConfig do
  @moduledoc false

  @enforce_keys [:id, :name, :enabled, :worker_port, :workflow_generated, :workspace_root, :logs_root]
  defstruct [
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
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          enabled: boolean(),
          worker_port: non_neg_integer(),
          workflow_source: String.t() | nil,
          workflow_generated: String.t(),
          workspace_root: String.t(),
          logs_root: String.t(),
          project_slug: String.t() | nil,
          repo_url: String.t() | nil
        }
end
