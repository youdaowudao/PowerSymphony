defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, Workflow}
  alias SymphonyElixir.Linear.IssueDiff

  @render_opts [strict_variables: true, strict_filters: true]
  @checking_recheck_prompt """
  Checking recheck only:

  - This is a bounded `Checking` recheck thread, not a normal implementation run.
  - Read and act on only three signal classes:
    1. latest PR merge status
    2. latest head SHA required checks
    3. the newest human review delta
  - Do not resume broad implementation, planning, or repository-wide execution beyond what is required to evaluate those three signals safely.
  - If merge is complete, move to `Done`.
  - If latest head SHA required checks reached a non-success terminal state, move to `In Progress`.
  - If automation cannot safely continue, move to `Human Review`.
  - Otherwise keep the issue in `Checking` and end this short recheck.
  """

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    if Keyword.get(opts, :run_mode) == :checking_recheck do
      build_checking_recheck_prompt(issue)
    else
      template =
        Workflow.current()
        |> prompt_template!()
        |> parse_template!()

      template
      |> Solid.render!(
        %{
          "attempt" => Keyword.get(opts, :attempt),
          "issue" => issue |> Map.from_struct() |> to_solid_map()
        },
        @render_opts
      )
      |> IO.iodata_to_binary()
    end
  end

  @spec build_continuation_prompt(
          SymphonyElixir.Linear.Issue.t(),
          SymphonyElixir.Linear.Issue.t(),
          pos_integer(),
          pos_integer()
        ) :: String.t()
  def build_continuation_prompt(previous_issue, current_issue, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.

    Issue snapshot diff since last turn:
    #{IssueDiff.summary(previous_issue, current_issue)}
    """
  end

  defp build_checking_recheck_prompt(issue) do
    """
    #{@checking_recheck_prompt}

    Issue context:
    Identifier: #{issue.identifier}
    Title: #{issue.title}
    Current status: #{issue.state}
    URL: #{issue.url}
    """
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
