defmodule SymphonyElixir.CoveragePolicy.Report do
  @moduledoc false

  alias SymphonyElixir.CoveragePolicy.Policy
  @compile {:no_warn_undefined, :cover}
  @cover_nowarn_functions [
    cover_stop: 0,
    cover_start: 0,
    cover_compile_beam: 1,
    cover_import: 1,
    cover_modules: 0,
    cover_analyse: 3
  ]
  @dialyzer {:nowarn_function, @cover_nowarn_functions}

  @spec load_reports!(keyword()) :: [map()]
  def load_reports!(opts \\ []) do
    cover_path = Keyword.get(opts, :cover_path, "cover")
    compile_path = Keyword.get(opts, :compile_path, Mix.Project.compile_path())
    ops = Keyword.get(opts, :ops, default_ops())
    output = String.trim_trailing(cover_path, "/")
    coverdata = Path.join(output, "policy.coverdata")

    if not ops.file_exists?.(coverdata) do
      raise ArgumentError, "no exported coverage data found in #{output}"
    end

    ops.ensure_tools.()
    _ = ops.cover_stop.()
    {:ok, _pid} = ops.cover_start.()

    compile_result = ops.cover_compile_beam.(beams(compile_path))

    case compile_result do
      results when is_list(results) -> :ok
      {:error, reason} -> raise ArgumentError, "failed to cover compile beams: #{inspect(reason)}"
    end

    :ok = ops.cover_import.(String.to_charlist(coverdata))

    ops.cover_modules.()
    |> Enum.reject(&(&1 in Policy.ignore_modules()))
    |> Enum.map(&report_for_module(&1, ops))
  end

  defp report_for_module(module, ops) do
    {:ok, line_rows} = ops.cover_analyse.(module, :coverage, :line)

    %{
      tier: tier,
      enforce_threshold?: enforce_threshold?,
      threshold: threshold,
      target_threshold: target_threshold
    } = Policy.module_policy(module)

    line_hits = line_hits(line_rows)
    executable_lines = map_size(line_hits)
    covered_lines = Enum.count(line_hits, fn {_line, status} -> status == :covered end)

    %{
      module: module,
      source: normalize_path(source_path(module)),
      tier: tier,
      enforce_threshold?: enforce_threshold?,
      threshold: threshold,
      target_threshold: target_threshold,
      executable_lines: executable_lines,
      covered_lines: covered_lines,
      coverage: percent(covered_lines, executable_lines),
      line_hits: line_hits
    }
  end

  defp line_hits(rows) do
    Enum.reduce(rows, %{}, fn {{_module, line}, tuple}, acc ->
      case tuple do
        {1, 0} -> Map.put(acc, line, :covered)
        {0, 1} -> Map.put_new(acc, line, :missed)
        _ -> acc
      end
    end)
  end

  defp percent(_covered, 0), do: 100.0
  defp percent(covered, executable), do: covered * 100.0 / executable

  defp source_path(module) do
    module
    |> then(& &1.module_info(:compile))
    |> Keyword.fetch!(:source)
    |> List.to_string()
    |> Path.relative_to(File.cwd!())
  end

  defp normalize_path(path) do
    path
    |> String.replace_prefix("./", "")
    |> String.replace_prefix("elixir/", "")
  end

  defp beams(dir) do
    dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".beam"))
    |> Enum.map(&(Path.join(dir, &1) |> String.to_charlist()))
  end

  defp default_ops do
    %{
      file_exists?: &File.exists?/1,
      ensure_tools: fn -> Mix.ensure_application!(:tools) end,
      cover_stop: &cover_stop/0,
      cover_start: &cover_start/0,
      cover_compile_beam: &cover_compile_beam/1,
      cover_import: &cover_import/1,
      cover_modules: &cover_modules/0,
      cover_analyse: &cover_analyse/3
    }
  end

  defp cover_stop do
    :cover.stop()
  end

  defp cover_start do
    :cover.start()
  end

  defp cover_compile_beam(beams) do
    :cover.compile_beam(beams)
  end

  defp cover_import(path) do
    :cover.import(path)
  end

  defp cover_modules do
    :cover.modules()
  end

  defp cover_analyse(module, type, level) do
    :cover.analyse(module, type, level)
  end
end
