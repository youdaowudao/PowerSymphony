defmodule Mix.Tasks.Coverage.Policy.Check do
  use Mix.Task

  @moduledoc false
  @shortdoc "Validate coverage policy from exported coverdata"

  alias SymphonyElixir.CoveragePolicy.{Checker, Diff, Policy, Report}

  @switches [
    cover_path: :string,
    base_ref: :string,
    base_ref_mode: :string
  ]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    Mix.Task.run("compile")
    policy = merged_policy(parse_args!(args))

    try do
      base_resolution = Policy.resolve_base_ref(policy, policy.base_ref)
      reports = Report.load_reports!(cover_path: policy.cover_path)
      Checker.validate_ignore_audit!(policy)

      {changed_lines, diff_result} =
        case base_resolution do
          {:ok, base_ref} ->
            changed_lines = Diff.changed_lines(base_ref, git_root: project_root())
            diff_result = Checker.validate_diff_coverage!(changed_lines, reports, policy)
            {changed_lines, diff_result}

          {:skip, :missing_base_ref} ->
            {nil,
             %{
               overall: %{covered: 0, executable: 0, percent: 100.0},
               tier_a: %{covered: 0, executable: 0, percent: 100.0}
             }}
        end

      Checker.validate_module_thresholds!(reports, changed_lines)

      Mix.shell().info(success_message(length(reports), diff_result, policy))
      :ok
    rescue
      error in [ArgumentError] ->
        Mix.raise("coverage.policy.check failed: #{Exception.message(error)}")
    end
  end

  @spec policy_for_test(map()) :: %{
          cover_path: String.t(),
          base_ref: String.t() | nil,
          ignore_audit: [map()],
          diff_coverage: map()
        }
  def policy_for_test(opts) when is_map(opts) do
    opts
    |> Enum.to_list()
    |> merged_policy()
  end

  defp parse_args!(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("Invalid option: #{inspect(invalid)}")
    end

    opts
  end

  defp merged_policy(opts) do
    base_config = Policy.config()

    mode =
      normalize_mode(opts[:base_ref_mode] || Atom.to_string(base_config[:diff_coverage][:mode]))

    %{
      cover_path: opts[:cover_path] || "cover",
      base_ref: opts[:base_ref],
      ignore_audit: Policy.ignore_audit(),
      diff_coverage: Map.put(base_config[:diff_coverage], :mode, mode)
    }
  end

  defp normalize_mode("enforce"), do: :enforce
  defp normalize_mode("skip_without_base"), do: :skip_without_base

  defp normalize_mode(other),
    do: raise(ArgumentError, "unsupported diff coverage mode: #{inspect(other)}")

  defp success_message(report_count, diff_result, policy) do
    mode = policy.diff_coverage.mode

    "coverage.policy.check: validated #{report_count} modules, " <>
      "diff mode=#{mode}, overall diff=#{format_percent(diff_result.overall.percent)}%, " <>
      "tier_a diff=#{format_percent(diff_result.tier_a.percent)}%"
  end

  defp format_percent(percent) do
    :erlang.float_to_binary(percent, decimals: 2)
  end

  defp project_root do
    File.cwd!()
    |> Path.join("..")
    |> Path.expand()
  end
end
