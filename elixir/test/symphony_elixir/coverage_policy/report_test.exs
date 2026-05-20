defmodule SymphonyElixir.CoveragePolicy.ReportTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.CoveragePolicy.Report

  defmodule SampleTrackedModule do
    def sample, do: :ok
  end

  defmodule SampleIgnoredModule do
    def sample, do: :ignored
  end

  test "fails when cover compile beams returns an error" do
    tmp = Path.join(System.tmp_dir!(), "coverage-policy-report-missing-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "policy.coverdata"), "placeholder")

    ops = %{
      file_exists?: fn _ -> true end,
      ensure_tools: fn -> :ok end,
      cover_stop: fn -> :ok end,
      cover_start: fn -> {:ok, self()} end,
      cover_compile_beam: fn _ -> {:error, :compile_failed} end,
      cover_import: fn _ -> :ok end,
      cover_modules: fn -> [] end,
      cover_analyse: fn _, _, _ -> {:ok, []} end
    }

    try do
      assert_raise ArgumentError, ~r/failed to cover compile beams: :compile_failed/, fn ->
        Report.load_reports!(cover_path: tmp, compile_path: tmp, ops: ops)
      end
    after
      File.rm_rf(tmp)
    end
  end

  test "loads reports, excludes ignored modules, and maps line hit states" do
    tmp = Path.join(System.tmp_dir!(), "coverage-policy-report-load-#{System.unique_integer([:positive])}")
    beams_dir = Path.join(tmp, "beams")
    cover_dir = Path.join(tmp, "cover")
    File.mkdir_p!(beams_dir)
    File.mkdir_p!(cover_dir)
    File.write!(Path.join(cover_dir, "policy.coverdata"), "placeholder")
    File.write!(Path.join(beams_dir, "sample.beam"), "")

    analyse_rows = %{
      SampleTrackedModule => [
        {{SampleTrackedModule, 10}, {1, 0}},
        {{SampleTrackedModule, 11}, {0, 1}},
        {{SampleTrackedModule, 11}, {0, 1}},
        {{SampleTrackedModule, 12}, {1, 0}},
        {{SampleTrackedModule, 12}, {0, 0}}
      ],
      SymphonyElixir.RunTrace => []
    }

    ops = %{
      file_exists?: fn path -> String.ends_with?(path, "policy.coverdata") end,
      ensure_tools: fn -> :ok end,
      cover_stop: fn -> :stopped end,
      cover_start: fn -> {:ok, self()} end,
      cover_compile_beam: fn [beam] ->
        assert to_string(beam) =~ "sample.beam"
        [:ok]
      end,
      cover_import: fn path ->
        assert to_string(path) =~ "policy.coverdata"
        :ok
      end,
      cover_modules: fn ->
        [SampleTrackedModule, SymphonyElixir.Config, SymphonyElixir.RunTrace]
      end,
      cover_analyse: fn module, :coverage, :line ->
        {:ok, Map.fetch!(analyse_rows, module)}
      end
    }

    try do
      reports = Report.load_reports!(cover_path: cover_dir, compile_path: beams_dir, ops: ops)

      assert [
               %{
                 module: __MODULE__.SampleTrackedModule,
                 source: "test/symphony_elixir/coverage_policy/report_test.exs",
                 tier: :c,
                 enforce_threshold?: false,
                 threshold: nil,
                 target_threshold: 95.0,
                 executable_lines: 3,
                 covered_lines: 2,
                 coverage: 66.66666666666667,
                 line_hits: %{10 => :covered, 11 => :missed, 12 => :covered}
               },
               %{
                 module: SymphonyElixir.RunTrace,
                 source: "lib/symphony_elixir/run_trace.ex",
                 tier: :a,
                 enforce_threshold?: true,
                 threshold: 96.85,
                 target_threshold: 99.0,
                 executable_lines: 0,
                 covered_lines: 0,
                 coverage: 100.0,
                 line_hits: %{}
               }
             ] = reports
    after
      File.rm_rf(tmp)
    end
  end
end
