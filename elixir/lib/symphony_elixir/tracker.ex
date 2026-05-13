defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias SymphonyElixir.{Config, RunTrace}

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    adapter().fetch_candidate_issues()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    result = adapter().create_comment(issue_id, body)

    RunTrace.record(:linear_tool, %{
      event: :create_comment,
      summary: "linear_tool:create_comment",
      payload: %{issue_id: issue_id, body: body, result: inspect(result)}
    })

    result
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    result = adapter().update_issue_state(issue_id, state_name)

    RunTrace.record(:linear_tool, %{
      event: :update_issue_state,
      summary: "linear_tool:update_issue_state",
      payload: %{issue_id: issue_id, state_name: state_name, result: inspect(result)}
    })

    result
  end

  @spec adapter() :: module()
  def adapter do
    case Application.get_env(:symphony_elixir, :tracker_adapter_override) do
      override when is_atom(override) and not is_nil(override) ->
        override

      _ ->
        case Config.settings!().tracker.kind do
          "memory" -> SymphonyElixir.Tracker.Memory
          _ -> SymphonyElixir.Linear.Adapter
        end
    end
  end
end
