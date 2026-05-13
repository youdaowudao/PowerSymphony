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
        current_work: %{
          count: 1,
          entries: [
            %{
              issue_id: "running-1",
              issue_identifier: "RUN-1",
              state: "In Progress"
            }
          ]
        },
        terminal_states: ["Done", "Closed"]
      })

    assert Enum.map(result.eligible, & &1.identifier) == ["MT-901", "MT-902", "MT-906"]
    assert Enum.map(result.dispatch, & &1.identifier) == ["MT-901"]
    assert Enum.map(result.eligible_todos, & &1.identifier) == ["MT-901", "MT-902", "MT-906"]
    assert Enum.map(result.dispatched_todos, & &1.identifier) == ["MT-901"]
    assert Enum.map(result.capacity_queued_todos, & &1.identifier) == ["MT-902", "MT-906"]
    assert Map.keys(result.blocked_todos) == ["MT-903", "MT-904", "MT-905"]
    assert result.blocked["MT-903"] == ["waiting on non-terminal blockers: MT-911"]
    assert result.blocked["MT-904"] == ["structural errors: self_dependency"]
    assert result.blocked["MT-905"] == ["structural errors: cross_project_dependency"]
    assert result.current_work.count == 1

    assert result.current_work.entries == [
             %{issue_id: "running-1", issue_identifier: "RUN-1", state: "In Progress"}
           ]

    assert result.anomalies == []
    assert Enum.any?(result.structural_errors, &(&1.issue_identifier == "MT-904" and &1.type == :self_dependency))
    assert Enum.any?(result.structural_errors, &(&1.issue_identifier == "MT-905" and &1.type == :cross_project_dependency))
    assert "MT-906" in result.convergence_points
    assert "Todo without blockers: MT-902" in result.warnings
    assert "Eligible Todo waiting for free capacity: MT-902, MT-906" in result.warnings
    assert result.text =~ "Eligible Todo"
    assert result.text =~ "Dispatch this round"
  end

  test "enabled m3 renders empty text sections as none when there are no todo issues" do
    result =
      SymphonyElixir.M3Precheck.run([], %{
        current_project_slug: "alpha",
        current_project_id: "project-alpha",
        m3_enabled: true,
        max_concurrent_agents: 1,
        active_running_count: 0,
        terminal_states: [123, " Done "]
      })

    assert result.eligible == []
    assert result.dispatch == []
    assert result.eligible_todos == []
    assert result.dispatched_todos == []
    assert result.capacity_queued_todos == []
    assert result.blocked_todos == %{}
    assert result.current_work == %{count: 0, entries: []}
    assert result.anomalies == []
    assert result.blocked == %{}
    assert result.structural_errors == []
    assert result.warnings == []
    assert result.convergence_points == []
    assert result.text =~ "Eligible Todo:\n(none)"
    assert result.text =~ "Dispatch this round:\n(none)"
    assert result.text =~ "Convergence points:\n(none)"
    assert result.text =~ "Warnings:\n(none)"
  end

  test "structural_errors_for_issue handles nil blockers fallback and project_id cross-project blockers" do
    no_blockers_issue = %Issue{id: "issue-no-blockers", identifier: "MT-920", state: "Todo", blocked_by: nil}

    cross_project_issue = %Issue{
      id: "issue-cross-project-id",
      identifier: "MT-921",
      state: "Todo",
      blocked_by: [%{id: "dep-1", identifier: "DEP-1", state: "Done", project_id: "project-beta"}]
    }

    assert SymphonyElixir.M3Precheck.structural_errors_for_issue(no_blockers_issue, [], %{
             current_project_slug: "alpha",
             current_project_id: "project-alpha"
           }) == []

    assert [
             %{
               issue_identifier: "MT-921",
               issue_id: "issue-cross-project-id",
               type: :cross_project_dependency
             }
           ] =
             SymphonyElixir.M3Precheck.structural_errors_for_issue(cross_project_issue, [cross_project_issue], %{
               current_project_slug: nil,
               current_project_id: "project-alpha"
             })
  end

  test "run reports blocker identifiers fallback paths and structural checks handle missing blockers and reachable cycles" do
    blocked_with_fallback_identifiers = %Issue{
      id: "issue-blocked",
      identifier: "MT-930",
      title: "Blocked with fallback identifiers",
      state: "  todo  ",
      blocked_by: [
        %{id: "dep-id-only", state: " In Progress "},
        %{state: "In Progress"}
      ]
    }

    missing_blocker_issue = %Issue{
      id: "issue-missing",
      identifier: "MT-931",
      state: "Todo",
      blocked_by: [%{id: "missing-dep", state: "Todo"}]
    }

    cycle_issue_a = %Issue{
      id: "cycle-a",
      identifier: "MT-932",
      state: "Todo",
      blocked_by: [%{id: "cycle-b", identifier: "MT-933", state: "Todo"}]
    }

    cycle_issue_b = %Issue{
      id: "cycle-b",
      identifier: "MT-933",
      state: "Todo",
      blocked_by: [%{id: "cycle-a", identifier: "MT-932", state: "Todo"}]
    }

    result =
      SymphonyElixir.M3Precheck.run([blocked_with_fallback_identifiers], %{
        current_project_slug: "alpha",
        current_project_id: "project-alpha",
        m3_enabled: true,
        max_concurrent_agents: 1,
        active_running_count: 0,
        terminal_states: [" done "]
      })

    assert result.blocked["MT-930"] == ["waiting on non-terminal blockers: dep-id-only, unknown"]

    assert SymphonyElixir.M3Precheck.structural_errors_for_issue(missing_blocker_issue, [missing_blocker_issue], %{
             current_project_slug: "alpha",
             current_project_id: "project-alpha"
           }) == []

    assert [
             %{
               issue_identifier: "MT-932",
               issue_id: "cycle-a",
               type: :cyclic_dependency
             }
           ] =
             SymphonyElixir.M3Precheck.structural_errors_for_issue(
               cycle_issue_a,
               [cycle_issue_a, cycle_issue_b],
               %{
                 current_project_slug: "alpha",
                 current_project_id: "project-alpha"
               }
             )
  end

  test "structural_errors_for_issue/2 follows recursive blocker chains and ignores unkeyed todo issues" do
    invalid_lookup_issue = %Issue{id: 123, identifier: nil, state: "Todo", blocked_by: []}

    cycle_issue_a = %Issue{
      id: "cycle-a",
      identifier: "MT-940",
      state: "Todo",
      blocked_by: [%{id: "cycle-b", identifier: "MT-941", state: "Todo"}]
    }

    cycle_issue_b = %Issue{
      id: "cycle-b",
      identifier: "MT-941",
      state: "Todo",
      blocked_by: [%{id: "cycle-c", identifier: "MT-942", state: "Todo"}]
    }

    cycle_issue_c = %Issue{
      id: "cycle-c",
      identifier: "MT-942",
      state: "Todo",
      blocked_by: [%{id: "cycle-a", identifier: "MT-940", state: "Todo"}]
    }

    assert [
             %{
               issue_identifier: "MT-940",
               issue_id: "cycle-a",
               type: :cyclic_dependency
             }
           ] =
             SymphonyElixir.M3Precheck.structural_errors_for_issue(
               cycle_issue_a,
               [cycle_issue_a, cycle_issue_b, cycle_issue_c, invalid_lookup_issue]
             )

    missing_tail_issue_a = %Issue{
      id: "missing-a",
      identifier: "MT-943",
      state: "Todo",
      blocked_by: [%{id: "missing-b", identifier: "MT-944", state: "Todo"}]
    }

    missing_tail_issue_b = %Issue{
      id: "missing-b",
      identifier: "MT-944",
      state: "Todo",
      blocked_by: [%{id: "missing-dep", identifier: "MT-945", state: "Todo"}]
    }

    assert [] =
             SymphonyElixir.M3Precheck.structural_errors_for_issue(
               missing_tail_issue_a,
               [missing_tail_issue_a, missing_tail_issue_b, invalid_lookup_issue]
             )
  end

  test "run sorts eligible todos by created_at ascending then identifier and exposes blocked in progress anomalies" do
    shared_time = ~U[2026-05-07 10:00:00Z]

    issues = [
      %Issue{
        id: "todo-b",
        identifier: "MT-951",
        title: "Second by identifier",
        state: "Todo",
        created_at: shared_time,
        blocked_by: []
      },
      %Issue{
        id: "todo-a",
        identifier: "MT-950",
        title: "First by identifier",
        state: "Todo",
        created_at: shared_time,
        blocked_by: []
      },
      %Issue{
        id: "active-blocked",
        identifier: "MT-952",
        title: "Active but blocked",
        state: "In Progress",
        blocked_by: [%{id: "dep-open", identifier: "MT-999", state: "Todo", project_slug: "alpha"}]
      }
    ]

    result =
      SymphonyElixir.M3Precheck.run(issues, %{
        current_project_slug: "alpha",
        current_project_id: "project-alpha",
        m3_enabled: true,
        max_concurrent_agents: 5,
        active_running_count: 0,
        terminal_states: ["Done", "Closed"]
      })

    assert Enum.map(result.eligible_todos, & &1.identifier) == ["MT-950", "MT-951"]

    assert result.anomalies == [
             %{
               type: :blocked_but_in_progress,
               issue_identifier: "MT-952",
               issue_id: "active-blocked",
               state: "In Progress",
               blocking_identifiers: ["MT-999"]
             }
           ]
  end

  test "run treats blockers with non-binary states as non-terminal blockers" do
    issue = %Issue{
      id: "issue-non-binary-blockers",
      identifier: "MT-950",
      state: "Todo",
      blocked_by: [
        %{id: "dep-int", identifier: "DEP-INT", state: 123},
        %{id: "dep-nil", identifier: "DEP-NIL", state: nil}
      ]
    }

    result =
      SymphonyElixir.M3Precheck.run([issue], %{
        current_project_slug: "alpha",
        current_project_id: "project-alpha",
        m3_enabled: true,
        max_concurrent_agents: 1,
        active_running_count: 0,
        terminal_states: ["Done"]
      })

    assert result.eligible == []
    assert result.blocked["MT-950"] == ["waiting on non-terminal blockers: DEP-INT, DEP-NIL"]
  end
end
