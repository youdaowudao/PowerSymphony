# C-14 Control Plane Entry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 M1 补齐独立 `symphony_control` 入口，让控制面只依赖 `symphony.projects.yaml` 与 `ProjectRegistry` 静态快照即可启动，同时保持原 `./bin/symphony ./WORKFLOW.md` 行为不回归。

**Architecture:** 现有仓库已经具备 `ProjectRegistry`、项目摘要 API 与首页 `Projects` 区块；本票不重做这些能力，而是在应用启动装配、CLI 入口和 HTTP 配置来源上新增 control-plane mode。该 mode 只启动 Phoenix 控制面与静态项目注册表，不启动 `WorkflowStore`、真实 `Orchestrator`、`StatusDashboard`，并让 Web/API 在无 `WORKFLOW.md` 的情况下返回轻量静态项目总览。

**Tech Stack:** Elixir, Phoenix LiveView, ExUnit

---

### Task 1: 固定 control-plane CLI contract

**Files:**
- Create: `elixir/lib/symphony_elixir/control_cli.ex`
- Modify: `elixir/test/symphony_elixir/cli_test.exs`
- Create: `bin/symphony_control`

- [ ] **Step 1: 写失败测试，定义 control-plane CLI 的最小 contract**

```elixir
test "control cli requires a project config path instead of WORKFLOW.md" do
  parent = self()
  config_path = Path.expand("../symphony.projects.example.yaml", __DIR__)

  deps = %{
    file_regular?: fn path ->
      send(parent, {:file_checked, path})
      path == config_path
    end,
    set_project_config_path: fn path ->
      send(parent, {:config_set, path})
      :ok
    end,
    set_server_port_override: fn port ->
      send(parent, {:port_set, port})
      :ok
    end,
    ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
  }

  assert :ok = SymphonyElixir.ControlCLI.evaluate(["--config", config_path, "--port", "4001"], deps)
  assert_received {:file_checked, ^config_path}
  assert_received {:config_set, ^config_path}
  assert_received {:port_set, 4001}
end
```

- [ ] **Step 2: 运行定向测试，确认 `ControlCLI` 未定义而失败**

Run: `cd elixir && mix test test/symphony_elixir/cli_test.exs`
Expected: FAIL，提示 `SymphonyElixir.ControlCLI` 未定义或 `evaluate/2` 不存在。

- [ ] **Step 3: 实现最小 control-plane CLI，并提供仓库级启动脚本**

```elixir
defmodule SymphonyElixir.ControlCLI do
  @moduledoc """
  Entrypoint for the M1 static control plane.
  """

  @switches [config: :string, port: :integer]

  @type deps :: %{
          file_regular?: (String.t() -> boolean()),
          set_project_config_path: (String.t() -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() | nil -> :ok | {:error, term()}),
          ensure_all_started: (-> {:ok, [atom()]} | {:error, term()})
        }

  @spec evaluate([String.t()], deps()) :: :ok | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        with {:ok, config_path} <- fetch_config_path(opts),
             :ok <- set_config_path(config_path, deps),
             :ok <- maybe_set_port(opts, deps) do
          deps.ensure_all_started.()
          :ok
        end

      _ ->
        {:error, "Usage: symphony_control --config <path> [--port <port>]"}
    end
  end
end
```

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../elixir"
exec mise exec -- mix run --no-halt -e 'SymphonyElixir.ControlCLI.main(System.argv())' -- "$@"
```

- [ ] **Step 4: 运行 CLI 测试，确认新入口参数正确**

Run: `cd elixir && mix test test/symphony_elixir/cli_test.exs`
Expected: PASS

- [ ] **Step 5: 验证脚本层不影响原单项目 escript**

Run: `cd elixir && mix build`
Expected: PASS，且 `elixir/bin/symphony` 仍按既有配置生成。

### Task 2: 为应用启动增加 control-plane mode

**Files:**
- Modify: `elixir/lib/symphony_elixir.ex`
- Modify: `elixir/lib/symphony_elixir/http_server.ex`
- Modify: `elixir/test/symphony_elixir/extensions_test.exs`

- [ ] **Step 1: 写失败测试，固定 control-plane mode 不启动真实 runtime 依赖**

```elixir
test "http server starts in control plane mode without workflow config" do
  config_root =
    Path.join(System.tmp_dir!(), "control-plane-mode-#{System.unique_integer([:positive])}")

  File.mkdir_p!(config_root)
  config_path = Path.join(config_root, "symphony.projects.yaml")

  File.write!(config_path, """
  projects:
    - id: alpha
      name: Alpha
      workflow_generated: /tmp/alpha/WORKFLOW.generated.md
      workspace_root: /tmp/workspaces/alpha
      logs_root: /tmp/logs/alpha
  """)

  Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
  Application.put_env(:symphony_elixir, :runtime_mode, :control_plane)

  assert {:ok, _pid} = start_supervised({HttpServer, host: "127.0.0.1", port: 0})
