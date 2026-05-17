defmodule Mix.Tasks.Workspace.BeforeRemoveTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Workspace.BeforeRemove

  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("workspace.before_remove")
    :ok
  end

  test "prints help" do
    output =
      capture_io(fn ->
        BeforeRemove.run(["--help"])
      end)

    assert output =~ "mix workspace.before_remove"
  end

  test "fails on invalid options" do
    assert_raise Mix.Error, ~r/Invalid option/, fn ->
      BeforeRemove.run(["--wat"])
    end
  end

  test "no-ops when branch is unavailable" do
    with_path([], fn ->
      in_temp_dir(fn ->
        output =
          capture_io(fn ->
            BeforeRemove.run([])
          end)

        assert output == ""
      end)
    end)
  end

  test "no-ops when github helper runtime is unavailable" do
    with_path([], fn ->
      output =
        capture_io(fn ->
          BeforeRemove.run(["--branch", "feature/no-helper"])
        end)

      assert output == ""
    end)
  end

  test "uses current branch for lookup when branch option is omitted" do
    with_fake_helper_and_git(
      """
      #!/bin/sh
      shift
      printf '%s\n' "$*" >> "$GITHUB_HELPER_LOG"

      if [ "$1" = "list-prs" ]; then
        printf '[{"number":101},{"number":102}]'
        exit 0
      fi

      if [ "$1" = "close-pr" ] && [ "$5" = "101" ]; then
        printf '{}'
        exit 0
      fi

      if [ "$1" = "close-pr" ] && [ "$5" = "102" ]; then
        printf 'boom\n' >&2
        exit 17
      fi

      exit 99
      """,
      """
      #!/bin/sh
      printf 'feature/workpad\n'
      exit 0
      """,
      fn log_path ->
        {output, error_output} =
          capture_task_output(fn ->
            BeforeRemove.run([])
          end)

        assert output =~ "Closed PR #101 for branch feature/workpad"
        assert error_output =~ "Failed to close PR #102 for branch feature/workpad"

        log = File.read!(log_path)

        assert log =~ "list-prs --repo openai/symphony --branch feature/workpad --state open"
        assert log =~ "close-pr --repo openai/symphony --number 101"
        assert log =~ "close-pr --repo openai/symphony --number 102"
      end
    )
  end

  test "closes open pull requests for the branch and tolerates close failures" do
    with_fake_helper(fn log_path ->
      File.write!(log_path, "")

      {output, error_output} =
        capture_task_output(fn ->
          BeforeRemove.run(["--branch", "feature/workpad"])
        end)

      assert output =~ "Closed PR #101 for branch feature/workpad"
      assert error_output =~ "Failed to close PR #102 for branch feature/workpad"

      log = File.read!(log_path)

      assert log =~ "list-prs --repo openai/symphony --branch feature/workpad --state open"
      assert log =~ "close-pr --repo openai/symphony --number 101"
      assert log =~ "close-pr --repo openai/symphony --number 102"

      {second_output, error_output} =
        capture_task_output(fn ->
          Mix.Task.reenable("workspace.before_remove")
          BeforeRemove.run(["--branch", "feature/workpad"])
        end)

      assert second_output =~ "Closed PR #101 for branch feature/workpad"
      assert error_output =~ "Failed to close PR #102 for branch feature/workpad"
    end)
  end

  test "formats close failures without command stderr output" do
    with_fake_helper(
      """
      #!/bin/sh
      shift
      printf '%s\n' "$*" >> "$GITHUB_HELPER_LOG"

      if [ "$1" = "list-prs" ]; then
        printf '[{"number":102}]'
        exit 0
      fi

      if [ "$1" = "close-pr" ] && [ "$5" = "102" ]; then
        exit 17
      fi

      exit 99
      """,
      fn log_path ->
        error_output =
          capture_io(:stderr, fn ->
            Mix.Task.reenable("workspace.before_remove")
            BeforeRemove.run(["--branch", "feature/no-output"])
          end)

        assert error_output =~ "Failed to close PR #102 for branch feature/no-output: exit 17"
        refute error_output =~ "output="
        log = File.read!(log_path)
        assert log =~ "list-prs --repo openai/symphony --branch feature/no-output --state open"
        assert log =~ "close-pr --repo openai/symphony --number 102"
      end
    )
  end

  test "no-ops when PR list fails for current branch" do
    with_fake_helper(
      """
      #!/bin/sh
      shift
      printf '%s\n' "$*" >> "$GITHUB_HELPER_LOG"

      if [ "$1" = "list-prs" ]; then
        exit 1
      fi

      exit 99
      """,
      fn log_path ->
        output =
          capture_io(fn ->
            BeforeRemove.run(["--branch", "feature/list-fails"])
          end)

        assert output == ""

        log = File.read!(log_path)
        assert log =~ "list-prs --repo openai/symphony --branch feature/list-fails --state open"
        refute log =~ "close-pr"
      end
    )
  end

  test "no-ops when PR list output is not a JSON list" do
    cases = [
      {"feature/invalid-json", "not-json"},
      {"feature/not-a-list", ~s({"number":101})}
    ]

    Enum.each(cases, fn {branch, list_output} ->
      with_fake_helper(
        """
        #!/bin/sh
        shift
        printf '%s\n' "$*" >> "$GITHUB_HELPER_LOG"

        if [ "$1" = "list-prs" ]; then
          printf '#{list_output}'
          exit 0
        fi

        exit 99
        """,
        fn log_path ->
          output =
            capture_io(fn ->
              BeforeRemove.run(["--branch", branch])
            end)

          assert output == ""

          log = File.read!(log_path)
          assert log =~ "list-prs --repo openai/symphony --branch #{branch} --state open"
          refute log =~ "close-pr"
        end
      )
    end)
  end

  test "no-ops when git current branch is blank" do
    with_fake_helper_and_git(
      """
      #!/bin/sh
      shift
      printf '%s\n' "$*" >> "$GITHUB_HELPER_LOG"
      exit 99
      """,
      """
      #!/bin/sh
      printf '\n'
      exit 0
      """,
      fn log_path ->
        output =
          capture_io(fn ->
            BeforeRemove.run([])
          end)

        assert output == ""

        log = File.read!(log_path)
        assert log == ""
        refute log =~ "list-prs"
      end
    )
  end

  test "no-ops when github helper lookup fails immediately" do
    with_fake_helper(
      """
      #!/bin/sh
      shift
      printf '%s\n' "$*" >> "$GITHUB_HELPER_LOG"
      exit 1
      """,
      fn log_path ->
        BeforeRemove.run(["--branch", "feature/no-helper-response"])

        log = File.read!(log_path)
        assert log =~ "list-prs --repo openai/symphony --branch feature/no-helper-response --state open"
        refute log =~ "close-pr"
      end
    )
  end

  defp with_fake_helper(fun) do
    with_fake_binaries(
      %{
        "python3" => """
        #!/bin/sh
        shift
        printf '%s\n' "$*" >> "$GITHUB_HELPER_LOG"

        if [ "$1" = "list-prs" ]; then
          printf '[{"number":101},{"number":102}]'
          exit 0
        fi

        if [ "$1" = "close-pr" ] && [ "$5" = "101" ]; then
          printf '{}'
          exit 0
        fi

        if [ "$1" = "close-pr" ] && [ "$5" = "102" ]; then
          printf 'boom\n' >&2
          exit 17
        fi

        exit 99
        """
      },
      fun
    )
  end

  defp with_fake_helper(script, fun) do
    with_fake_binaries(%{"python3" => script}, fun)
  end

  defp with_fake_helper_and_git(helper_script, git_script, fun) do
    with_fake_binaries(%{"python3" => helper_script, "git" => git_script}, fun)
  end

  defp with_fake_binaries(scripts, fun) do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-task-test-#{unique}")
    bin_dir = Path.join(root, "bin")
    log_path = Path.join(root, "github-helper.log")

    try do
      File.rm_rf!(root)
      File.mkdir_p!(bin_dir)
      File.write!(log_path, "")
      original_path = System.get_env("PATH") || ""
      path_with_binaries = Enum.join([bin_dir, original_path], ":")

      Enum.each(scripts, fn {name, script} ->
        path = Path.join(bin_dir, name)
        File.write!(path, script)
        File.chmod!(path, 0o755)
      end)

      with_env(
        %{
          "GITHUB_HELPER_LOG" => log_path,
          "PATH" => path_with_binaries
        },
        fn ->
          fun.(log_path)
        end
      )
    after
      File.rm_rf!(root)
    end
  end

  defp with_path(paths, fun) do
    with_env(%{"PATH" => Enum.join(paths, ":")}, fun)
  end

  defp with_env(overrides, fun) do
    keys = Map.keys(overrides)
    previous = Map.new(keys, fn key -> {key, System.get_env(key)} end)

    try do
      Enum.each(overrides, fn {key, value} -> System.put_env(key, value) end)
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  defp in_temp_dir(fun) do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "workspace-before-remove-empty-dir-#{unique}")

    File.rm_rf!(root)
    File.mkdir_p!(root)

    original_cwd = File.cwd!()

    try do
      File.cd!(root)
      fun.()
    after
      File.cd!(original_cwd)
      File.rm_rf!(root)
    end
  end

  defp capture_task_output(fun) do
    parent = self()
    ref = make_ref()

    error_output =
      capture_io(:stderr, fn ->
        output =
          capture_io(fn ->
            fun.()
          end)

        send(parent, {ref, output})
      end)

    output =
      receive do
        {^ref, output} -> output
      after
        1_000 -> flunk("Timed out waiting for captured task output")
      end

    {output, error_output}
  end
end
