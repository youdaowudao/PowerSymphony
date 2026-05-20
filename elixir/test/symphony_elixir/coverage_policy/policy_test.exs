defmodule SymphonyElixir.CoveragePolicy.PolicyTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.CoveragePolicy.Policy

  test "fetches ignore modules from mix project config" do
    ignore_modules = Policy.ignore_modules()

    assert SymphonyElixir.Config in ignore_modules
    assert SymphonyElixirWeb.Router.Helpers in ignore_modules
  end

  test "fails when an ignored module is missing audit metadata" do
    assert_raise ArgumentError,
                 ~r/missing ignore audit metadata for ignored modules: .*SymphonyElixir\.Config/,
                 fn ->
                   Policy.validate_ignore_audit!([
                     %{
                       module: SymphonyElixir.Linear.Client,
                       reason: "external boundary",
                       test_target: "SymphonyElixir.Linear.Adapter",
                       review_after: "2026-06-01"
                     }
                   ])
                 end
  end

  test "fails when ignore audit includes a module not present in ignore_modules" do
    entries =
      Policy.ignore_audit() ++
        [
          %{
            module: SymphonyElixir.Config.Schema.Agent,
            reason: "extra entry",
            test_target: "SymphonyElixir.Config.Schema.Agent",
            review_after: "2026-06-01"
          }
        ]

    assert_raise ArgumentError,
                 ~r/ignore audit contains modules not present in mix\.exs ignore_modules: .*SymphonyElixir\.Config\.Schema\.Agent/,
                 fn ->
                   Policy.validate_ignore_audit!(entries)
                 end
  end

  test "fails when ignore audit metadata is incomplete" do
    entries =
      Policy.ignore_audit()
      |> Enum.map(fn entry ->
        if entry.module == SymphonyElixir.Config do
          %{entry | reason: ""}
        else
          entry
        end
      end)

    assert_raise ArgumentError,
                 ~r/ignore audit entry SymphonyElixir\.Config missing reason/,
                 fn ->
                   Policy.validate_ignore_audit!(entries)
                 end
  end

  test "resolves explicit base ref for diff coverage mode" do
    assert {:ok, "origin/main"} =
             Policy.resolve_base_ref(%{diff_coverage: %{mode: :enforce}}, "origin/main")
  end

  test "fails closed when diff coverage is enforced without base ref" do
    assert_raise ArgumentError,
                 ~r/base ref is required when diff coverage mode is :enforce/,
                 fn ->
                   Policy.resolve_base_ref(%{diff_coverage: %{mode: :enforce}}, nil)
                 end
  end

  test "allows explicit skip mode without base ref" do
    assert {:skip, :missing_base_ref} =
             Policy.resolve_base_ref(%{diff_coverage: %{mode: :skip_without_base}}, nil)
  end

  test "fails on unsupported diff coverage mode when base ref is missing" do
    assert_raise ArgumentError,
                 ~r/unsupported diff coverage mode: :unexpected/,
                 fn ->
                   Policy.resolve_base_ref(%{diff_coverage: %{mode: :unexpected}}, nil)
                 end
  end

  test "marks tier a baseline as enforced but tier c target as report-only" do
    assert %{
             tier: :a,
             enforce_threshold?: true,
             threshold: 96.85,
             target_threshold: 99.0
           } = Policy.module_policy(SymphonyElixir.RunTrace)

    assert %{
             tier: :c,
             enforce_threshold?: false,
             threshold: nil,
             target_threshold: 95.0
           } = Policy.module_policy(SymphonyElixir.Config.Schema.Agent)
  end

  test "raises when tier baseline refers to a missing threshold bucket" do
    original = Policy.config()

    Application.put_env(
      :symphony_elixir,
      :coverage_policy,
      original
      |> Keyword.put(:tiers, %{SampleTier.Module => %{tier: :z, current_baseline: 50}})
    )

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :coverage_policy, original)
    end)

    assert_raise KeyError, fn ->
      Policy.module_policy(SampleTier.Module)
    end
  end

  test "normalizes integer baselines to floats" do
    original = Policy.config()

    Application.put_env(
      :symphony_elixir,
      :coverage_policy,
      original
      |> Keyword.put(:tiers, %{SampleTier.IntBaseline => %{tier: :b, current_baseline: 97}})
    )

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :coverage_policy, original)
    end)

    assert %{
             tier: :b,
             enforce_threshold?: true,
             threshold: 97.0,
             target_threshold: 97.0
           } = Policy.module_policy(SampleTier.IntBaseline)
  end
end
