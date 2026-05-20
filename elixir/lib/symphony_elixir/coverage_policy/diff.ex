defmodule SymphonyElixir.CoveragePolicy.Diff do
  @moduledoc false

  @spec changed_lines(String.t(), keyword()) :: %{optional(String.t()) => MapSet.t(integer())}
  def changed_lines(base_ref, opts \\ []) when is_binary(base_ref) do
    git_root = Keyword.get(opts, :git_root, File.cwd!())

    {output, status} =
      System.cmd(
        "git",
        ["diff", "--unified=0", "--no-color", "#{base_ref}...HEAD", "--", "elixir"],
        cd: git_root,
        stderr_to_stdout: true
      )

    case status do
      0 -> parse_unified_diff(output)
      _ -> raise ArgumentError, "git diff against #{base_ref} failed: #{String.trim(output)}"
    end
  end

  @spec parse_unified_diff(String.t()) :: %{optional(String.t()) => MapSet.t(integer())}
  def parse_unified_diff(diff_text) do
    diff_text
    |> String.split("\n")
    |> Enum.reduce({nil, %{}}, &consume_line/2)
    |> elem(1)
  end

  defp consume_line("+++ b/" <> path, {_current, acc}) do
    {normalize_path(path), acc}
  end

  defp consume_line("@@ " <> hunk, {current, acc}) when is_binary(current) do
    {current, add_hunk_lines(acc, current, hunk)}
  end

  defp consume_line(_, state), do: state

  defp add_hunk_lines(acc, current, hunk) do
    case Regex.run(~r/\+(\d+)(?:,(\d+))?/, hunk, capture: :all_but_first) do
      [start_line] ->
        add_single_changed_line(acc, current, start_line)

      [start_line, count] ->
        start_line = String.to_integer(start_line)
        count = String.to_integer(count)

        if count == 0 do
          Map.put_new(acc, current, MapSet.new())
        else
          lines = MapSet.new(start_line..(start_line + count - 1))
          Map.update(acc, current, lines, &MapSet.union(&1, lines))
        end

      _ ->
        acc
    end
  end

  defp add_single_changed_line(acc, current, start_line) do
    line = String.to_integer(start_line)
    Map.update(acc, current, MapSet.new([line]), &MapSet.put(&1, line))
  end

  defp normalize_path(path) do
    path
    |> String.replace_prefix("./", "")
    |> String.replace_prefix("elixir/", "")
  end
end
