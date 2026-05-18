defmodule SymphonyElixir.Linear.IssueDiff do
  @moduledoc """
  Produces a partial diff summary from two `%SymphonyElixir.Linear.Issue{}` snapshots.
  """

  alias SymphonyElixir.Linear.Issue

  @typedoc "Top-level conclusion for the observed issue snapshot fields."
  @type status ::
          :issue_snapshot_changed
          | :issue_snapshot_unchanged
          | :issue_snapshot_unavailable

  @type summary :: %{
          status: status(),
          status_text: String.t(),
          observed_changes: [String.t()],
          updated_at_changed?: boolean(),
          notes: [String.t()]
        }

  @observed_fields [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    :project_id,
    :project_slug,
    :blocked_by,
    :labels,
    :assigned_to_worker,
    :created_at
  ]
  @scope_note "Partial observation only: compares the current %SymphonyElixir.Linear.Issue{} snapshot fields."
  @coverage_note "Not covered in v1: comments, threads, description/body revision history, or other unobserved objects."

  @spec describe(Issue.t(), Issue.t()) :: summary()
  def describe(%Issue{} = previous, %Issue{} = current) do
    {observed_changes, unavailable_notes} =
      Enum.reduce(@observed_fields, {[], []}, fn field, {changes, unavailable} ->
        previous_value = Map.get(previous, field)
        current_value = Map.get(current, field)

        case compare_field(field, previous_value, current_value) do
          :equal ->
            {changes, unavailable}

          {:changed, change_line} ->
            {[change_line | changes], unavailable}

          {:unavailable, note} ->
            {changes, [note | unavailable]}
        end
      end)

    updated_at_changed? =
      comparable_value(previous.updated_at) != comparable_value(current.updated_at)

    observed_changes = Enum.reverse(observed_changes)
    unavailable_notes = Enum.reverse(unavailable_notes)

    status = status_for(observed_changes, unavailable_notes)

    %{
      status: status,
      status_text: Atom.to_string(status),
      observed_changes: observed_changes,
      updated_at_changed?: updated_at_changed?,
      notes:
        notes_for(
          status,
          previous.updated_at,
          current.updated_at,
          updated_at_changed?,
          unavailable_notes
        )
    }
  end

  @spec summary(Issue.t(), Issue.t()) :: String.t()
  def summary(%Issue{} = previous, %Issue{} = current) do
    diff = describe(previous, current)

    [
      "Result: #{diff.status_text}",
      "Observation scope:",
      "- #{@scope_note}",
      "- #{@coverage_note}",
      observed_changes_block(diff.observed_changes),
      notes_block(diff.notes)
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp observed_changes_block([]), do: ["Observed field changes:", "- none"]
  defp observed_changes_block(changes), do: ["Observed field changes:" | changes]

  defp notes_block([]), do: []
  defp notes_block(notes), do: ["Notes:" | Enum.map(notes, &"- #{&1}")]

  defp status_for(_observed_changes, unavailable_notes) when unavailable_notes != [],
    do: :issue_snapshot_unavailable

  defp status_for([], []), do: :issue_snapshot_unchanged
  defp status_for(_observed_changes, []), do: :issue_snapshot_changed

  defp notes_for(
         :issue_snapshot_changed,
         _previous_updated_at,
         _current_updated_at,
         _updated_at_changed?,
         _unavailable_notes
       ),
       do: []

  defp notes_for(:issue_snapshot_unchanged, previous_updated_at, current_updated_at, true, []) do
    [
      "No observed %SymphonyElixir.Linear.Issue{} snapshot field changes.",
      "#{render_field_name(:updated_at)} changed from #{render_value(previous_updated_at)} to #{render_value(current_updated_at)}, but that alone is not treated as a semantic field change.",
      "This may still reflect v1-unobserved changes such as comments, threads, or body revisions."
    ]
  end

  defp notes_for(:issue_snapshot_unchanged, _previous_updated_at, _current_updated_at, false, []) do
    ["No observed %SymphonyElixir.Linear.Issue{} snapshot field changes."]
  end

  defp notes_for(
         :issue_snapshot_unavailable,
         previous_updated_at,
         current_updated_at,
         updated_at_changed?,
         unavailable_notes
       ) do
    base_notes = [
      "Observed snapshot comparison degraded: at least one field was not safely compared, so this is not a normal changed/unchanged conclusion."
      | unavailable_notes
    ]

    if updated_at_changed? do
      base_notes ++
        [
          "#{render_field_name(:updated_at)} changed from #{render_value(previous_updated_at)} to #{render_value(current_updated_at)}, but that alone is not treated as a semantic field change."
        ]
    else
      base_notes
    end
  end

  defp compare_field(field, previous_value, current_value) do
    with {:ok, previous_comparable} <- comparable_value_for_field(previous_value, field),
         {:ok, current_comparable} <- comparable_value_for_field(current_value, field) do
      if previous_comparable == current_comparable do
        :equal
      else
        {:changed, render_change(field, previous_value, current_value)}
      end
    else
      {:error, reason} ->
        {:unavailable, "#{render_field_name(field)} was not safely compared because #{reason}; treat this as unavailable/not_yet_observed for the current snapshot conclusion."}
    end
  end

  defp render_change(:description, previous_value, current_value) do
    "- description: #{render_text_summary(previous_value)} -> #{render_text_summary(current_value)}"
  end

  defp render_change(field, previous_value, current_value) do
    "- #{field}: #{render_value(previous_value, field)} -> #{render_value(current_value, field)}"
  end

  defp comparable_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp comparable_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp comparable_value(%Date{} = value), do: Date.to_iso8601(value)
  defp comparable_value(%Time{} = value), do: Time.to_iso8601(value)
  defp comparable_value(value) when is_list(value), do: Enum.map(value, &comparable_value/1)
  defp comparable_value(value) when is_map(value), do: Enum.into(value, %{}, fn {key, val} -> {key, comparable_value(val)} end)
  defp comparable_value(value), do: value

  defp comparable_value(value, :labels) when is_list(value) do
    value
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp comparable_value(value, :blocked_by) when is_list(value) do
    case normalize_blockers(value) do
      {:ok, blockers} ->
        blockers
        |> Enum.sort_by(fn %{id: id, state: state} -> {id, state} end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp comparable_value(value, field) when is_atom(field), do: comparable_value(value)

  defp comparable_value_for_field(value, :blocked_by) when is_list(value) do
    case comparable_value(value, :blocked_by) do
      {:error, reason} -> {:error, reason}
      comparable -> {:ok, comparable}
    end
  end

  defp comparable_value_for_field(value, field) when is_atom(field), do: {:ok, comparable_value(value, field)}

  defp render_field_name(field), do: Atom.to_string(field)

  defp render_value(%DateTime{} = value, _field), do: inspect(DateTime.to_iso8601(value))
  defp render_value(%NaiveDateTime{} = value, _field), do: inspect(NaiveDateTime.to_iso8601(value))
  defp render_value(%Date{} = value, _field), do: inspect(Date.to_iso8601(value))
  defp render_value(%Time{} = value, _field), do: inspect(Time.to_iso8601(value))
  defp render_value(value, field) when is_atom(field), do: inspect(comparable_value(value, field), pretty: true)
  defp render_value(value), do: render_value(value, :generic)

  defp render_text_summary(value) when is_binary(value) do
    length = String.length(value)
    prefix = String.slice(value, 0, 24)
    suffix = String.slice(value, max(length - 24, 0), 24)
    digest = :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) |> binary_part(0, 12)

    inspect("text summary(len=#{length}, sha256=#{digest}, prefix=#{prefix}, suffix=#{suffix})")
  end

  defp render_text_summary(nil), do: inspect("text summary(nil)")

  defp normalize_blockers(blockers) when is_list(blockers) do
    Enum.reduce_while(blockers, {:ok, []}, fn blocker, {:ok, acc} ->
      case normalize_blocker(blocker) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_blocker(%{id: id, state: state}) when not is_nil(id) and not is_nil(state),
    do: {:ok, %{id: id, state: state}}

  defp normalize_blocker(%{"id" => id, "state" => state}) when not is_nil(id) and not is_nil(state),
    do: {:ok, %{id: id, state: state}}

  defp normalize_blocker(other),
    do: {:error, "blocked_by contains an entry without stable id/state keys: #{inspect(other)}"}
end
