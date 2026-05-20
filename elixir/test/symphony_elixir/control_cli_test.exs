defmodule SymphonyElixir.ControlCLITest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ControlCLI

  @default_config_path Path.expand("../../../bin/symphony.projects.yaml", __DIR__)

  setup do
    previous_runtime_mode = Application.get_env(:symphony_elixir, :runtime_mode)
    previous_project_config_path = Application.get_env(:symphony_elixir, :project_config_path_override)
    previous_server_port = Application.get_env(:symphony_elixir, :server_port_override)

    on_exit(fn ->
      restore_env(:runtime_mode, previous_runtime_mode)
      restore_env(:project_config_path_override, previous_project_config_path)
      restore_env(:server_port_override, previous_server_port)
    end)

    :ok
  end

  test "defaults to bin/symphony.projects.yaml when config path is missing" do
    deps = %{
      file_regular?: fn path -> path == @default_config_path end,
      set_runtime_mode: fn :control_plane -> :ok end,
      set_project_config_path: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = ControlCLI.evaluate([], deps)
  end

  test "uses an explicit config path override and port when provided" do
    parent = self()
    config_path = "tmp/control/symphony.projects.yaml"
    expanded_path = Path.expand(config_path)

    deps = %{
      file_regular?: fn path ->
        send(parent, {:config_checked, path})
        path == expanded_path
      end,
      set_runtime_mode: fn mode ->
        send(parent, {:runtime_mode, mode})
        :ok
      end,
      set_project_config_path: fn path ->
        send(parent, {:config_set, path})
        :ok
      end,
      set_server_port_override: fn port ->
        send(parent, {:port_set, port})
        :ok
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end
    }

    assert :ok = ControlCLI.evaluate(["--config", config_path, "--port", "4100"], deps)
    assert_received {:config_checked, ^expanded_path}
    assert_received {:runtime_mode, :control_plane}
    assert_received {:config_set, ^expanded_path}
    assert_received {:port_set, 4100}
    assert_received :started
  end

  test "returns not found when config file does not exist" do
    deps = %{
      file_regular?: fn _path -> false end,
      set_runtime_mode: fn _mode -> :ok end,
      set_project_config_path: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, message} = ControlCLI.evaluate(["--config", "missing.yaml"], deps)
    assert message =~ "Project config file not found:"
  end

  test "returns startup error when app cannot start" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_runtime_mode: fn _mode -> :ok end,
      set_project_config_path: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:error, :boom} end
    }

    assert {:error, message} = ControlCLI.evaluate(["--config", "symphony.projects.yaml"], deps)
    assert message =~ "Failed to start Symphony control plane"
    assert message =~ ":boom"
  end

  test "returns usage when arguments are invalid" do
    assert {:error, "Usage: symphony_control [--config <path>] [--port <port>]"} =
             ControlCLI.evaluate(["--unknown"])

    assert {:error, "Usage: symphony_control [--config <path>] [--port <port>]"} =
             ControlCLI.evaluate(["config.yaml", "extra"])
  end

  test "returns usage when port is negative" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_runtime_mode: fn _mode -> :ok end,
      set_project_config_path: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, "Usage: symphony_control [--config <path>] [--port <port>]"} =
             ControlCLI.evaluate(["--port", "-1"], deps)
  end

  test "default runtime deps set application env from evaluate/1" do
    config_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-control-cli-default-deps-#{System.unique_integer([:positive])}.yaml"
      )

    File.write!(config_path, "projects: []\n")

    on_exit(fn -> File.rm_rf(config_path) end)

    assert :ok = ControlCLI.evaluate(["--config", config_path, "--port", "4123"])
    assert Application.get_env(:symphony_elixir, :runtime_mode) == :control_plane
    assert Application.get_env(:symphony_elixir, :project_config_path_override) == config_path
    assert Application.get_env(:symphony_elixir, :server_port_override) == 4123
  end

  test "main_result returns halt code and usage message for invalid arguments" do
    assert {1, "Usage: symphony_control [--config <path>] [--port <port>]"} =
             ControlCLI.main_result(["--unknown"])
  end

  test "main_result returns exit 1 when supervisor is missing after startup" do
    deps = startup_success_deps()

    assert {1, "Symphony supervisor is not running"} =
             ControlCLI.main_result(["--config", "symphony.projects.yaml"], deps, fn -> nil end)
  end

  test "main_result returns exit 0 when supervisor exits normally" do
    deps = startup_success_deps()
    pid = spawn(fn -> Process.sleep(20) end)

    assert {0, nil} =
             ControlCLI.main_result(["--config", "symphony.projects.yaml"], deps, fn -> pid end)
  end

  test "main_result returns exit 1 when supervisor exits abnormally" do
    deps = startup_success_deps()

    pid =
      spawn(fn ->
        Process.sleep(20)
        exit(:boom)
      end)

    assert {1, nil} =
             ControlCLI.main_result(["--config", "symphony.projects.yaml"], deps, fn -> pid end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp startup_success_deps do
    %{
      file_regular?: fn _path -> true end,
      set_runtime_mode: fn _mode -> :ok end,
      set_project_config_path: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }
  end
end

defmodule SymphonyElixir.ControlCLIScriptTest do
  use ExUnit.Case, async: false

  @repo_root Path.expand("../../..", __DIR__)
  @script_path Path.join(@repo_root, "bin/symphony_control")

  test "rewrites relative config paths against the repository root before entering elixir" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-control-cli-script-#{System.unique_integer([:positive])}"
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

      {_, 0} =
        System.cmd(@script_path, ["--config", "./bin/symphony.projects.yaml", "--port", "4001"],
          cd: @repo_root,
          env: [
            {"PATH", "#{fake_bin}:#{previous_path}"},
            {"TRACE_FILE", trace_file}
          ]
        )

      trace = File.read!(trace_file)
      assert trace =~ "cwd=#{Path.join(@repo_root, "elixir")}"
      assert trace =~ "--config #{@repo_root}/./bin/symphony.projects.yaml --port 4001"
      assert trace =~ "SymphonyElixir.ControlCLI.main_result(System.argv())"
      assert trace =~ "System.halt(exit_code)"
    after
      File.rm_rf(test_root)
    end
  end
end
