defmodule SymphonyElixir.CLITest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CLI

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  test "returns the guardrails acknowledgement banner when the flag is missing" do
    parent = self()

    deps = %{
      file_regular?: fn _path ->
        send(parent, :file_checked)
        true
      end,
      set_workflow_file_path: fn _path ->
        send(parent, :workflow_set)
        :ok
      end,
      set_logs_root: fn _path ->
        send(parent, :logs_root_set)
        :ok
      end,
      set_server_port_override: fn _port ->
        send(parent, :port_set)
        :ok
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end
    }

    assert {:error, banner} = CLI.evaluate(["WORKFLOW.md"], deps)
    assert banner =~ "This Symphony implementation is a low key engineering preview."
    assert banner =~ "Codex will run without any guardrails."
    assert banner =~ "SymphonyElixir is not a supported product and is presented as-is."
    assert banner =~ @ack_flag
    refute_received :file_checked
    refute_received :workflow_set
    refute_received :logs_root_set
    refute_received :port_set
    refute_received :started
  end

  test "defaults to WORKFLOW.md when workflow path is missing" do
    deps = %{
      file_regular?: fn path -> Path.basename(path) == "WORKFLOW.md" end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag], deps)
  end

  test "uses an explicit workflow path override when provided" do
    parent = self()
    workflow_path = "tmp/custom/WORKFLOW.md"
    expanded_path = Path.expand(workflow_path)

    deps = %{
      file_regular?: fn path ->
        send(parent, {:workflow_checked, path})
        path == expanded_path
      end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, workflow_path], deps)
    assert_received {:workflow_checked, ^expanded_path}
    assert_received {:workflow_set, ^expanded_path}
  end

  test "accepts --logs-root and passes an expanded root to runtime deps" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "--logs-root", "tmp/custom-logs", "WORKFLOW.md"], deps)
    assert_received {:logs_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-logs")
  end

  test "returns usage when --logs-root is missing its value" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, "Usage: symphony [--logs-root <path>] [--port <port>] [path-to-WORKFLOW.md]"} =
             CLI.evaluate([@ack_flag, "--logs-root"], deps)
  end

  test "returns not found when workflow file does not exist" do
    deps = %{
      file_regular?: fn _path -> false end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Workflow file not found:"
  end

  test "returns startup error when app cannot start" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:error, :boom} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Failed to start Symphony with workflow"
    assert message =~ ":boom"
  end

  test "returns ok when workflow exists and app starts" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
  end
end

