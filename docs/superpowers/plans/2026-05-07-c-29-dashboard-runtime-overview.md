# C-29 Dashboard 多项目运行态总览 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有 `DashboardLive` 首页上收口 control-plane 多项目运行态总览，并提供 `start / stop / restart` 与轻量刷新。

**Architecture:** 继续复用 `Presenter.projects_payload/1` 与 `ProjectProcessManager` 作为数据与动作真源，不新增新的控制协议。control-plane 模式下由 `DashboardLive` 维护一个轻量项目刷新 tick，只重载项目摘要，不加载 raw/timeline/event 数据。

**Tech Stack:** Elixir, Phoenix LiveView, ExUnit

---

### Task 1: 先用集成测试固定 control-plane 总览与交互 contract

**Files:**
- Modify: `elixir/test/symphony_elixir/extensions_test.exs`
- Reference: `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`
- Reference: `elixir/lib/symphony_elixir/project_process_manager.ex`

- [ ] **Step 1: 写首页字段与轻量边界的失败测试**

```elixir
test "control-plane dashboard renders runtime overview columns for multiple projects" do
  start_test_endpoint(
    runtime_mode: :control_plane,
    orchestrator: SymphonyElixir.ControlPlaneSnapshotServer,
    project_registry: %StaticProjectRegistry{
      entries: [
        %{
          project_id: "alpha",
          project_name: "Alpha",
          normalized_config: %{enabled: true, worker_port: 4101},
          validation_result: :valid,
          validation_errors: [],
          runtime_state: %{status: :running, worker_port: 4101, last_seen_at: DateTime.utc_now(), last_error: nil}
        },
        %{
          project_id: "beta",
          project_name: "Beta",
          normalized_config: %{enabled: false, worker_port: 4102},
          validation_result: :invalid,
          validation_errors: [%{field: "workspace_root", message: "workspace_root is required"}],
          runtime_state: %{status: :config_invalid}
        }
      ]
    }
  )

  {:ok, _view, html} = live(build_conn(), "/")

  assert html =~ "Worker status"
  assert html =~ "Worker port"
  assert html =~ "Last seen"
  assert html =~ "Last error"
  assert html =~ "Actions"
  assert html =~ "Alpha"
  assert html =~ "Beta"
  refute html =~ "Running sessions"
  refute html =~ "Retry queue"
  refute html =~ "Rate limits"
end
```

- [ ] **Step 2: 运行定向测试，确认当前页面 contract 还未满足**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/extensions_test.exs --only control_plane`

Expected: FAIL，缺少新列或动作按钮。

- [ ] **Step 3: 写动作与刷新失败测试**

```elixir
test "control-plane dashboard start stop restart buttons refresh only the targeted project row" do
  test_root = temp_root!("dashboard-actions")
  manager_name = Module.concat(__MODULE__, DashboardActionsManager)
  alpha_port = reserve_tcp_port!()
  beta_port = reserve_tcp_port!()

  config_path =
    write_projects_config!(test_root, [
      project_fixture(test_root, "alpha", alpha_port),
      project_fixture(test_root, "beta", beta_port)
    ])

  Application.put_env(:symphony_elixir, :project_config_path_override, config_path)
  Application.put_env(:symphony_elixir, :project_process_manager_name, manager_name)

  start_supervised!(
    {ProjectProcessManager,
     name: manager_name,
     command_builder: fake_worker_builder(%{"alpha" => "normal", "beta" => "hang"})}
  )

  start_test_endpoint(runtime_mode: :control_plane, orchestrator: SymphonyElixir.ControlPlaneSnapshotServer)

  {:ok, view, _html} = live(build_conn(), "/")

  render_click(element(view, "[data-role=project-action][data-project-id=alpha][data-action=start]"))

  assert_eventually(fn ->
    html = render(view)
    html =~ "alpha" and html =~ "running"
  end)

  refute render(view) =~ "beta running"
end
```

- [ ] **Step 4: 运行同一测试文件，确认动作事件当前失败**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/extensions_test.exs`

Expected: FAIL，提示缺少 `handle_event/3`、按钮 selector 不存在，或页面未刷新。

- [ ] **Step 5: 记录失败信号到 Workpad Notes**

Run: 无额外命令；把失败点写入 `C-29` 的 `## Codex Workpad > Notes`。

Expected: Notes 中有明确的 RED 阶段信号。

