defmodule Mix.Tasks.Coverage.Policy.CheckTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Coverage.Policy.Check
  alias SymphonyElixir.CoveragePolicy.Policy, as: CoveragePolicy

  defmodule StubPolicy do
    def config do
      [
        diff_coverage: %{minimum: 90.0, tier_a_minimum: 95.0, mode: :enforce}
      ]
    end

    def ignore_audit, do: [%{module: Stub.Module, reason: "stub", test_target: "Stub.Target", review_after: "2026-06-01"}]
    def resolve_base_ref(policy, base_ref), do: CoveragePolicy.resolve_base_ref(policy, base_ref)
  end

  defmodule StubChecker do
    def validate_ignore_audit!(_policy), do: :ok
    def validate_diff_coverage!(_changed_lines, _reports, _policy), do: %{overall: %{percent: 91.23}, tier_a: %{percent: 98.76}}
    def validate_module_thresholds!(_reports, _changed_lines), do: :ok
  end

  defmodule StubDiff do
    def changed_lines("origin/main", git_root: git_root) do
      send(self(), {:diff_called, git_root})
      %{"lib/example.ex" => MapSet.new([10])}
    end
  end

  defmodule StubReport do
    def load_reports!(cover_path: cover_path) do
      send(self(), {:report_called, cover_path})
      [%{module: Stub.Module}]
    end
  end

  defmodule FailingChecker do
    def validate_ignore_audit!(_policy), do: raise(ArgumentError, "boom")
    def validate_diff_coverage!(_changed_lines, _reports, _policy), do: :ok
    def validate_module_thresholds!(_reports, _changed_lines), do: :ok
  end

  setup do
    Mix.Task.reenable("coverage.policy.check")

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :coverage_policy_check_task_modules)
      Mix.Task.reenable("coverage.policy.check")
    end)

    :ok
  end

  test "fails when no exported coverdata exists" do
    assert_raise Mix.Error,
                 ~r/coverage\.policy\.check failed: no exported coverage data found in missing-cover/,
                 fn ->
                   capture_io(fn ->
                     Check.run(["--cover-path", "missing-cover", "--base-ref-mode", "skip_without_base"])
                   end)
                 end
  end

  test "fails when base ref is required but missing" do
    assert_raise Mix.Error,
                 ~r/coverage\.policy\.check failed: base ref is required when diff coverage mode is :enforce/,
                 fn ->
                   capture_io(fn ->
                     Check.run(["--cover-path", "cover", "--base-ref-mode", "enforce"])
                   end)
                 end
  end

  test "skip wrapper mode uses explicit skip_without_base without requiring base ref" do
    policy = Check.policy_for_test(%{base_ref_mode: "skip_without_base"})

    assert policy.base_ref == nil
    assert policy.diff_coverage.mode == :skip_without_base
  end

  test "enforce wrapper requires explicit base ref instead of guessing origin/main" do
    policy = Check.policy_for_test(%{base_ref_mode: "enforce", base_ref: "origin/main"})

    assert policy.base_ref == "origin/main"
    assert policy.diff_coverage.mode == :enforce
  end

  test "fails on invalid command-line options" do
    assert_raise Mix.Error, ~r/Invalid option: \[\{"--bad", nil\}\]/, fn ->
      capture_io(fn ->
        Check.run(["--bad"])
      end)
    end
  end

  test "fails when base_ref_mode is unsupported" do
    assert_raise ArgumentError, ~r/unsupported diff coverage mode: "weird"/, fn ->
      capture_io(fn ->
        Check.run(["--cover-path", "cover", "--base-ref-mode", "weird"])
      end)
    end
  end

  test "prints success message when skip_without_base succeeds" do
    Application.put_env(:symphony_elixir, :coverage_policy_check_task_modules, %{
      checker: StubChecker,
      diff: StubDiff,
      policy: StubPolicy,
      report: StubReport
    })

    output =
      capture_io(fn ->
        assert :ok = Check.run(["--cover-path", "fake-cover", "--base-ref-mode", "skip_without_base"])
      end)

    assert_received {:report_called, "fake-cover"}
    refute_received {:diff_called, _git_root}
    assert output =~ "coverage.policy.check: validated 1 modules, diff mode=skip_without_base, overall diff=100.00%, tier_a diff=100.00%"
  end

  test "prints success message when enforce mode succeeds" do
    Application.put_env(:symphony_elixir, :coverage_policy_check_task_modules, %{
      checker: StubChecker,
      diff: StubDiff,
      policy: StubPolicy,
      report: StubReport
    })

    output =
      capture_io(fn ->
        assert :ok = Check.run(["--cover-path", "fake-cover", "--base-ref", "origin/main", "--base-ref-mode", "enforce"])
      end)

    assert_received {:report_called, "fake-cover"}
    assert_received {:diff_called, git_root}
    assert git_root == Path.expand("..", File.cwd!())
    assert output =~ "coverage.policy.check: validated 1 modules, diff mode=enforce, overall diff=91.23%, tier_a diff=98.76%"
  end

  test "wraps downstream argument errors with task context" do
    Application.put_env(:symphony_elixir, :coverage_policy_check_task_modules, %{
      checker: FailingChecker,
      diff: StubDiff,
      policy: StubPolicy,
      report: StubReport
    })

    assert_raise Mix.Error, ~r/coverage\.policy\.check failed: boom/, fn ->
      capture_io(fn ->
        Check.run(["--cover-path", "fake-cover", "--base-ref-mode", "skip_without_base"])
      end)
    end
  end
end
