defmodule SymphonyElixir.CoveragePolicy.DiffTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.CoveragePolicy.Diff

  setup do
    repo_dir =
      Path.join(System.tmp_dir!(), "coverage-policy-diff-#{System.unique_integer([:positive])}")

    File.rm_rf!(repo_dir)
    File.mkdir_p!(Path.join(repo_dir, "elixir/lib/sample"))

    {_output, 0} = System.cmd("git", ["-C", repo_dir, "init", "-b", "main"])
    {_output, 0} = System.cmd("git", ["-C", repo_dir, "config", "user.name", "Test User"])
    {_output, 0} = System.cmd("git", ["-C", repo_dir, "config", "user.email", "test@example.com"])

    File.write!(Path.join(repo_dir, "elixir/lib/sample/module.ex"), "defmodule Sample.Module do\n  def one, do: 1\nend\n")
    File.write!(Path.join(repo_dir, "elixir/README.md"), "docs\n")
    {_output, 0} = System.cmd("git", ["-C", repo_dir, "add", "."])
    {_output, 0} = System.cmd("git", ["-C", repo_dir, "commit", "-m", "initial"])

    on_exit(fn -> File.rm_rf!(repo_dir) end)
    %{repo_dir: repo_dir}
  end

  test "parses unified diff hunks including single, multi-line, zero-count and normalized paths" do
    diff = """
    diff --git a/elixir/lib/sample/module.ex b/elixir/lib/sample/module.ex
    --- a/elixir/lib/sample/module.ex
    +++ b/elixir/lib/sample/module.ex
    @@ -1,0 +1 @@
    +defmodule Sample.Module do
    @@ -4,0 +6,3 @@
    +  def two, do: 2
    +  def three, do: 3
    +  def four, do: 4
    diff --git a/./elixir/lib/sample/other.ex b/./elixir/lib/sample/other.ex
    +++ b/./elixir/lib/sample/other.ex
    @@ -10 +13,0 @@
    @@ nonsense @@
    """

    assert Diff.parse_unified_diff(diff) == %{
             "lib/sample/module.ex" => MapSet.new([1, 6, 7, 8]),
             "lib/sample/other.ex" => MapSet.new()
           }
  end

  test "ignores hunks before a target file and malformed hunk ranges" do
    diff = """
    @@ -1 +1 @@
    +ignored
    +++ b/elixir/lib/sample/module.ex
    @@ not-a-valid-range @@
    +still ignored
    """

    assert Diff.parse_unified_diff(diff) == %{}
  end

  test "reads changed lines from git diff output", %{repo_dir: repo_dir} do
    file = Path.join(repo_dir, "elixir/lib/sample/module.ex")
    {_output, 0} = System.cmd("git", ["-C", repo_dir, "checkout", "-b", "feature"])

    File.write!(file, "defmodule Sample.Module do\n  def one, do: 1\n  def two, do: 2\n  def three, do: 3\nend\n")
    {_output, 0} = System.cmd("git", ["-C", repo_dir, "add", "elixir/lib/sample/module.ex"])
    {_output, 0} = System.cmd("git", ["-C", repo_dir, "commit", "-m", "feature change"])

    assert Diff.changed_lines("main", git_root: repo_dir) == %{
             "lib/sample/module.ex" => MapSet.new([3, 4])
           }
  end

  test "raises when git diff command fails", %{repo_dir: repo_dir} do
    assert_raise ArgumentError, ~r/git diff against missing-base failed:/, fn ->
      Diff.changed_lines("missing-base", git_root: repo_dir)
    end
  end
end
