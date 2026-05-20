defmodule Mix.Tasks.Coverage.Policy.CheckTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Coverage.Policy.Check

  setup do
    Mix.Task.reenable("coverage.policy.check")
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
end
