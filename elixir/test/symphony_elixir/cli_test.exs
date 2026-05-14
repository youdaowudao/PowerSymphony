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
    fake_ss = Path.join(fake_bin, "ss")
    trace_file = Path.join(test_root, "mise.trace")
    xdg_state_home = Path.join(test_root, "xdg-state")
    previous_path = System.get_env("PATH")
    default_logs_root = Path.join(xdg_state_home, "powersymphony")
    home_dir = Path.join(test_root, "home")
    token_dir = Path.join(home_dir, ".config/linear")
    token_file = Path.join(token_dir, "linear_api_key.token")

    try do
      File.mkdir_p!(fake_bin)
      File.mkdir_p!(token_dir)
      File.write!(token_file, "file-token-value\n")
      write_fake_command(fake_mise, ~S(printf 'cwd=%s\n' "$PWD" > "$TRACE_FILE"
printf 'args=%s\n' "$*" >> "$TRACE_FILE"))
      write_fake_command(fake_codex, "exit 0")
      write_fake_command(fake_ss, "printf ''")

      {_, status} =
        System.cmd(@script_path, [@ack_flag],
          cd: @repo_root,
          env: [
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"TRACE_FILE", trace_file},
            {"XDG_STATE_HOME", xdg_state_home},
            {"HOME", home_dir}
          ]
        )

      assert status == 0

      trace = File.read!(trace_file)
      assert trace =~ "cwd=#{Path.join(@repo_root, "elixir")}"
      assert trace =~ @ack_flag
      assert trace =~ "--logs-root #{default_logs_root}"
      assert trace =~ "--port 4000"
      assert trace =~ Path.join(@repo_root, "elixir/WORKFLOW.md")
      assert trace =~ "SymphonyElixir.CLI.main(System.argv())"
    after
      File.rm_rf(test_root)
    end
  end

  test "reads LINEAR_API_KEY from the token file, trims surrounding whitespace, and preserves internal whitespace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-formal-start-token-file-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(test_root, "bin")
    fake_mise = Path.join(fake_bin, "mise")
    fake_codex = Path.join(fake_bin, "codex")
    trace_file = Path.join(test_root, "mise.trace")
    previous_path = System.get_env("PATH")
    home_dir = Path.join(test_root, "home")
    token_dir = Path.join(home_dir, ".config/linear")
    token_file = Path.join(token_dir, "linear_api_key.token")
    port = available_tcp_port()

    try do
      File.mkdir_p!(fake_bin)
      File.mkdir_p!(token_dir)
      File.write!(token_file, " \n  file token value \t\n")
      write_fake_command(fake_mise, ~S(printf 'cwd=%s\n' "$PWD" > "$TRACE_FILE"
printf 'args=%s\n' "$*" >> "$TRACE_FILE"
printf 'linear=%s\n' "$LINEAR_API_KEY" >> "$TRACE_FILE"))
      write_fake_command(fake_codex, "exit 0")

      {_, status} =
        System.cmd(@script_path, [@ack_flag, "--port", Integer.to_string(port)],
          cd: @repo_root,
          env: [
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"TRACE_FILE", trace_file},
            {"HOME", home_dir}
          ]
        )

      assert status == 0

      trace = File.read!(trace_file)
      assert trace =~ "linear=file token value"
      assert trace =~ "--port #{port}"
    after
      File.rm_rf(test_root)
    end
  end

  test "reads the token file successfully without requiring perl in PATH" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-formal-start-without-perl-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(test_root, "bin")
    fake_mise = Path.join(fake_bin, "mise")
    fake_codex = Path.join(fake_bin, "codex")
    trace_file = Path.join(test_root, "mise.trace")
    home_dir = Path.join(test_root, "home")
    token_dir = Path.join(home_dir, ".config/linear")
    token_file = Path.join(token_dir, "linear_api_key.token")
    port = available_tcp_port()

    try do
      File.mkdir_p!(fake_bin)
      File.mkdir_p!(token_dir)
      File.write!(token_file, " trimmed token \n")
      write_fake_command(fake_mise, ~S(printf 'linear=%s\n' "$LINEAR_API_KEY" > "$TRACE_FILE"))
      write_fake_command(fake_codex, "exit 0")

      {_, status} =
        System.cmd(@script_path, [@ack_flag, "--port", Integer.to_string(port)],
          cd: @repo_root,
          env: [
            {"PATH", "#{fake_bin}:/usr/bin:/bin"},
            {"TRACE_FILE", trace_file},
            {"HOME", home_dir}
          ]
        )

      assert status == 0
      assert File.read!(trace_file) =~ "linear=trimmed token"
    after
      File.rm_rf(test_root)
    end
  end

  test "prefers explicit LINEAR_API_KEY over the token file" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-formal-start-explicit-linear-env-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(test_root, "bin")
    fake_mise = Path.join(fake_bin, "mise")
    fake_codex = Path.join(fake_bin, "codex")
    trace_file = Path.join(test_root, "mise.trace")
    previous_path = System.get_env("PATH")
    home_dir = Path.join(test_root, "home")
    token_dir = Path.join(home_dir, ".config/linear")
    token_file = Path.join(token_dir, "linear_api_key.token")
    port = available_tcp_port()

    try do
      File.mkdir_p!(fake_bin)
      File.mkdir_p!(token_dir)
      File.write!(token_file, "file-token-value\n")
      write_fake_command(fake_mise, ~S(printf 'linear=%s\n' "$LINEAR_API_KEY" > "$TRACE_FILE"))
      write_fake_command(fake_codex, "exit 0")

      {_, status} =
        System.cmd(@script_path, [@ack_flag, "--port", Integer.to_string(port)],
          cd: @repo_root,
          env: [
            {"LINEAR_API_KEY", "explicit-env-token"},
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"TRACE_FILE", trace_file},
            {"HOME", home_dir}
          ]
        )

      assert status == 0
      assert File.read!(trace_file) =~ "linear=explicit-env-token"
    after
      File.rm_rf(test_root)
    end
  end

  test "prefers an explicitly empty LINEAR_API_KEY over the token file" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-formal-start-explicit-empty-linear-env-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(test_root, "bin")
    fake_mise = Path.join(fake_bin, "mise")
    fake_codex = Path.join(fake_bin, "codex")
    trace_file = Path.join(test_root, "mise.trace")
    previous_path = System.get_env("PATH")
    home_dir = Path.join(test_root, "home")
    token_dir = Path.join(home_dir, ".config/linear")
    token_file = Path.join(token_dir, "linear_api_key.token")
    port = available_tcp_port()

    try do
      File.mkdir_p!(fake_bin)
      File.mkdir_p!(token_dir)
      File.write!(token_file, "file-token-value\n")
      write_fake_command(fake_mise, ~S(printf 'linear=<%s>\n' "$LINEAR_API_KEY" > "$TRACE_FILE"))
      write_fake_command(fake_codex, "exit 0")

      command =
        ~s(LINEAR_API_KEY='' "#{@script_path}" #{@ack_flag} --port #{port})

      {_, status} =
        System.cmd("bash", ["-lc", command],
          cd: @repo_root,
          env: [
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"TRACE_FILE", trace_file},
            {"HOME", home_dir}
          ]
        )

      assert status == 0
      assert File.read!(trace_file) =~ "linear=<>"
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
    home_dir = Path.join(test_root, "home")
    token_dir = Path.join(home_dir, ".config/linear")
    token_file = Path.join(token_dir, "linear_api_key.token")
    port = available_tcp_port()

    try do
      File.mkdir_p!(fake_bin)
      File.mkdir_p!(token_dir)
      File.write!(token_file, "file-token-value\n")
      write_fake_command(fake_mise, ~S(printf 'cwd=%s\n' "$PWD" > "$TRACE_FILE"
printf 'args=%s\n' "$*" >> "$TRACE_FILE"))
      write_fake_command(fake_codex, "exit 0")

      {_, status} =
        System.cmd(@script_path, [@ack_flag, "--logs-root", explicit_logs_root, "--port", Integer.to_string(port)],
          cd: @repo_root,
          env: [
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"TRACE_FILE", trace_file},
            {"HOME", home_dir}
          ]
        )

      assert status == 0

      trace = File.read!(trace_file)
      assert trace =~ "--logs-root #{explicit_logs_root}"
      assert trace =~ "--port #{port}"
      assert trace =~ "#{@repo_root}/elixir/WORKFLOW.md"
      refute trace =~ "--port 4000"
    after
      File.rm_rf(test_root)
    end
  end

  test "copied script returns a clear error when repo root is not configured" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-formal-start-copied-script-missing-root-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(test_root, "bin")
    fake_mise = Path.join(fake_bin, "mise")
    fake_codex = Path.join(fake_bin, "codex")
    copied_script = Path.join(fake_bin, "symphony_start")
    trace_file = Path.join(test_root, "mise.trace")
    previous_path = System.get_env("PATH")
    home_dir = Path.join(test_root, "home")
    token_dir = Path.join(home_dir, ".config/linear")
    token_file = Path.join(token_dir, "linear_api_key.token")

    try do
      File.mkdir_p!(fake_bin)
      File.mkdir_p!(token_dir)
      File.write!(token_file, "file-token-value\n")
      write_fake_command(fake_mise, ~S(printf 'cwd=%s\n' "$PWD" > "$TRACE_FILE"
printf 'args=%s\n' "$*" >> "$TRACE_FILE"))
      write_fake_command(fake_codex, "exit 0")
      File.cp!(@script_path, copied_script)
      File.chmod!(copied_script, 0o755)

      {output, status} =
        System.cmd(copied_script, [@ack_flag],
          cd: test_root,
          env: [
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"TRACE_FILE", trace_file},
            {"HOME", home_dir}
          ],
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ "POWERSYMPHONY_ROOT"
      assert output =~ "bin/symphony_start"
      refute File.exists?(trace_file)
    after
      File.rm_rf(test_root)
    end
  end

  test "auto-discovered repo root still reports workflow not found when WORKFLOW.md is missing" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-formal-start-autodiscovered-root-missing-workflow-#{System.unique_integer([:positive])}"
      )

    repo_root = Path.join(test_root, "repo")
    repo_bin = Path.join(repo_root, "bin")
    repo_elixir = Path.join(repo_root, "elixir")
    fake_bin = Path.join(test_root, "fake-bin")
    fake_codex = Path.join(fake_bin, "codex")
    fake_mise = Path.join(fake_bin, "mise")
    copied_script = Path.join(repo_bin, "symphony_start")
    wrapped_symphony = Path.join(repo_bin, "symphony")
    previous_path = System.get_env("PATH")
    home_dir = Path.join(test_root, "home")
    token_dir = Path.join(home_dir, ".config/linear")
    token_file = Path.join(token_dir, "linear_api_key.token")

    try do
      File.mkdir_p!(repo_bin)
      File.mkdir_p!(repo_elixir)
      File.mkdir_p!(fake_bin)
      File.mkdir_p!(token_dir)
      File.write!(token_file, "file-token-value\n")
      File.cp!(@script_path, copied_script)
      File.chmod!(copied_script, 0o755)
      write_fake_command(wrapped_symphony, "exit 0")
      write_fake_command(fake_codex, "exit 0")
      write_fake_command(fake_mise, "exit 0")

      {output, status} =
        System.cmd(copied_script, [@ack_flag],
          cd: repo_root,
          env: [
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"HOME", home_dir}
          ],
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ "Workflow file not found:"
      assert output =~ Path.join(repo_elixir, "WORKFLOW.md")
    after
      File.rm_rf(test_root)
    end
  end

  test "copied script succeeds when POWERSYMPHONY_ROOT is provided" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-formal-start-copied-script-with-root-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(test_root, "bin")
    fake_mise = Path.join(fake_bin, "mise")
    fake_codex = Path.join(fake_bin, "codex")
    copied_script = Path.join(fake_bin, "symphony_start")
    trace_file = Path.join(test_root, "mise.trace")
    previous_path = System.get_env("PATH")
    home_dir = Path.join(test_root, "home")
    token_dir = Path.join(home_dir, ".config/linear")
    token_file = Path.join(token_dir, "linear_api_key.token")
    port = available_tcp_port()

    try do
      File.mkdir_p!(fake_bin)
      File.mkdir_p!(token_dir)
      File.write!(token_file, "file-token-value\n")
      write_fake_command(fake_mise, ~S(printf 'args=%s\n' "$*" > "$TRACE_FILE"))
      write_fake_command(fake_codex, "exit 0")
      File.cp!(@script_path, copied_script)
      File.chmod!(copied_script, 0o755)

      {_, status} =
        System.cmd(copied_script, [@ack_flag, "--port", Integer.to_string(port)],
          cd: test_root,
          env: [
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"TRACE_FILE", trace_file},
            {"HOME", home_dir},
            {"POWERSYMPHONY_ROOT", @repo_root}
          ]
        )

      assert status == 0
      assert File.read!(trace_file) =~ Path.join(@repo_root, "elixir/WORKFLOW.md")
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
            {"TRACE_FILE", trace_file},
            {"HOME", test_root}
          ],
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ "linear_api_key.token"
      assert output =~ ".config/linear"
      refute File.exists?(trace_file)
    after
      File.rm_rf(test_root)
    end
  end

  test "returns a clear error when the token file is blank after trimming" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-formal-start-empty-token-file-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(test_root, "bin")
    fake_mise = Path.join(fake_bin, "mise")
    fake_codex = Path.join(fake_bin, "codex")
    previous_path = System.get_env("PATH")
    home_dir = Path.join(test_root, "home")
    token_dir = Path.join(home_dir, ".config/linear")
    token_file = Path.join(token_dir, "linear_api_key.token")

    try do
      File.mkdir_p!(fake_bin)
      File.mkdir_p!(token_dir)
      File.write!(token_file, " \n\t \n")
      write_fake_command(fake_mise, "exit 0")
      write_fake_command(fake_codex, "exit 0")

      {output, status} =
        System.cmd(@script_path, [@ack_flag],
          cd: @repo_root,
          env: [
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"HOME", home_dir}
          ],
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ "linear_api_key.token"
      assert output =~ "empty"
    after
      File.rm_rf(test_root)
    end
  end

  test "returns a clear error when the token path exists but is not a regular file" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-formal-start-token-not-regular-file-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(test_root, "bin")
    fake_mise = Path.join(fake_bin, "mise")
    fake_codex = Path.join(fake_bin, "codex")
    previous_path = System.get_env("PATH")
    home_dir = Path.join(test_root, "home")
    token_dir = Path.join(home_dir, ".config/linear")
    token_path = Path.join(token_dir, "linear_api_key.token")

    try do
      File.mkdir_p!(fake_bin)
      File.mkdir_p!(token_path)
      write_fake_command(fake_mise, "exit 0")
      write_fake_command(fake_codex, "exit 0")

      {output, status} =
        System.cmd(@script_path, [@ack_flag],
          cd: @repo_root,
          env: [
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"HOME", home_dir}
          ],
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ "linear_api_key.token"
      assert output =~ "regular file"
    after
      File.rm_rf(test_root)
    end
  end

  test "returns a clear error when the token file is not readable" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-formal-start-token-not-readable-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(test_root, "bin")
    fake_mise = Path.join(fake_bin, "mise")
    fake_codex = Path.join(fake_bin, "codex")
    previous_path = System.get_env("PATH")
    blocked_root = Path.join(test_root, "blocked")
    blocked_token_dir = Path.join(blocked_root, ".config/linear")
    blocked_token_file = Path.join(blocked_token_dir, "linear_api_key.token")

    try do
      File.mkdir_p!(fake_bin)
      File.mkdir_p!(blocked_token_dir)
      File.write!(blocked_token_file, "file-token-value\n")
      File.chmod!(blocked_root, 0o000)
      write_fake_command(fake_mise, "exit 0")
      write_fake_command(fake_codex, "exit 0")

      {output, status} =
        System.cmd(@script_path, [@ack_flag],
          cd: @repo_root,
          env: [
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"HOME", blocked_root}
          ],
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ "linear_api_key.token"
      assert output =~ "readable"
    after
      File.chmod(blocked_root, 0o700)
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
    home_dir = Path.join(test_root, "home")
    token_dir = Path.join(home_dir, ".config/linear")
    token_file = Path.join(token_dir, "linear_api_key.token")

    try do
      File.mkdir_p!(fake_bin)
      File.mkdir_p!(token_dir)
      File.write!(token_file, "file-token-value\n")

      {output, status} =
        System.cmd(@script_path, [@ack_flag],
          cd: @repo_root,
          env: [
            {"PATH", "#{fake_bin}:/usr/bin:/bin"},
            {"HOME", home_dir}
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
    home_dir = Path.join(test_root, "home")
    token_dir = Path.join(home_dir, ".config/linear")
    token_file = Path.join(token_dir, "linear_api_key.token")

    try do
      File.mkdir_p!(fake_bin)
      File.mkdir_p!(token_dir)
      File.write!(token_file, "file-token-value\n")
      write_fake_command(fake_codex, "exit 0")

      {output, status} =
        System.cmd(@script_path, [@ack_flag],
          cd: @repo_root,
          env: [
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"POWERSYMPHONY_ROOT", test_root},
            {"HOME", home_dir}
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
            {"LINEAR_API_KEY", "explicit-env-token"},
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
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"TRACE_FILE", trace_file},
            {"HOME", test_root}
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
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"TRACE_FILE", trace_file},
            {"HOME", test_root}
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

  test "fails before entering elixir when the default port is already listening" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-formal-start-default-port-conflict-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(test_root, "bin")
    fake_codex = Path.join(fake_bin, "codex")
    fake_mise = Path.join(fake_bin, "mise")
    trace_file = Path.join(test_root, "mise.trace")
    previous_path = System.get_env("PATH")
    home_dir = Path.join(test_root, "home")
    token_dir = Path.join(home_dir, ".config/linear")
    token_file = Path.join(token_dir, "linear_api_key.token")
    listener =
      case :gen_tcp.listen(4000, [:binary, active: false, reuseaddr: true]) do
        {:ok, socket} -> socket
        {:error, :eaddrinuse} -> nil
      end

    try do
      File.mkdir_p!(fake_bin)
      File.mkdir_p!(token_dir)
      File.write!(token_file, "file-token-value\n")
      write_fake_command(fake_codex, "exit 0")
      write_fake_command(fake_mise, ~S(printf 'args=%s\n' "$*" > "$TRACE_FILE"))

      {output, status} =
        System.cmd(@script_path, [@ack_flag],
          cd: @repo_root,
          env: [
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"TRACE_FILE", trace_file},
            {"HOME", home_dir}
          ],
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ "4000"
      assert output =~ "ss -ltnp | grep ':4000 '"
      assert output =~ "lsof -nP -iTCP:4000 -sTCP:LISTEN"
      assert output =~ "停止现有实例"
      assert output =~ "--port"
      refute File.exists?(trace_file)
    after
      if listener, do: :gen_tcp.close(listener)
      File.rm_rf(test_root)
    end
  end

  test "fails before entering elixir when an explicit port is already listening" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-formal-start-explicit-port-conflict-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(test_root, "bin")
    fake_codex = Path.join(fake_bin, "codex")
    fake_mise = Path.join(fake_bin, "mise")
    trace_file = Path.join(test_root, "mise.trace")
    previous_path = System.get_env("PATH")
    home_dir = Path.join(test_root, "home")
    token_dir = Path.join(home_dir, ".config/linear")
    token_file = Path.join(token_dir, "linear_api_key.token")
    {listener, port} = reserve_tcp_port()

    try do
      File.mkdir_p!(fake_bin)
      File.mkdir_p!(token_dir)
      File.write!(token_file, "file-token-value\n")
      write_fake_command(fake_codex, "exit 0")
      write_fake_command(fake_mise, ~S(printf 'args=%s\n' "$*" > "$TRACE_FILE"))

      {output, status} =
        System.cmd(@script_path, [@ack_flag, "--port", Integer.to_string(port)],
          cd: @repo_root,
          env: [
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"TRACE_FILE", trace_file},
            {"HOME", home_dir}
          ],
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ Integer.to_string(port)
      assert output =~ "ss -ltnp | grep ':#{port} '"
      assert output =~ "lsof -nP -iTCP:#{port} -sTCP:LISTEN"
      assert output =~ "停止现有实例"
      assert output =~ "--port"
      refute File.exists?(trace_file)
    after
      :gen_tcp.close(listener)
      File.rm_rf(test_root)
    end
  end

  test "falls back to /proc when ss and lsof are unusable and still blocks startup before elixir" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-formal-start-proc-port-conflict-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(test_root, "bin")
    fake_codex = Path.join(fake_bin, "codex")
    fake_mise = Path.join(fake_bin, "mise")
    fake_ss = Path.join(fake_bin, "ss")
    fake_lsof = Path.join(fake_bin, "lsof")
    trace_file = Path.join(test_root, "mise.trace")
    previous_path = System.get_env("PATH")
    home_dir = Path.join(test_root, "home")
    token_dir = Path.join(home_dir, ".config/linear")
    token_file = Path.join(token_dir, "linear_api_key.token")
    {listener, port} = reserve_tcp_port()

    try do
      File.mkdir_p!(fake_bin)
      File.mkdir_p!(token_dir)
      File.write!(token_file, "file-token-value\n")
      write_fake_command(fake_codex, "exit 0")
      write_fake_command(fake_mise, ~S(printf 'args=%s\n' "$*" > "$TRACE_FILE"))
      write_fake_command(fake_ss, "exit 127")
      write_fake_command(fake_lsof, "exit 127")

      {output, status} =
        System.cmd(@script_path, [@ack_flag, "--port", Integer.to_string(port)],
          cd: @repo_root,
          env: [
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"TRACE_FILE", trace_file},
            {"HOME", home_dir}
          ],
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ Integer.to_string(port)
      assert output =~ "ss -ltnp | grep ':#{port} '"
      assert output =~ "lsof -nP -iTCP:#{port} -sTCP:LISTEN"
      refute File.exists?(trace_file)
    after
      :gen_tcp.close(listener)
      File.rm_rf(test_root)
    end
  end

  test "falls back to lsof when ss exists but fails and still blocks startup before elixir" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-formal-start-lsof-port-conflict-#{System.unique_integer([:positive])}"
      )

    fake_bin = Path.join(test_root, "bin")
    fake_codex = Path.join(fake_bin, "codex")
    fake_mise = Path.join(fake_bin, "mise")
    fake_ss = Path.join(fake_bin, "ss")
    fake_lsof = Path.join(fake_bin, "lsof")
    trace_file = Path.join(test_root, "mise.trace")
    previous_path = System.get_env("PATH")
    home_dir = Path.join(test_root, "home")
    token_dir = Path.join(home_dir, ".config/linear")
    token_file = Path.join(token_dir, "linear_api_key.token")
    port = available_tcp_port()

    try do
      File.mkdir_p!(fake_bin)
      File.mkdir_p!(token_dir)
      File.write!(token_file, "file-token-value\n")
      write_fake_command(fake_codex, "exit 0")
      write_fake_command(fake_mise, ~S(printf 'args=%s\n' "$*" > "$TRACE_FILE"))
      write_fake_command(fake_ss, "exit 2")

      write_fake_command(
        fake_lsof,
        ~s(if [[ "$*" == *"-iTCP:#{port}"* ]] && [[ "$*" == *"-sTCP:LISTEN"* ]]; then
  exit 0
fi
exit 1)
      )

      {output, status} =
        System.cmd(@script_path, [@ack_flag, "--port", Integer.to_string(port)],
          cd: @repo_root,
          env: [
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"TRACE_FILE", trace_file},
            {"HOME", home_dir}
          ],
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ Integer.to_string(port)
      assert output =~ "ss -ltnp | grep ':#{port} '"
      assert output =~ "lsof -nP -iTCP:#{port} -sTCP:LISTEN"
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
    home_dir = Path.join(test_root, "home")
    token_dir = Path.join(home_dir, ".config/linear")
    token_file = Path.join(token_dir, "linear_api_key.token")

    try do
      File.mkdir_p!(fake_bin)
      File.mkdir_p!(token_dir)
      File.write!(token_file, "file-token-value\n")
      write_fake_command(fake_codex, "exit 0")

      {output, status} =
        System.cmd(@script_path, [@ack_flag],
          cd: @repo_root,
          env: [
            {"PATH", "#{fake_bin}:/usr/bin:/bin"},
            {"HOME", home_dir}
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

  defp available_tcp_port do
    {listener, port} = reserve_tcp_port()
    :gen_tcp.close(listener)
    port
  end

  defp reserve_tcp_port do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    {listener, port}
  end
end
