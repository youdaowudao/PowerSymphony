defmodule SymphonyElixir.M3Precheck do
  @moduledoc """
  Pure computation for M3-0 Todo auto-dispatch eligibility and explanation.
  """

  alias SymphonyElixir.Linear.Issue

  @max_sort_key 9_223_372_036_854_775_807

  @type current_work_entry :: %{
          optional(:issue_id) => String.t() | nil,
          optional(:issue_identifier) => String.t() | nil,
          optional(:state) => String.t() | nil,
          optional(:worker_host) => String.t() | nil,
          optional(:workspace_path) => String.t() | nil
        }
  @type current_work :: %{
          count: non_neg_integer(),
          entries: [current_work_entry()]
        }
  @type anomaly :: %{
          type: :blocked_but_in_progress,
          issue_identifier: String.t() | nil,
          issue_id: String.t() | nil,
          state: String.t() | nil,
          blocking_identifiers: [String.t()]
        }
  @type result :: %{
          m3_enabled: boolean(),
          eligible: [Issue.t()],
          dispatch: [Issue.t()],
          blocked: %{optional(String.t()) => [String.t()]},
          eligible_todos: [Issue.t()],
          dispatched_todos: [Issue.t()],
          capacity_queued_todos: [Issue.t()],
          blocked_todos: %{optional(String.t()) => [String.t()]},
          current_work: current_work() | nil,
          anomalies: [anomaly()],
          structural_errors: [map()],
          warnings: [String.t()],
          convergence_points: [String.t()],
          text: String.t()
        }
  @type issue_key :: String.t()
  @type issue_lookup :: %{optional(issue_key()) => Issue.t()}
  @type visited_issue_keys :: %{optional(issue_key()) => true}

  @spec structural_errors_for_issue(Issue.t(), [Issue.t()], map()) :: [map()]
  def structural_errors_for_issue(%Issue{} = issue, issues, opts \\ %{})
      when is_list(issues) and is_map(opts) do
    current_project_slug = Map.get(opts, :current_project_slug, Map.get(opts, "current_project_slug"))
    current_project_id = Map.get(opts, :current_project_id, Map.get(opts, "current_project_id"))

    issue_structural_errors(issue, issues, current_project_slug, current_project_id)
  end

  @spec run([Issue.t()], map()) :: result()
  def run(issues, opts) when is_list(issues) and is_map(opts) do
    m3_enabled = Map.get(opts, :m3_enabled, Map.get(opts, "m3_enabled", false)) == true
    current_project_slug = Map.get(opts, :current_project_slug, Map.get(opts, "current_project_slug"))
    current_project_id = Map.get(opts, :current_project_id, Map.get(opts, "current_project_id"))
    terminal_states = terminal_state_set(Map.get(opts, :terminal_states, Map.get(opts, "terminal_states", [])))
    current_work = current_work_option(opts)
    max_concurrent_agents = Map.get(opts, :max_concurrent_agents, Map.get(opts, "max_concurrent_agents", 0))

    active_running_count =
      current_work_count(
        current_work,
        Map.get(opts, :active_running_count, Map.get(opts, "active_running_count", 0))
      )

    available_slots = max(max_concurrent_agents - active_running_count, 0)

    todo_issues = Enum.filter(issues, &todo_issue?/1)

    analysis =
      Enum.map(todo_issues, fn issue ->
        analyze_issue(
          issue,
          todo_issues,
          current_project_slug,
          current_project_id,
          terminal_states,
          m3_enabled,
          current_work
        )
      end)

    eligible =
      analysis
      |> Enum.filter(&(&1.reasons == []))
      |> Enum.map(& &1.issue)
      |> sort_todo_issues()

    dispatch = Enum.take(eligible, available_slots)
    capacity_queued = Enum.drop(eligible, length(dispatch))

    blocked =
      analysis
      |> Enum.filter(&(&1.reasons != []))
      |> Map.new(fn entry -> {entry.issue.identifier, entry.reasons} end)

    structural_errors =
      analysis
      |> Enum.flat_map(& &1.structural_errors)

    warnings =
      []
      |> maybe_add_warning(no_dependency_warning(eligible))
      |> maybe_add_warning(multiple_root_warning(eligible))
      |> maybe_add_warning(capacity_warning(eligible, dispatch))

    convergence_points =
      analysis
      |> Enum.filter(&(length(&1.terminal_blockers) > 1 and &1.reasons == []))
      |> Enum.map(& &1.issue.identifier)

    anomalies = blocked_but_in_progress_anomalies(issues, terminal_states)

    text =
      build_text(%{
        m3_enabled: m3_enabled,
        eligible: eligible,
        dispatch: dispatch,
        blocked: blocked,
        warnings: warnings,
        structural_errors: structural_errors,
        convergence_points: convergence_points
      })

    %{
      m3_enabled: m3_enabled,
      eligible: eligible,
      dispatch: dispatch,
      blocked: blocked,
      eligible_todos: eligible,
      dispatched_todos: dispatch,
      capacity_queued_todos: capacity_queued,
      blocked_todos: blocked,
      current_work: current_work,
      anomalies: anomalies,
      structural_errors: structural_errors,
      warnings: warnings,
      convergence_points: convergence_points,
      text: text
    }
  end

  defp analyze_issue(
         %Issue{} = issue,
         todo_issues,
         current_project_slug,
         current_project_id,
         terminal_states,
         m3_enabled,
         current_work
       ) do
    structural_errors =
      issue_structural_errors(issue, todo_issues, current_project_slug, current_project_id)

    blocker_analysis =
      Enum.reduce(issue.blocked_by || [], %{terminal: [], non_terminal: []}, fn blocker, acc ->
        classify_blocker(acc, issue, blocker, terminal_states)
      end)

    reasons =
      []
      |> maybe_add_reason(!m3_enabled, "m3 disabled for project")
      |> maybe_add_reason(issue_in_current_work?(issue, current_work), "already present in current work: #{issue.identifier || issue.id}")
      |> maybe_add_reason(structural_errors != [], "structural errors: " <> Enum.map_join(structural_errors, ", ", &Atom.to_string(&1.type)))
      |> maybe_add_reason(
        blocker_analysis.non_terminal != [],
        "waiting on non-terminal blockers: " <>
          Enum.map_join(Enum.reverse(blocker_analysis.non_terminal), ", ", &blocker_identifier/1)
      )

    %{
      issue: issue,
      reasons: Enum.filter(reasons, &is_binary/1),
      structural_errors: structural_errors,
      terminal_blockers: Enum.reverse(blocker_analysis.terminal)
    }
  end

  defp issue_structural_errors(%Issue{} = issue, todo_issues, current_project_slug, current_project_id) do
    self_dependency = self_dependency?(issue)
    cross_project_dependency = cross_project_dependency?(issue, current_project_slug, current_project_id)

    []
    |> maybe_add_structural_error(self_dependency, issue, :self_dependency)
    |> maybe_add_structural_error(cross_project_dependency, issue, :cross_project_dependency)
    |> maybe_add_structural_error(
      !self_dependency and !cross_project_dependency and cyclic_dependency?(issue, todo_issues),
      issue,
      :cyclic_dependency
    )
  end

  defp self_dependency?(%Issue{id: id, identifier: identifier, blocked_by: blockers}) when is_list(blockers) do
    Enum.any?(blockers, fn blocker ->
      blocker_self_reference?(%Issue{id: id, identifier: identifier}, blocker)
    end)
  end

  defp self_dependency?(_issue), do: false

  defp cross_project_dependency?(%Issue{blocked_by: blockers}, current_project_slug, current_project_id)
       when is_list(blockers) do
    Enum.any?(blockers, fn blocker ->
      blocker_project_slug = Map.get(blocker, :project_slug)
      blocker_project_id = Map.get(blocker, :project_id)

      cond do
        is_binary(blocker_project_slug) and is_binary(current_project_slug) ->
          blocker_project_slug != current_project_slug

        is_binary(blocker_project_id) and is_binary(current_project_id) ->
          blocker_project_id != current_project_id

        true ->
          false
      end
    end)
  end

  defp cross_project_dependency?(_issue, _current_project_slug, _current_project_id), do: false

  defp cyclic_dependency?(%Issue{} = issue, todo_issues) do
    todo_ids = build_issue_lookup(todo_issues, :id)
    todo_identifiers = build_issue_lookup(todo_issues, :identifier)

    Enum.any?(issue.blocked_by || [], fn blocker ->
      case find_blocker_issue(blocker, todo_ids, todo_identifiers) do
        %Issue{} = blocker_issue ->
          depends_on?(blocker_issue, issue, todo_ids, todo_identifiers, %{})

        nil ->
          false
      end
    end)
  end

  @spec build_issue_lookup([Issue.t()], :id | :identifier) :: issue_lookup()
  defp build_issue_lookup(issues, field) when field in [:id, :identifier] do
    Enum.reduce(issues, %{}, fn %Issue{} = candidate, acc ->
      case Map.get(candidate, field) do
        key when is_binary(key) -> Map.put(acc, key, candidate)
        _ -> acc
      end
    end)
  end

  @spec depends_on?(Issue.t(), Issue.t(), issue_lookup(), issue_lookup(), visited_issue_keys()) ::
          boolean()
  defp depends_on?(%Issue{} = current, %Issue{} = target, todo_ids, todo_identifiers, visited) do
    current_key = current.id || current.identifier

    cond do
      is_nil(current_key) ->
        false

      Map.has_key?(visited, current_key) ->
        false

      true ->
        next_visited = Map.put(visited, current_key, true)

        Enum.any?(current.blocked_by || [], fn blocker ->
          depends_on_blocker?(blocker, target, todo_ids, todo_identifiers, next_visited)
        end)
    end
  end

  defp classify_blocker(acc, issue, blocker, terminal_states) do
    cond do
      blocker_terminal?(blocker, terminal_states) ->
        %{acc | terminal: [blocker | acc.terminal]}

      blocker_self_reference?(issue, blocker) ->
        acc

      true ->
        %{acc | non_terminal: [blocker | acc.non_terminal]}
    end
  end

  @spec find_blocker_issue(map(), issue_lookup(), issue_lookup()) :: Issue.t() | nil
  defp find_blocker_issue(blocker, todo_ids, todo_identifiers) do
    Map.get(todo_ids, Map.get(blocker, :id)) ||
      Map.get(todo_identifiers, Map.get(blocker, :identifier))
  end

  @spec depends_on_blocker?(map(), Issue.t(), issue_lookup(), issue_lookup(), visited_issue_keys()) ::
          boolean()
  defp depends_on_blocker?(blocker, target, todo_ids, todo_identifiers, next_visited) do
    blocker_issue = find_blocker_issue(blocker, todo_ids, todo_identifiers)
    direct_match? = Map.get(blocker, :id) == target.id || Map.get(blocker, :identifier) == target.identifier

    direct_match? ||
      case blocker_issue do
        %Issue{} ->
          depends_on?(blocker_issue, target, todo_ids, todo_identifiers, next_visited)

        nil ->
          false
      end
  end

  defp blocker_terminal?(%{state: state}, terminal_states) when is_binary(state) do
    MapSet.member?(terminal_states, normalize_state(state))
  end

  defp blocker_terminal?(_blocker, _terminal_states), do: false

  defp todo_issue?(%Issue{state: state}) when is_binary(state), do: normalize_state(state) == "todo"
  defp todo_issue?(_issue), do: false

  defp blocked_but_in_progress_anomalies(issues, terminal_states) do
    issues
    |> Enum.filter(fn issue -> blocked_but_in_progress?(issue, terminal_states) end)
    |> sort_todo_issues()
    |> Enum.map(fn %Issue{} = issue ->
      %{
        type: :blocked_but_in_progress,
        issue_identifier: issue.identifier,
        issue_id: issue.id,
        state: issue.state,
        blocking_identifiers:
          issue.blocked_by
          |> Enum.reject(&blocker_terminal?(&1, terminal_states))
          |> Enum.map(&blocker_identifier/1)
      }
    end)
  end

  defp blocked_but_in_progress?(%Issue{state: state, blocked_by: blockers}, terminal_states)
       when is_binary(state) and is_list(blockers) do
    normalize_state(state) == "in progress" and
      Enum.any?(blockers, &(not blocker_terminal?(&1, terminal_states)))
  end

  defp blocked_but_in_progress?(_issue, _terminal_states), do: false

  defp issue_in_current_work?(%Issue{} = issue, %{entries: entries}) when is_list(entries) do
    Enum.any?(entries, fn entry ->
      current_work_matches_issue?(entry, issue)
    end)
  end

  defp issue_in_current_work?(_issue, _current_work), do: false

  defp current_work_matches_issue?(entry, %Issue{} = issue) when is_map(entry) do
    entry_issue_id = Map.get(entry, :issue_id)
    entry_issue_identifier = Map.get(entry, :issue_identifier)

    (is_binary(issue.id) and is_binary(entry_issue_id) and entry_issue_id == issue.id) or
      (is_binary(issue.identifier) and is_binary(entry_issue_identifier) and entry_issue_identifier == issue.identifier)
  end

  defp current_work_matches_issue?(_entry, _issue), do: false

  defp sort_todo_issues(issues) do
    Enum.sort_by(issues, &issue_sort_key/1)
  end

  defp issue_sort_key(%Issue{} = issue), do: {created_at_sort_key(issue), issue.identifier || issue.id || ""}
  defp issue_sort_key(_issue), do: {@max_sort_key, ""}

  defp created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}),
    do: DateTime.to_unix(created_at, :microsecond)

  defp created_at_sort_key(_issue), do: @max_sort_key

  defp current_work_option(opts) when is_map(opts) do
    cond do
      Map.has_key?(opts, :current_work) -> normalize_current_work(Map.get(opts, :current_work))
      Map.has_key?(opts, "current_work") -> normalize_current_work(Map.get(opts, "current_work"))
      true -> nil
    end
  end

  defp normalize_current_work(%{count: count, entries: entries}) do
    normalized_entries = normalize_current_work_entries(entries)
    %{count: normalize_count(count, normalized_entries), entries: normalized_entries}
  end

  defp normalize_current_work(%{"count" => count, "entries" => entries}) do
    normalized_entries = normalize_current_work_entries(entries)
    %{count: normalize_count(count, normalized_entries), entries: normalized_entries}
  end

  defp normalize_current_work(%{entries: entries}) do
    normalized_entries = normalize_current_work_entries(entries)
    %{count: length(normalized_entries), entries: normalized_entries}
  end

  defp normalize_current_work(%{"entries" => entries}) do
    normalized_entries = normalize_current_work_entries(entries)
    %{count: length(normalized_entries), entries: normalized_entries}
  end

  defp normalize_current_work(_current_work), do: %{count: 0, entries: []}

  defp normalize_current_work_entries(entries) when is_list(entries) do
    entries
    |> Enum.map(fn entry ->
      []
      |> maybe_put_current_work_value(:issue_id, Map.get(entry, :issue_id, Map.get(entry, "issue_id")))
      |> maybe_put_current_work_value(
        :issue_identifier,
        Map.get(entry, :issue_identifier, Map.get(entry, "issue_identifier"))
      )
      |> maybe_put_current_work_value(:state, Map.get(entry, :state, Map.get(entry, "state")))
      |> maybe_put_current_work_value(:worker_host, Map.get(entry, :worker_host, Map.get(entry, "worker_host")))
      |> maybe_put_current_work_value(
        :workspace_path,
        Map.get(entry, :workspace_path, Map.get(entry, "workspace_path"))
      )
      |> Map.new()
    end)
    |> Enum.sort_by(fn entry ->
      {Map.get(entry, :issue_identifier) || Map.get(entry, :issue_id) || "", Map.get(entry, :worker_host) || ""}
    end)
  end

  defp normalize_current_work_entries(_entries), do: []

  defp maybe_put_current_work_value(entries, _key, nil), do: entries
  defp maybe_put_current_work_value(entries, key, value), do: [{key, value} | entries]

  defp normalize_count(count, _entries) when is_integer(count) and count >= 0, do: count
  defp normalize_count(_count, entries), do: length(entries)

  defp current_work_count(%{count: count}, _fallback) when is_integer(count) and count >= 0, do: count
  defp current_work_count(_current_work, fallback) when is_integer(fallback) and fallback >= 0, do: fallback
  defp current_work_count(_current_work, _fallback), do: 0

  defp terminal_state_set(states) do
    states
    |> Enum.map(&normalize_state/1)
    |> MapSet.new()
  end

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: ""

  defp blocker_identifier(%{identifier: identifier}) when is_binary(identifier), do: identifier
  defp blocker_identifier(%{id: id}) when is_binary(id), do: id
  defp blocker_identifier(_blocker), do: "unknown"

  defp blocker_self_reference?(%Issue{id: id, identifier: identifier}, blocker) do
    Map.get(blocker, :id) == id or Map.get(blocker, :identifier) == identifier
  end

  defp maybe_add_reason(reasons, true, reason), do: [reason | reasons]
  defp maybe_add_reason(reasons, false, _reason), do: reasons

  defp maybe_add_structural_error(errors, true, issue, type) do
    [%{issue_identifier: issue.identifier, issue_id: issue.id, type: type} | errors]
  end

  defp maybe_add_structural_error(errors, false, _issue, _type), do: errors

  defp no_dependency_warning(eligible) do
    no_deps =
      eligible
      |> Enum.filter(fn issue -> (issue.blocked_by || []) == [] end)
      |> Enum.map(& &1.identifier)

    if no_deps == [], do: nil, else: "Todo without blockers: " <> Enum.join(no_deps, ", ")
  end

  defp multiple_root_warning(eligible) do
    if length(Enum.filter(eligible, fn issue -> (issue.blocked_by || []) == [] end)) > 1 do
      "Multiple independent Todo roots are ready in parallel"
    end
  end

  defp capacity_warning(eligible, dispatch) do
    waiting =
      eligible
      |> Enum.drop(length(dispatch))
      |> Enum.map(& &1.identifier)

    if waiting == [], do: nil, else: "Eligible Todo waiting for free capacity: " <> Enum.join(waiting, ", ")
  end

  defp maybe_add_warning(warnings, nil), do: warnings
  defp maybe_add_warning(warnings, warning), do: warnings ++ [warning]

  defp build_text(%{m3_enabled: false, blocked: blocked}) do
    """
    M3 is disabled for this project.
    Todo automatic dispatch is off.
    Blocked Todo:
    #{Enum.map_join(blocked, "\n", fn {identifier, reasons} -> "- #{identifier}: #{Enum.join(reasons, "; ")}" end)}
    """
    |> String.trim()
  end

  defp build_text(result) do
    """
    Eligible Todo:
    #{format_issue_list(result.eligible)}

    Dispatch this round:
    #{format_issue_list(result.dispatch)}

    Blocked Todo:
    #{Enum.map_join(result.blocked, "\n", fn {identifier, reasons} -> "- #{identifier}: #{Enum.join(reasons, "; ")}" end)}

    Convergence points:
    #{format_string_list(result.convergence_points)}

    Structural errors:
    #{Enum.map_join(result.structural_errors, "\n", fn error -> "- #{error.issue_identifier}: #{error.type}" end)}

    Warnings:
    #{format_string_list(result.warnings)}
    """
    |> String.trim()
  end

  defp format_issue_list([]), do: "(none)"
  defp format_issue_list(issues), do: Enum.map_join(issues, "\n", &"- #{&1.identifier}")

  defp format_string_list([]), do: "(none)"
  defp format_string_list(values), do: Enum.map_join(values, "\n", &"- #{&1}")
end