end
```

- [ ] **Step 2: 运行集成测试，确认当前会因为 `Config.settings!()` / `WORKFLOW.md` 缺失而失败**

Run: `cd elixir && mix test test/symphony_elixir/extensions_test.exs`
Expected: FAIL，报 `WORKFLOW.md` 缺失或 `Config.settings!()` 相关错误。

- [ ] **Step 3: 在应用启动总装配与 `HttpServer` 中分出 control-plane mode**

```elixir
def start(_type, _args) do
  :ok = SymphonyElixir.LogFile.configure()

  children =
    case Application.get_env(:symphony_elixir, :runtime_mode, :worker) do
      :control_plane ->
        [
          {Phoenix.PubSub, name: SymphonyElixir.PubSub},
          {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
          SymphonyElixir.HttpServer
        ]

      _ ->
        [
          {Phoenix.PubSub, name: SymphonyElixir.PubSub},
          {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
          SymphonyElixir.WorkflowStore,
          SymphonyElixir.Orchestrator,
          SymphonyElixir.HttpServer,
          SymphonyElixir.StatusDashboard
        ]
    end

  Supervisor.start_link(children, strategy: :one_for_one, name: SymphonyElixir.Supervisor)
end
```

```elixir
host =
  Keyword.get_lazy(opts, :host, fn ->
    case Application.get_env(:symphony_elixir, :runtime_mode, :worker) do
      :control_plane -> "127.0.0.1"
      _ -> Config.settings!().server.host
    end
  end)
```

- [ ] **Step 4: 回归 `extensions_test.exs`，确认 control-plane mode 可启动**

Run: `cd elixir && mix test test/symphony_elixir/extensions_test.exs`
Expected: PASS

- [ ] **Step 5: 补充应用模式切换清理，避免污染其他测试**

Run: `cd elixir && mix test test/symphony_elixir/extensions_test.exs --seed 0`
Expected: PASS，且无跨测试环境泄漏。

### Task 3: 让 Web/API 在 control-plane mode 下退化为静态项目总览

**Files:**
- Modify: `elixir/lib/symphony_elixir_web/presenter.ex`
- Modify: `elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex`
- Modify: `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`
- Modify: `elixir/test/symphony_elixir/extensions_test.exs`

- [ ] **Step 1: 写失败测试，固定首页在 control-plane mode 下以项目总览为主**

```elixir
test "dashboard renders static project registry without runtime unavailable error in control plane mode" do
  start_test_endpoint(
    runtime_mode: :control_plane,
    project_registry: %{
      entries: [
        %{
          project_id: "alpha",
          project_name: "Alpha",
          validation_result: :valid,
          validation_errors: [],
          runtime_state: %{status: :not_started}
        }
      ]
    }
  )

  {:ok, _view, html} = live(build_conn(), "/")
  assert html =~ "Projects"
  assert html =~ "Alpha"
  assert html =~ "not_started"
  refute html =~ "Snapshot unavailable"
  refute html =~ "Running sessions"
end
```

- [ ] **Step 2: 运行集成测试，确认现有页面仍把 runtime 错误当主视图而失败**

Run: `cd elixir && mix test test/symphony_elixir/extensions_test.exs`
Expected: FAIL，页面仍出现 `Snapshot unavailable` 或仍依赖 runtime sections。

- [ ] **Step 3: 让 Presenter / Controller / LiveView 明确支持 control-plane mode**

```elixir
@spec state_payload(GenServer.name(), timeout(), keyword()) :: map()
def state_payload(orchestrator, snapshot_timeout_ms, opts \\ []) do
  if Keyword.get(opts, :control_plane?, false) do
    %{
      generated_at: generated_at(),
      counts: %{running: 0, retrying: 0},
      running: [],
      retrying: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }
  else
    ...
  end
end
```

```elixir
<%= if control_plane_mode?() do %>
  <section class="section-card">
    ...
  </section>
<% else %>
  ...
<% end %>
```

- [ ] **Step 4: 运行 Web/API 集成测试，确认 control-plane mode 稳定返回轻量项目总览**

Run: `cd elixir && mix test test/symphony_elixir/extensions_test.exs`
Expected: PASS

- [ ] **Step 5: 补 API 边界断言，确保不暴露真实运行态入口**

```elixir
projects_response = Req.get!("http://127.0.0.1:#{port}/api/v1/projects")
assert projects_response.status == 200

refresh_response =
  Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
    headers: [{"content-type", "application/x-www-form-urlencoded"}],
    body: ""
  )

assert refresh_response.status in [202, 405, 503]
```

Run: `cd elixir && mix test test/symphony_elixir/extensions_test.exs`
Expected: PASS，且 `/api/v1/projects` 是本票主验证出口。

### Task 4: 更新说明并做兼容性验证

**Files:**
- Modify: `elixir/README.md`
- Test: `elixir/test/symphony_elixir/cli_test.exs`
- Test: `elixir/test/symphony_elixir/extensions_test.exs`

- [ ] **Step 1: 写文档更新，补控制面启动方式**

```md
## Control plane

Use the lightweight M1 control plane to inspect static project registry snapshots:

```bash
./bin/symphony_control --config ../symphony.projects.example.yaml --port 4001
```

This entrypoint only loads `symphony.projects.yaml` and `ProjectRegistry` static snapshots. It does
not start worker lifecycle management, raw event ingestion, timeline APIs, or worker summary polling.
```

- [ ] **Step 2: 运行 targeted validation**

Run: `cd elixir && mix test test/symphony_elixir/cli_test.exs test/symphony_elixir/extensions_test.exs test/symphony_elixir/project_registry_test.exs`
Expected: PASS

- [ ] **Step 3: 运行规格检查**

Run: `cd elixir && mix specs.check`
Expected: PASS

- [ ] **Step 4: 若最终落点涉及启动路径，执行 full validation**

Run: `make -C elixir all`
Expected: PASS

- [ ] **Step 5: 记录兼容性结论**

```text
- `./bin/symphony_control --config ... --port 4001` 可在无 `WORKFLOW.md` 的 control-plane mode 下启动。
- `/api/v1/projects` 与首页项目表格只展示静态 `ProjectRegistry` 快照。
- 原 `./bin/symphony ./WORKFLOW.md` CLI tests 未回归。
```