### Task 2: 实现 `Presenter` 与 `DashboardLive` 的 control-plane 总览和动作闭环

**Files:**
- Modify: `elixir/lib/symphony_elixir_web/presenter.ex`
- Modify: `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`
- Reference: `elixir/lib/symphony_elixir/http_server.ex`

- [ ] **Step 1: 为 `last_error` 回退逻辑写失败测试**

```elixir
test "projects api falls back to validation error text when runtime error is absent" do
  start_test_endpoint(
    runtime_mode: :control_plane,
    orchestrator: SymphonyElixir.ControlPlaneSnapshotServer,
    project_registry: %StaticProjectRegistry{
      entries: [
        %{
          project_id: "beta",
          project_name: "Beta",
          validation_result: :invalid,
          validation_errors: [%{field: "workspace_root", message: "workspace_root is required"}],
          runtime_state: %{status: :config_invalid}
        }
      ]
    }
  )

  payload = json_response(get(build_conn(), "/api/v1/projects"), 200)
  [project] = payload["projects"]

  assert project["last_error"] == "workspace_root: workspace_root is required"
end
```

- [ ] **Step 2: 运行定向测试，确认 `last_error` 目前没有 validation fallback**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/extensions_test.exs`

Expected: FAIL，`last_error` 为 `nil` 或页面未显示对应文本。

- [ ] **Step 3: 最小实现 `Presenter` 的 fallback 和辅助格式化**

```elixir
defp project_last_error(entry, runtime_state) do
  runtime_state_value(runtime_state, :last_error) ||
    runtime_state_value(runtime_state, :error_summary) ||
    validation_error_summary(Map.get(entry, :validation_errors, []))
end

defp validation_error_summary([first | _rest]), do: validation_error_label(first)
defp validation_error_summary([]), do: nil
```

- [ ] **Step 4: 在 `DashboardLive` 新增 control-plane 事件、tick 和表格列**

```elixir
@control_plane_tick_ms 2_000

def handle_event("project_action", %{"project_id" => project_id, "action" => action}, socket) do
  case run_project_action(action, project_id) do
    {:ok, _runtime_state} ->
      {:noreply,
       socket
       |> put_flash(:info, "#{project_id} #{action} queued")
       |> assign(:projects_payload, load_projects_payload())}

    {:error, reason} ->
      {:noreply,
       socket
       |> put_flash(:error, "#{project_id} #{action} failed: #{reason}")
       |> assign(:projects_payload, load_projects_payload())}
  end
end
```

- [ ] **Step 5: control-plane 连接态下补轻量刷新，不订阅 observability pubsub**

Run: 代码实现后执行 `cd elixir && mise exec -- mix test test/symphony_elixir/extensions_test.exs`

Expected: 之前的 LiveView RED 测试转绿，且 control-plane 页面仍不出现 workflow-only 区块。

### Task 3: 回归验证隔离性与现有 API/CLI 行为

**Files:**
- Modify: `elixir/test/symphony_elixir/extensions_test.exs`
- Reference: `elixir/test/symphony_elixir/project_process_manager_test.exs`
- Reference: `elixir/test/symphony_elixir/control_plane_runtime_test.exs`

- [ ] **Step 1: 为 A/B 项目隔离写失败测试**

```elixir
test "dashboard actions do not cross-write sibling project runtime fields" do
  # 复用双项目 manager 场景
  # 断言 alpha 启动后 beta 仍保持 not_started 或自身错误态
end
```

- [ ] **Step 2: 运行定向测试，确认隔离断言覆盖到位**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/extensions_test.exs`

Expected: PASS；若 FAIL，失败应明确落在串写或页面未刷新。

- [ ] **Step 3: 回归项目摘要 API 与 control-plane runtime 测试**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/extensions_test.exs test/symphony_elixir/control_plane_runtime_test.exs test/symphony_elixir/project_process_manager_test.exs`

Expected: PASS

- [ ] **Step 4: 按仓库分层规则跑本卡最轻充分验证**

Run: `cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test test/symphony_elixir/extensions_test.exs test/symphony_elixir/control_plane_runtime_test.exs test/symphony_elixir/project_process_manager_test.exs --cover`

Expected: PASS，且不需要升级到 `make all`。

- [ ] **Step 5: 更新 Linear 与准备 1+2 复核**

Run: 无额外命令；把验证结果、风险、子线程数量与一次/返工情况写回 `C-29`。

Expected: Linear Workpad、评论与状态都反映最新事实。
