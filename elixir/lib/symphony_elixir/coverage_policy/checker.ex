defmodule SymphonyElixir.CoveragePolicy.Checker do
  @moduledoc false

  alias SymphonyElixir.CoveragePolicy.Policy

  @type report :: %{
          required(:module) => module(),
          required(:source) => String.t(),
          required(:tier) => atom(),
          required(:enforce_threshold?) => boolean(),
          required(:threshold) => float() | nil,
          required(:target_threshold) => float(),
          required(:coverage) => float(),
          required(:line_hits) => map()
        }

  @spec validate_ignore_audit!(map()) :: :ok
  def validate_ignore_audit!(policy) do
    Policy.validate_ignore_audit!(policy.ignore_audit)
  end

  @spec validate_module_thresholds!([report()], %{optional(String.t()) => MapSet.t(integer())} | nil) :: :ok
  def validate_module_thresholds!(reports, changed_lines) do
    touched_sources = touched_sources(changed_lines)

    failures =
      Enum.filter(reports, fn report ->
        report.enforce_threshold? and touched?(report.source, touched_sources) and
          rounded(report.coverage) < rounded(report.threshold)
      end)

    if failures != [] do
      details =
        Enum.map_join(failures, ", ", fn report ->
          "#{inspect(report.module)} #{format_percent(report.coverage)} < #{format_percent(report.threshold)} (tier #{report.tier})"
        end)

      raise ArgumentError, "module coverage thresholds failed: #{details}"
    end

    :ok
  end

  @spec validate_diff_coverage!(
          %{optional(String.t()) => MapSet.t(integer())},
          [report()],
          map()
        ) :: %{overall: map(), tier_a: map()}
  def validate_diff_coverage!(changed_lines, reports, policy) do
    reports_by_source = Map.new(reports, &{normalize_path(&1.source), &1})
    tracked_changed_lines = coverage_tracked_changed_lines(changed_lines)

    assert_no_unmapped_changed_sources!(tracked_changed_lines, reports_by_source)
    summaries = collect_diff_summaries(tracked_changed_lines, reports_by_source)

    overall = finish_bucket(summaries.overall)
    tier_a = finish_bucket(summaries.tier_a)

    minimum = policy[:diff_coverage][:minimum]
    tier_a_minimum = policy[:diff_coverage][:tier_a_minimum]

    if overall.executable > 0 and overall.percent + 1.0e-6 < minimum do
      raise ArgumentError,
            "diff coverage failed: overall #{format_percent(overall.percent)} < #{format_percent(minimum)}"
    end

    if tier_a.executable > 0 and tier_a.percent + 1.0e-6 < tier_a_minimum do
      raise ArgumentError,
            "diff coverage failed: tier_a #{format_percent(tier_a.percent)} < #{format_percent(tier_a_minimum)}"
    end

    %{overall: overall, tier_a: tier_a}
  end

  defp empty_bucket, do: %{covered: 0, executable: 0}

  defp increment(acc, bucket, field) do
    update_in(acc, [bucket, field], &(&1 + 1))
  end

  defp maybe_increment_tier_a(acc, :a, field), do: increment(acc, :tier_a, field)
  defp maybe_increment_tier_a(acc, _tier, _field), do: acc

  defp touched_sources(nil), do: nil
  defp touched_sources(changed_lines), do: Map.keys(changed_lines) |> MapSet.new(&normalize_path/1)

  defp touched?(_source, nil), do: false
  defp touched?(source, touched_sources), do: MapSet.member?(touched_sources, normalize_path(source))

  defp assert_no_unmapped_changed_sources!(changed_lines, reports_by_source) do
    unmapped =
      changed_lines
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(reports_by_source, normalize_path(&1)))
      |> Enum.sort()

    if unmapped != [] do
      raise ArgumentError, "unmapped changed source files: #{inspect(unmapped)}"
    end
  end

  defp coverage_tracked_changed_lines(changed_lines) do
    ignored_sources = ignored_source_paths()

    Map.filter(changed_lines, fn {path, _lines} ->
      coverage_tracked_source?(path, ignored_sources)
    end)
  end

  defp coverage_tracked_source?(path, ignored_sources) do
    normalized = normalize_path(path)

    String.starts_with?(normalized, "lib/") and String.ends_with?(normalized, ".ex") and
      not MapSet.member?(ignored_sources, normalized)
  end

  defp ignored_source_paths do
    Policy.ignore_modules()
    |> Enum.reduce(MapSet.new(), fn
      module, acc when is_atom(module) ->
        MapSet.put(acc, normalize_path(source_path(module)))

      _ignored_entry, acc ->
        acc
    end)
  end

  defp source_path(module) do
    module
    |> then(& &1.module_info(:compile))
    |> Keyword.fetch!(:source)
    |> List.to_string()
    |> Path.relative_to(File.cwd!())
  end

  defp collect_diff_summaries(changed_lines, reports_by_source) do
    Enum.reduce(changed_lines, %{overall: empty_bucket(), tier_a: empty_bucket()}, fn {path, lines}, acc ->
      report = Map.fetch!(reports_by_source, normalize_path(path))
      accumulate_report_lines(lines, report, acc)
    end)
  end

  defp accumulate_report_lines(lines, report, acc) do
    Enum.reduce(lines, acc, fn line, bucket_acc ->
      case Map.get(report.line_hits, line) do
        nil -> bucket_acc
        :covered -> add_covered_line(bucket_acc, report.tier)
        :missed -> add_missed_line(bucket_acc, report.tier)
      end
    end)
  end

  defp add_covered_line(bucket_acc, tier) do
    bucket_acc
    |> increment(:overall, :covered)
    |> increment(:overall, :executable)
    |> maybe_increment_tier_a(tier, :covered)
    |> maybe_increment_tier_a(tier, :executable)
  end

  defp add_missed_line(bucket_acc, tier) do
    bucket_acc
    |> increment(:overall, :executable)
    |> maybe_increment_tier_a(tier, :executable)
  end

  defp finish_bucket(bucket) do
    percent =
      case bucket.executable do
        0 -> 100.0
        executable -> bucket.covered * 100.0 / executable
      end

    Map.put(bucket, :percent, percent)
  end

  defp normalize_path(path) do
    path
    |> String.replace_prefix("./", "")
    |> String.replace_prefix("elixir/", "")
  end

  defp format_percent(percent) do
    :erlang.float_to_binary(percent, decimals: 2)
  end

  defp rounded(value) when is_float(value), do: Float.round(value, 2)
  defp rounded(value) when is_integer(value), do: (value / 1) |> Float.round(2)
end