defmodule SymphonyElixir.CLIScriptTest do
  use ExUnit.Case, async: false

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"
  @repo_root Path.expand("../../..", __DIR__)
  @script_path Path.join(@repo_root, "bin/symphony")

  test "rewrites relative workflow and logs root paths against the caller cwd before entering elixir" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-cli-script-explicit-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(test_root, "bin")
    trace_file = Path.join(test_root, "mise.trace")
    fake_mise = Path.join(fake_bin, "mise")
    previous_path = System.get_env("PATH")

    try do
      File.mkdir_p!(fake_bin)

      File.write!(fake_mise, """
      #!/usr/bin/env bash
      printf 'cwd=%s\n' "$PWD" > "$TRACE_FILE"
      printf 'args=%s\n' "$*" >> "$TRACE_FILE"
      """)

      File.chmod!(fake_mise, 0o755)

      {_, status} =
        System.cmd(
          @script_path,
          [@ack_flag, "./WORKFLOW.md", "--logs-root", "./log"],
          cd: @repo_root,
          env: [
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"TRACE_FILE", trace_file}
          ]
        )

      assert status == 0

      trace = File.read!(trace_file)
      assert trace =~ "cwd=#{Path.join(@repo_root, "elixir")}"
      assert trace =~ @ack_flag
      assert trace =~ "--logs-root #{@repo_root}/log"
      assert trace =~ "#{@repo_root}/WORKFLOW.md"
      assert trace =~ "SymphonyElixir.CLI.main(System.argv())"
    after
      File.rm_rf(test_root)
    end
  end

  test "injects the default workflow path from the caller cwd before entering elixir" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-cli-script-default-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(test_root, "bin")
    trace_file = Path.join(test_root, "mise.trace")
    fake_mise = Path.join(fake_bin, "mise")
    previous_path = System.get_env("PATH")

    try do
      File.mkdir_p!(fake_bin)

      File.write!(fake_mise, """
      #!/usr/bin/env bash
      printf 'cwd=%s\n' "$PWD" > "$TRACE_FILE"
      printf 'args=%s\n' "$*" >> "$TRACE_FILE"
      """)

      File.chmod!(fake_mise, 0o755)

      {_, status} =
        System.cmd(
          @script_path,
          [@ack_flag],
          cd: @repo_root,
          env: [
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"TRACE_FILE", trace_file}
          ]
        )

      assert status == 0

      trace = File.read!(trace_file)
      assert trace =~ "cwd=#{Path.join(@repo_root, "elixir")}"
      assert trace =~ @ack_flag
      assert trace =~ "#{@repo_root}/WORKFLOW.md"
      assert trace =~ "SymphonyElixir.CLI.main(System.argv())"
    after
      File.rm_rf(test_root)
    end
  end

  test "does not inject a default workflow when --logs-root is missing its value" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-cli-script-missing-logs-root-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(test_root, "bin")
    trace_file = Path.join(test_root, "mise.trace")
    fake_mise = Path.join(fake_bin, "mise")
    previous_path = System.get_env("PATH")

    try do
      File.mkdir_p!(fake_bin)

      File.write!(fake_mise, """
      #!/usr/bin/env bash
      printf 'cwd=%s\n' "$PWD" > "$TRACE_FILE"
      printf 'args=%s\n' "$*" >> "$TRACE_FILE"
      exit 64
      """)

      File.chmod!(fake_mise, 0o755)

      {_, status} =
        System.cmd(
          @script_path,
          [@ack_flag, "--logs-root"],
          cd: @repo_root,
          env: [
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"TRACE_FILE", trace_file}
          ],
          stderr_to_stdout: true
        )

      assert status == 64

      trace = File.read!(trace_file)
      assert trace =~ "cwd=#{Path.join(@repo_root, "elixir")}"
      assert trace =~ "args=exec -- mix run --no-start -e "
      assert trace =~ @ack_flag
      assert trace =~ " --logs-root"
      refute trace =~ "#{@repo_root}/WORKFLOW.md"
    after
      File.rm_rf(test_root)
    end
  end

  test "does not treat a following option as the value for --logs-root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-cli-script-logs-root-followed-by-option-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(test_root, "bin")
    trace_file = Path.join(test_root, "mise.trace")
    fake_mise = Path.join(fake_bin, "mise")
    previous_path = System.get_env("PATH")

    try do
      File.mkdir_p!(fake_bin)

      File.write!(fake_mise, """
      #!/usr/bin/env bash
      printf 'cwd=%s\n' "$PWD" > "$TRACE_FILE"
      printf 'args=%s\n' "$*" >> "$TRACE_FILE"
      exit 64
      """)

      File.chmod!(fake_mise, 0o755)

      {_, status} =
        System.cmd(
          @script_path,
          [@ack_flag, "--logs-root", "--port", "4000"],
          cd: @repo_root,
          env: [
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"TRACE_FILE", trace_file}
          ],
          stderr_to_stdout: true
        )

      assert status == 64

      trace = File.read!(trace_file)
      assert trace =~ "cwd=#{Path.join(@repo_root, "elixir")}"
      assert trace =~ "args=exec -- mix run --no-start -e "
      assert trace =~ @ack_flag
      assert trace =~ " --logs-root --port 4000"
      refute trace =~ "--logs-root #{@repo_root}/--port"
      refute trace =~ "#{@repo_root}/WORKFLOW.md"
    after
      File.rm_rf(test_root)
    end
  end
end

