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
end
