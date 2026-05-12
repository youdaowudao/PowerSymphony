defmodule SymphonyElixir.M3PrecheckTest do
  use SymphonyElixir.TestSupport

  test "disabled m3 explains that todo auto dispatch is not enabled" do
    issue = %Issue{id: "issue-todo-disabled", identifier: "MT-900", title: "Todo", state: "Todo"}

    result =
      SymphonyElixir.M3Precheck.run([issue], %{
        current_project_slug: "alpha",
        current_project_id: "project-alpha",
        m3_enabled: false,
        max_concurrent_agents: 1,
        active_running_count: 0,
        terminal_states: ["Done", "Closed"]
      })

    assert result.m3_enabled == false
    assert result.eligible == []
    assert result.dispatch == []
    assert result.blocked["MT-900"] == ["m3 disabled for project"]
    assert result.text =~ "M3 is disabled"
  end

  test "enabled m3 computes eligible dispatch set, structural errors, and warnings" do
    issues = [
      %Issue{
        id: "ready-older",
        identifier: "MT-901",
        title: "Ready older",
        state: "Todo",
        created_at: ~U[2026-05-01 00:00:00Z],
        blocked_by: [%{id: "done-1", identifier: "MT-910", state: "Done", project_slug: "alpha"}]
      },
      %Issue{
        id: "ready-no-deps",
        identifier: "MT-902",
        title: "Ready root",
        state: "Todo",
        created_at: ~U[2026-05-02 00:00:00Z],
        blocked_by: []
      },
      %Issue{
        id: "blocked-active",
        identifier: "MT-903",
        title: "Blocked by active issue",
        state: "Todo",
        created_at: ~U[2026-05-03 00:00:00Z],
        blocked_by: [%{id: "active-1", identifier: "MT-911", state: "In Progress", project_slug: "alpha"}]
      },
      %Issue{
        id: "self-cycle",
        identifier: "MT-904",
        title: "Self cycle",
        state: "Todo",
        created_at: ~U[2026-05-04 00:00:00Z],
        blocked_by: [%{id: "self-cycle", identifier: "MT-904", state: "Todo", project_slug: "alpha"}]
      },
      %Issue{
        id: "cross-project",
        identifier: "MT-905",
        title: "Cross project dependency",
        state: "Todo",
        created_at: ~U[2026-05-05 00:00:00Z],
        blocked_by: [%{id: "other-1", identifier: "OT-1", state: "Done", project_slug: "beta"}]
      },
      %Issue{
        id: "fan-in",
        identifier: "MT-906",
        title: "Fan in",
        state: "Todo",
        created_at: ~U[2026-05-06 00:00:00Z],
        blocked_by: [
          %{id: "done-2", identifier: "MT-912", state: "Done", project_slug: "alpha"},
          %{id: "done-3", identifier: "MT-913", state: "Done", project_slug: "alpha"}
        ]
      }
    ]

    result =
      SymphonyElixir.M3Precheck.run(issues, %{
        current_project_slug: "alpha",
        current_project_id: "project-alpha",
        m3_enabled: true,
        max_concurrent_agents: 2,
        active_running_count: 1,
        terminal_states: ["Done", "Closed"]
      })

    assert Enum.map(result.eligible, & &1.identifier) == ["MT-901", "MT-902", "MT-906"]
    assert Enum.map(result.dispatch, & &1.identifier) == ["MT-901"]
    assert result.blocked["MT-903"] == ["waiting on non-terminal blockers: MT-911"]
    assert result.blocked["MT-904"] == ["structural errors: self_dependency"]
    assert result.blocked["MT-905"] == ["structural errors: cross_project_dependency"]
    assert Enum.any?(result.structural_errors, &(&1.issue_identifier == "MT-904" and &1.type == :self_dependency))
    assert Enum.any?(result.structural_errors, &(&1.issue_identifier == "MT-905" and &1.type == :cross_project_dependency))
    assert "MT-906" in result.convergence_points
    assert "Todo without blockers: MT-902" in result.warnings
    assert "Eligible Todo waiting for free capacity: MT-902, MT-906" in result.warnings
    assert result.text =~ "Eligible Todo"
    assert result.text =~ "Dispatch this round"
  end
end