defmodule SymphonyElixir.FormalStartScriptTest do
  use ExUnit.Case, async: false

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"
  @repo_root Path.expand("../../..", __DIR__)
  @script_path Path.join(@repo_root, "bin/symphony_start")

  test "uses the in-repo workflow and injects default logs root and port" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-formal-start-defaults-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(test_root, "bin")
    fake_mise = Path.join(fake_bin, "mise")
    fake_codex = Path.join(fake_bin, "codex")
    trace_file = Path.join(test_root, "mise.trace")
    xdg_state_home = Path.join(test_root, "xdg-state")
    previous_path = System.get_env("PATH")
    default_logs_root = Path.join(xdg_state_home, "powersymphony")

    try do
      File.mkdir_p!(fake_bin)
      write_fake_command(fake_mise, ~S(printf 'cwd=%s\n' "$PWD" > "$TRACE_FILE"
printf 'args=%s\n' "$*" >> "$TRACE_FILE"))
      write_fake_command(fake_codex, "exit 0")

      {_, status} =
        System.cmd(@script_path, [@ack_flag],
          cd: @repo_root,
          env: [
            {"LINEAR_API_KEY", "linear-test-token"},
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"TRACE_FILE", trace_file},
            {"XDG_STATE_HOME", xdg_state_home}
          ]
        )

      assert status == 0

      trace = File.read!(trace_file)
      assert trace =~ "cwd=#{Path.join(@repo_root, "elixir")}"
      assert trace =~ @ack_flag
      assert trace =~ "--logs-root #{default_logs_root}"
      assert trace =~ "--port 0"
      assert trace =~ "#{@repo_root}/elixir/WORKFLOW.md"
      assert trace =~ "SymphonyElixir.CLI.main(System.argv())"
    after
      File.rm_rf(test_root)
    end
  end

  test "preserves explicit logs root and port overrides while pinning the workflow path" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-formal-start-overrides-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(test_root, "bin")
    fake_mise = Path.join(fake_bin, "mise")
    fake_codex = Path.join(fake_bin, "codex")
    trace_file = Path.join(test_root, "mise.trace")
    previous_path = System.get_env("PATH")
    explicit_logs_root = Path.join(test_root, "custom-logs")

    try do
      File.mkdir_p!(fake_bin)
      write_fake_command(fake_mise, ~S(printf 'cwd=%s\n' "$PWD" > "$TRACE_FILE"
printf 'args=%s\n' "$*" >> "$TRACE_FILE"))
      write_fake_command(fake_codex, "exit 0")

      {_, status} =
        System.cmd(@script_path, [@ack_flag, "--logs-root", explicit_logs_root, "--port", "4311"],
          cd: @repo_root,
          env: [
            {"LINEAR_API_KEY", "linear-test-token"},
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"TRACE_FILE", trace_file}
          ]
        )

      assert status == 0

      trace = File.read!(trace_file)
      assert trace =~ "--logs-root #{explicit_logs_root}"
      assert trace =~ "--port 4311"
      assert trace =~ "#{@repo_root}/elixir/WORKFLOW.md"
      refute trace =~ "--port 0"
    after
      File.rm_rf(test_root)
    end
  end

  test "copied script still targets the current repository workflow by default" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-formal-start-copied-script-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(test_root, "bin")
    fake_mise = Path.join(fake_bin, "mise")
    fake_codex = Path.join(fake_bin, "codex")
    copied_script = Path.join(fake_bin, "symphony_start")
    trace_file = Path.join(test_root, "mise.trace")
    previous_path = System.get_env("PATH")

    try do
      File.mkdir_p!(fake_bin)
      write_fake_command(fake_mise, ~S(printf 'cwd=%s\n' "$PWD" > "$TRACE_FILE"
printf 'args=%s\n' "$*" >> "$TRACE_FILE"))
      write_fake_command(fake_codex, "exit 0")
      File.cp!(@script_path, copied_script)
      File.chmod!(copied_script, 0o755)

      {_, status} =
        System.cmd(copied_script, [@ack_flag],
          cd: test_root,
          env: [
            {"LINEAR_API_KEY", "linear-test-token"},
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"TRACE_FILE", trace_file}
          ]
        )

      assert status == 0

      trace = File.read!(trace_file)
      assert trace =~ "#{@repo_root}/elixir/WORKFLOW.md"
    after
      File.rm_rf(test_root)
    end
  end

  test "returns a clear error when LINEAR_API_KEY is missing" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-formal-start-missing-linear-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(test_root, "bin")
    fake_mise = Path.join(fake_bin, "mise")
    fake_codex = Path.join(fake_bin, "codex")
    trace_file = Path.join(test_root, "mise.trace")
    previous_path = System.get_env("PATH")

    try do
      File.mkdir_p!(fake_bin)
      write_fake_command(fake_mise, "exit 0")
      write_fake_command(fake_codex, "exit 0")

      {output, status} =
        System.cmd(@script_path, [@ack_flag],
          cd: @repo_root,
          env: [
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"TRACE_FILE", trace_file}
          ],
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ "LINEAR_API_KEY"
      assert output =~ "export"
      refute File.exists?(trace_file)
    after
      File.rm_rf(test_root)
    end
  end

  test "returns a clear error when codex is missing" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-formal-start-missing-codex-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(test_root, "bin")

    try do
      File.mkdir_p!(fake_bin)

      {output, status} =
        System.cmd(@script_path, [@ack_flag],
          cd: @repo_root,
          env: [
            {"LINEAR_API_KEY", "linear-test-token"},
            {"PATH", "#{fake_bin}:/usr/bin:/bin"}
          ],
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ "codex"
      assert output =~ "PATH"
    after
      File.rm_rf(test_root)
    end
  end

  test "returns a clear error when the fixed workflow file is missing" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-formal-start-missing-workflow-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(test_root, "bin")
    fake_codex = Path.join(fake_bin, "codex")
    previous_path = System.get_env("PATH")

    try do
      File.mkdir_p!(fake_bin)
      write_fake_command(fake_codex, "exit 0")

      {output, status} =
        System.cmd(@script_path, [@ack_flag],
          cd: @repo_root,
          env: [
            {"LINEAR_API_KEY", "linear-test-token"},
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"POWERSYMPHONY_ROOT", test_root}
          ],
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ "Workflow file not found:"
      assert output =~ Path.join(test_root, "elixir/WORKFLOW.md")
    after
      File.rm_rf(test_root)
    end
  end

  test "returns a clear error when neither XDG_STATE_HOME nor HOME is available" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-formal-start-missing-home-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(test_root, "bin")
    fake_codex = Path.join(fake_bin, "codex")
    fake_mise = Path.join(fake_bin, "mise")
    previous_path = System.get_env("PATH")

    try do
      File.mkdir_p!(fake_bin)
      write_fake_command(fake_codex, "exit 0")
      write_fake_command(fake_mise, "exit 0")

      {output, status} =
        System.cmd(@script_path, [@ack_flag],
          cd: @repo_root,
          env: [
            {"LINEAR_API_KEY", "linear-test-token"},
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"HOME", nil},
            {"XDG_STATE_HOME", nil}
          ],
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ "HOME"
      assert output =~ "XDG_STATE_HOME"
    after
      File.rm_rf(test_root)
    end
  end

  test "returns usage when --logs-root is followed by another option" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-formal-start-logs-root-followed-by-option-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(test_root, "bin")
    fake_codex = Path.join(fake_bin, "codex")
    fake_mise = Path.join(fake_bin, "mise")
    trace_file = Path.join(test_root, "mise.trace")
    previous_path = System.get_env("PATH")

    try do
      File.mkdir_p!(fake_bin)
      write_fake_command(fake_codex, "exit 0")
      write_fake_command(fake_mise, ~S(printf 'args=%s\n' "$*" > "$TRACE_FILE"))

      {output, status} =
        System.cmd(@script_path, [@ack_flag, "--logs-root", "--port", "4311"],
          cd: @repo_root,
          env: [
            {"LINEAR_API_KEY", "linear-test-token"},
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"TRACE_FILE", trace_file}
          ],
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ "Usage: symphony_start"
      refute File.exists?(trace_file)
    after
      File.rm_rf(test_root)
    end
  end

  test "returns usage when --port is followed by another option" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-formal-start-port-followed-by-option-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(test_root, "bin")
    fake_codex = Path.join(fake_bin, "codex")
    fake_mise = Path.join(fake_bin, "mise")
    trace_file = Path.join(test_root, "mise.trace")
    previous_path = System.get_env("PATH")

    try do
      File.mkdir_p!(fake_bin)
      write_fake_command(fake_codex, "exit 0")
      write_fake_command(fake_mise, ~S(printf 'args=%s\n' "$*" > "$TRACE_FILE"))

      {output, status} =
        System.cmd(@script_path, [@ack_flag, "--port", "--logs-root", "/tmp/logs"],
          cd: @repo_root,
          env: [
            {"LINEAR_API_KEY", "linear-test-token"},
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"TRACE_FILE", trace_file}
          ],
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ "Usage: symphony_start"
      refute File.exists?(trace_file)
    after
      File.rm_rf(test_root)
    end
  end

  test "help works even when runtime prerequisites are missing" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-formal-start-help-without-prereqs-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(test_root, "bin")

    try do
      File.mkdir_p!(fake_bin)

      {output, status} =
        System.cmd(@script_path, ["--help"],
          cd: @repo_root,
          env: [
            {"PATH", "#{fake_bin}:/usr/bin:/bin"},
            {"HOME", nil},
            {"XDG_STATE_HOME", nil},
            {"LINEAR_API_KEY", nil}
          ],
          stderr_to_stdout: true
        )

      assert status == 0
      assert output =~ "Usage: symphony_start"
      refute output =~ "LINEAR_API_KEY"
      refute output =~ "codex"
      refute output =~ "Workflow file not found"
    after
      File.rm_rf(test_root)
    end
  end

  test "returns a clear error when mise is missing" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-formal-start-missing-mise-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(test_root, "bin")
    fake_codex = Path.join(fake_bin, "codex")

    try do
      File.mkdir_p!(fake_bin)
      write_fake_command(fake_codex, "exit 0")

      {output, status} =
        System.cmd(@script_path, [@ack_flag],
          cd: @repo_root,
          env: [
            {"LINEAR_API_KEY", "linear-test-token"},
            {"PATH", "#{fake_bin}:/usr/bin:/bin"},
            {"HOME", "/tmp/symphony-home"}
          ],
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ "mise"
      assert output =~ "PATH"
    after
      File.rm_rf(test_root)
    end
  end

  defp write_fake_command(path, body) do
    File.write!(path, "#!/usr/bin/env bash\nset -euo pipefail\n#{body}\n")
    File.chmod!(path, 0o755)
  end
end
