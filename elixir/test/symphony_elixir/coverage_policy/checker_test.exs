defmodule SymphonyElixir.CoveragePolicy.CheckerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.CoveragePolicy.Checker

  test "fails closed when a changed source file cannot be mapped to coverage data" do
    reports = [
      %{
        module: Sample.Module,
        source: "elixir/lib/sample/module.ex",
        tier: :b,
        threshold: 97.0,
        coverage: 100.0,
        executable_lines: 1,
        covered_lines: 1,
        line_hits: %{10 => :covered}
      }
    ]

    assert_raise ArgumentError,
                 ~r/unmapped changed source files: \["elixir\/lib\/other\.ex"\]/,
                 fn ->
                   Checker.validate_diff_coverage!(
                     %{"elixir/lib/other.ex" => MapSet.new([12])},
                     reports,
                     %{diff_coverage: %{minimum: 90.0, tier_a_minimum: 95.0}}
                   )
                 end
  end

  test "ignores non coverage files when checking unmapped changed paths" do
    reports = [
      %{
        module: Sample.Module,
        source: "elixir/lib/sample/module.ex",
        tier: :b,
        threshold: 97.0,
        coverage: 100.0,
        executable_lines: 1,
        covered_lines: 1,
        line_hits: %{10 => :covered}
      }
    ]

    result =
      Checker.validate_diff_coverage!(
        %{
          "elixir/README.md" => MapSet.new([1]),
          "elixir/Makefile" => MapSet.new([2]),
          "elixir/config/config.exs" => MapSet.new([3]),
          "elixir/test/symphony_elixir/coverage_policy/checker_test.exs" => MapSet.new([4]),
          "elixir/lib/sample/module.ex" => MapSet.new([10])
        },
        reports,
        %{diff_coverage: %{minimum: 90.0, tier_a_minimum: 95.0}}
      )

    assert result.overall.covered == 1
    assert result.overall.executable == 1
    assert_in_delta result.overall.percent, 100.0, 0.01
  end

  test "still fails closed for unmapped executable elixir sources" do
    reports = [
      %{
        module: Sample.Module,
        source: "elixir/lib/sample/module.ex",
        tier: :b,
        threshold: 97.0,
        coverage: 100.0,
        executable_lines: 1,
        covered_lines: 1,
        line_hits: %{10 => :covered}
      }
    ]

    assert_raise ArgumentError,
                 ~r/unmapped changed source files: \["elixir\/lib\/sample\/other\.ex"\]/,
                 fn ->
                   Checker.validate_diff_coverage!(
                     %{
                       "elixir/README.md" => MapSet.new([1]),
                       "elixir/config/config.exs" => MapSet.new([3]),
                       "elixir/lib/sample/other.ex" => MapSet.new([12])
                     },
                     reports,
                     %{diff_coverage: %{minimum: 90.0, tier_a_minimum: 95.0}}
                   )
                 end
  end

  test "ignores changed sources for modules excluded by ignore_modules" do
    reports = [
      %{
        module: Sample.Module,
        source: "elixir/lib/sample/module.ex",
        tier: :b,
        threshold: 97.0,
        coverage: 100.0,
        executable_lines: 1,
        covered_lines: 1,
        line_hits: %{10 => :covered}
      }
    ]

    result =
      Checker.validate_diff_coverage!(
        %{"elixir/lib/symphony_elixir/config.ex" => MapSet.new([1])},
        reports,
        %{diff_coverage: %{minimum: 90.0, tier_a_minimum: 95.0}}
      )

    assert result.overall.covered == 0
    assert result.overall.executable == 0
    assert_in_delta result.overall.percent, 100.0, 0.01
  end

  test "computes overall and tier a diff coverage from executable changed lines" do
    reports = [
      %{
        module: TierA.Module,
        source: "elixir/lib/tier_a/module.ex",
        tier: :a,
        threshold: 98.0,
        coverage: 99.0,
        executable_lines: 3,
        covered_lines: 3,
        line_hits: %{10 => :covered, 11 => :missed, 12 => :covered}
      },
      %{
        module: TierB.Module,
        source: "elixir/lib/tier_b/module.ex",
        tier: :b,
        threshold: 97.0,
        coverage: 98.0,
        executable_lines: 2,
        covered_lines: 2,
        line_hits: %{20 => :covered}
      }
    ]

    result =
      Checker.validate_diff_coverage!(
        %{
          "elixir/lib/tier_a/module.ex" => MapSet.new([10, 11, 99]),
          "elixir/lib/tier_b/module.ex" => MapSet.new([20])
        },
        reports,
        %{diff_coverage: %{minimum: 60.0, tier_a_minimum: 50.0}}
      )

    assert result.overall.covered == 2
    assert result.overall.executable == 3
    assert_in_delta result.overall.percent, 66.67, 0.01
    assert result.tier_a.covered == 1
    assert result.tier_a.executable == 2
    assert_in_delta result.tier_a.percent, 50.0, 0.01
  end

  test "does not fail non tier a modules that are below long term target" do
    reports = [
      %{
        module: TierC.Module,
        source: "lib/tier_c/module.ex",
        tier: :c,
        enforce_threshold?: false,
        threshold: nil,
        target_threshold: 95.0,
        coverage: 42.0,
        executable_lines: 10,
        covered_lines: 4,
        line_hits: %{}
      }
    ]

    assert :ok = Checker.validate_module_thresholds!(reports, %{})
  end

  test "does not fail untouched tier a modules that are below baseline" do
    reports = [
      %{
        module: TierA.Module,
        source: "lib/tier_a/module.ex",
        tier: :a,
        enforce_threshold?: true,
        threshold: 97.13,
        target_threshold: 99.0,
        coverage: 96.85,
        executable_lines: 100,
        covered_lines: 97,
        line_hits: %{}
      }
    ]

    assert :ok = Checker.validate_module_thresholds!(reports, %{})
  end

  test "fails touched tier a modules that drop below current baseline" do
    reports = [
      %{
        module: TierA.Module,
        source: "lib/tier_a/module.ex",
        tier: :a,
        enforce_threshold?: true,
        threshold: 97.13,
        target_threshold: 99.0,
        coverage: 96.85,
        executable_lines: 100,
        covered_lines: 97,
        line_hits: %{}
      }
    ]

    assert_raise ArgumentError, ~r/module coverage thresholds failed: TierA\.Module 96\.85 < 97\.13/, fn ->
      Checker.validate_module_thresholds!(reports, %{"lib/tier_a/module.ex" => MapSet.new([10])})
    end
  end

  test "passes when tier a module matches configured baseline exactly" do
    reports = [
      %{
        module: TierA.Module,
        source: "lib/tier_a/module.ex",
        tier: :a,
        enforce_threshold?: true,
        threshold: 96.85,
        target_threshold: 99.0,
        coverage: 96.85,
        executable_lines: 100,
        covered_lines: 97,
        line_hits: %{}
      }
    ]

    assert :ok = Checker.validate_module_thresholds!(reports, %{"lib/tier_a/module.ex" => MapSet.new([10])})
  end

  test "skips tier a baseline gate when skip_without_base provides no changed lines" do
    reports = [
      %{
        module: TierA.Module,
        source: "lib/tier_a/module.ex",
        tier: :a,
        enforce_threshold?: true,
        threshold: 97.13,
        target_threshold: 99.0,
        coverage: 96.85,
        executable_lines: 100,
        covered_lines: 97,
        line_hits: %{}
      }
    ]

    assert :ok = Checker.validate_module_thresholds!(reports, nil)
  end

  test "does not fail when rounded coverage equals rounded baseline" do
    reports = [
      %{
        module: TierA.Module,
        source: "lib/tier_a/module.ex",
        tier: :a,
        enforce_threshold?: true,
        threshold: 96.875,
        target_threshold: 99.0,
        coverage: 96.875,
        executable_lines: 100,
        covered_lines: 97,
        line_hits: %{}
      }
    ]

    assert :ok = Checker.validate_module_thresholds!(reports, %{"lib/tier_a/module.ex" => MapSet.new([10])})
  end
end
