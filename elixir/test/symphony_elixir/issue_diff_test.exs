defmodule SymphonyElixir.IssueDiffTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.{Issue, IssueDiff}

  test "describe returns issue_snapshot_unchanged when snapshots match" do
    issue = %Issue{
      id: "issue-1",
      identifier: "MT-1",
      title: "Stable title",
      description: "Stable description",
      priority: 2,
      state: "In Progress",
      branch_name: "feature/stable-title",
      url: "https://example.org/issues/MT-1",
      assignee_id: "user-1",
      project_id: "project-1",
      project_slug: "project",
      blocked_by: [%{id: "blocker-1", state: "Done"}],
      labels: ["backend"],
      assigned_to_worker: true,
      created_at: DateTime.from_naive!(~N[2026-05-18 08:00:00], "Etc/UTC"),
      updated_at: DateTime.from_naive!(~N[2026-05-18 09:00:00], "Etc/UTC")
    }

    assert %{
             status: :issue_snapshot_unchanged,
             status_text: "issue_snapshot_unchanged",
             observed_changes: [],
             updated_at_changed?: false,
             notes: ["No observed %SymphonyElixir.Linear.Issue{} snapshot field changes."]
           } = IssueDiff.describe(issue, issue)
  end

  test "describe reports issue_snapshot_changed for semantic field changes" do
    previous = %Issue{
      id: "issue-2",
      identifier: "MT-2",
      title: "Old title",
      description: "Stable description",
      state: "Todo",
      labels: ["backend"]
    }

    current = %Issue{
      previous
      | title: "New title",
        state: "In Progress",
        labels: ["backend", "urgent"]
    }

    summary = IssueDiff.describe(previous, current)

    assert summary.status == :issue_snapshot_changed
    assert summary.status_text == "issue_snapshot_changed"
    assert summary.notes == []
    assert ~s(- title: "Old title" -> "New title") in summary.observed_changes
    assert ~s(- state: "Todo" -> "In Progress") in summary.observed_changes
    assert ~s(- labels: ["backend"] -> ["backend", "urgent"]) in summary.observed_changes
  end

  test "describe keeps issue_snapshot_unchanged for updated_at-only changes and flags downgraded coverage" do
    previous = %Issue{
      id: "issue-3",
      identifier: "MT-3",
      title: "Updated timestamp only",
      state: "In Progress",
      updated_at: DateTime.from_naive!(~N[2026-05-18 09:00:00], "Etc/UTC")
    }

    current = %Issue{
      previous
      | updated_at: DateTime.from_naive!(~N[2026-05-18 10:00:00], "Etc/UTC")
    }

    assert %{
             status: :issue_snapshot_unchanged,
             status_text: "issue_snapshot_unchanged",
             observed_changes: [],
             updated_at_changed?: true,
             notes: notes
           } = IssueDiff.describe(previous, current)

    assert Enum.any?(notes, &String.contains?(&1, "updated_at changed"))
    assert Enum.any?(notes, &String.contains?(&1, "not treated as a semantic field change"))
    assert Enum.any?(notes, &String.contains?(&1, "v1-unobserved changes"))
  end

  test "describe normalizes collection fields before comparison" do
    previous = %Issue{
      id: "issue-4",
      identifier: "MT-4",
      title: "Collection order only",
      labels: ["backend", "urgent"],
      blocked_by: [%{id: "b-1", state: "Todo"}, %{id: "b-2", state: "Done"}]
    }

    current = %Issue{
      previous
      | labels: ["urgent", "backend"],
        blocked_by: [%{id: "b-2", state: "Done"}, %{id: "b-1", state: "Todo"}]
    }

    assert %{
             status: :issue_snapshot_unchanged,
             status_text: "issue_snapshot_unchanged",
             observed_changes: []
           } = IssueDiff.describe(previous, current)
  end

  test "describe marks long text changes as summarized without leaking the full text" do
    previous_description = String.duplicate("old-paragraph-", 30)
    current_description = String.duplicate("new-paragraph-", 30)

    previous = %Issue{id: "issue-5", identifier: "MT-5", description: previous_description}
    current = %Issue{previous | description: current_description}

    summary = IssueDiff.describe(previous, current)

    assert summary.status == :issue_snapshot_changed
    assert Enum.any?(summary.observed_changes, &String.contains?(&1, "description"))
    refute Enum.any?(summary.observed_changes, &String.contains?(&1, previous_description))
    refute Enum.any?(summary.observed_changes, &String.contains?(&1, current_description))
    assert Enum.any?(summary.observed_changes, &String.contains?(&1, "text summary"))
  end

  test "describe treats description nil/string transitions as changed without leaking full text" do
    filled_description = String.duplicate("filled-body-", 25)

    nil_to_string_previous = %Issue{id: "issue-5a", identifier: "MT-5A", description: nil}
    nil_to_string_current = %Issue{nil_to_string_previous | description: filled_description}

    string_to_nil_previous = %Issue{id: "issue-5b", identifier: "MT-5B", description: filled_description}
    string_to_nil_current = %Issue{string_to_nil_previous | description: nil}

    nil_to_string_summary = IssueDiff.describe(nil_to_string_previous, nil_to_string_current)
    string_to_nil_summary = IssueDiff.describe(string_to_nil_previous, string_to_nil_current)

    assert nil_to_string_summary.status == :issue_snapshot_changed
    assert string_to_nil_summary.status == :issue_snapshot_changed

    assert Enum.any?(nil_to_string_summary.observed_changes, &String.contains?(&1, "description"))
    assert Enum.any?(string_to_nil_summary.observed_changes, &String.contains?(&1, "description"))

    refute Enum.any?(nil_to_string_summary.observed_changes, &String.contains?(&1, filled_description))
    refute Enum.any?(string_to_nil_summary.observed_changes, &String.contains?(&1, filled_description))
  end

  test "describe treats nil to value and value to nil as ordinary snapshot changes" do
    previous = %Issue{
      id: "issue-6",
      identifier: "MT-6",
      assignee_id: nil,
      branch_name: "feature/x",
      project_id: nil
    }

    current = %Issue{
      previous
      | assignee_id: "user-1",
        branch_name: nil,
        project_id: "proj-1"
    }

    summary = IssueDiff.describe(previous, current)

    assert summary.status == :issue_snapshot_changed
    assert summary.status_text == "issue_snapshot_changed"
    assert ~s(- assignee_id: nil -> "user-1") in summary.observed_changes
    assert ~s(- branch_name: "feature/x" -> nil) in summary.observed_changes
    assert ~s(- project_id: nil -> "proj-1") in summary.observed_changes
  end

  test "describe keeps explicit unavailable path for truly unsafe blocked_by shapes" do
    previous = %Issue{
      id: "issue-7",
      identifier: "MT-7",
      blocked_by: [%{id: "b-1", state: "Todo"}]
    }

    current = %Issue{
      previous
      | blocked_by: [%{state: "Todo"}]
    }

    assert %{
             status: :issue_snapshot_unavailable,
             status_text: "issue_snapshot_unavailable",
             observed_changes: [],
             notes: notes
           } = IssueDiff.describe(previous, current)

    assert Enum.any?(notes, &String.contains?(&1, "blocked_by"))
    assert Enum.any?(notes, &String.contains?(&1, "not safely compared"))
  end

  test "describe includes updated_at note when unavailable comparison also sees updated_at change" do
    previous = %Issue{
      id: "issue-8",
      identifier: "MT-8",
      blocked_by: [%{id: "b-1", state: "Todo"}],
      updated_at: DateTime.from_naive!(~N[2026-05-18 09:00:00], "Etc/UTC")
    }

    current = %Issue{
      previous
      | blocked_by: [%{state: "Todo"}],
        updated_at: DateTime.from_naive!(~N[2026-05-18 10:00:00], "Etc/UTC")
    }

    assert %{status: :issue_snapshot_unavailable, notes: notes} = IssueDiff.describe(previous, current)

    assert Enum.any?(notes, &String.contains?(&1, "blocked_by"))
    assert Enum.any?(notes, &String.contains?(&1, "updated_at changed"))
  end

  test "describe compares and renders date-like fields and string-key blockers" do
    previous = %Issue{
      id: "issue-9",
      identifier: "MT-9",
      blocked_by: [%{"id" => "b-1", "state" => "Todo"}],
      created_at: DateTime.from_naive!(~N[2026-05-18 08:00:00], "Etc/UTC"),
      priority: ~D[2026-05-18],
      state: ~T[08:30:00],
      title: ~N[2026-05-18 08:30:00]
    }

    current = %Issue{
      previous
      | blocked_by: [%{"id" => "b-2", "state" => "Done"}],
        priority: ~D[2026-05-19],
        state: ~T[09:30:00],
        title: ~N[2026-05-19 09:30:00]
    }

    summary = IssueDiff.describe(previous, current)

    assert summary.status == :issue_snapshot_changed
    assert ~s(- blocked_by: [%{id: "b-1", state: "Todo"}] -> [%{id: "b-2", state: "Done"}]) in summary.observed_changes
    assert ~s(- priority: "2026-05-18" -> "2026-05-19") in summary.observed_changes
    assert ~s(- state: "08:30:00" -> "09:30:00") in summary.observed_changes
    assert ~s(- title: "2026-05-18T08:30:00" -> "2026-05-19T09:30:00") in summary.observed_changes
  end

  test "describe unchanged path covers false updated_at branch and generic structured values" do
    shared_datetime = DateTime.from_naive!(~N[2026-05-18 08:00:00], "Etc/UTC")

    previous = %Issue{
      id: "issue-10",
      identifier: "MT-10",
      description: %{"nested" => ["a", %{flag: true}]},
      priority: %{score: 1},
      state: [1, 2, 3],
      branch_name: nil,
      url: nil,
      assignee_id: nil,
      project_id: nil,
      project_slug: nil,
      blocked_by: [],
      labels: [],
      assigned_to_worker: true,
      created_at: shared_datetime,
      updated_at: shared_datetime
    }

    current = %Issue{previous | created_at: shared_datetime, updated_at: shared_datetime}

    assert %{
             status: :issue_snapshot_unchanged,
             status_text: "issue_snapshot_unchanged",
             observed_changes: [],
             updated_at_changed?: false,
             notes: ["No observed %SymphonyElixir.Linear.Issue{} snapshot field changes."]
           } = IssueDiff.describe(previous, current)
  end

  test "describe renders datetime field changes with iso8601 strings" do
    previous = %Issue{
      id: "issue-11",
      identifier: "MT-11",
      created_at: DateTime.from_naive!(~N[2026-05-18 08:00:00], "Etc/UTC")
    }

    current = %Issue{
      previous
      | created_at: DateTime.from_naive!(~N[2026-05-19 09:00:00], "Etc/UTC")
    }

    summary = IssueDiff.describe(previous, current)

    assert summary.status == :issue_snapshot_changed
    assert ~s(- created_at: "2026-05-18T08:00:00Z" -> "2026-05-19T09:00:00Z") in summary.observed_changes
  end

  test "summary renders changed snapshots with observed change lines and no notes block" do
    previous = %Issue{
      id: "issue-12",
      identifier: "MT-12",
      title: "Old title",
      state: "Todo"
    }

    current = %Issue{
      previous
      | title: "New title",
        state: "In Progress"
    }

    summary = IssueDiff.summary(previous, current)

    assert summary =~ "Result: issue_snapshot_changed"
    assert summary =~ "Observation scope:"
    assert summary =~ "Observed field changes:"
    assert summary =~ ~s(- title: "Old title" -> "New title")
    assert summary =~ ~s(- state: "Todo" -> "In Progress")
    refute summary =~ "Notes:"
    refute summary =~ "- none"
  end

  test "summary renders unchanged snapshots with none marker and notes block" do
    issue = %Issue{
      id: "issue-13",
      identifier: "MT-13",
      title: "Stable title",
      description: "Stable description",
      state: "In Progress"
    }

    summary = IssueDiff.summary(issue, issue)

    assert summary =~ "Result: issue_snapshot_unchanged"
    assert summary =~ "Observed field changes:"
    assert summary =~ "- none"
    assert summary =~ "Notes:"
    assert summary =~ "No observed %SymphonyElixir.Linear.Issue{} snapshot field changes."
  end
end
