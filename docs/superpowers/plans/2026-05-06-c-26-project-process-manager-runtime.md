# C-26 ProjectProcessManager 与 Worker 生命周期真源 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 control-plane 中引入真实 per-project worker 生命周期真源，让 API 和 Dashboard 能按项目展示并控制独立 worker 的启动、停止、重启与最小运行态。

**Architecture:** 保留 `ProjectRegistryLoader` 作为静态配置入口，在 `:control_plane` child tree 中新增 `ProjectProcessManager` 持有可变运行态，并在每次项目查询时把静态 registry 与动态 runtime 合并。项目动作通过新的 `/api/v1/projects/:project_id/{start|stop|restart}` 路由调用 manager，Presenter 负责把 `config_invalid` 投影成对外状态而不是混进内部状态机。

**Tech Stack:** Elixir, Phoenix Controller/LiveView, ExUnit, Port/System.cmd

---

### Task 1: 扩展静态项目配置并固定对外状态投影边界

**Files:**
- Modify: `elixir/lib/symphony_elixir/project_config.ex`
- Modify: `elixir/lib/symphony_elixir/project_config_store.ex`
- Modify: `elixir/lib/symphony_elixir/project_registry.ex`
- Modify: `elixir/test/symphony_elixir/project_config_store_test.exs`
- Modify: `elixir/test/symphony_elixir/project_registry_test.exs`

- [ ] **Step 1: 先写失败测试，固定 `enabled` / `worker_port` 默认与显式行为**

Run:

```bash
cd elixir && mix test \
  test/symphony_elixir/project_config_store_test.exs \
  test/symphony_elixir/project_registry_test.exs
```

新增断言要覆盖：

```elixir
assert %ProjectConfig{enabled: true, worker_port: 4101} = first
assert %ProjectConfig{enabled: false, worker_port: 4202} = second
```

- [ ] **Step 2: 扩展 `ProjectConfig` struct 与 store 归一化逻辑**

目标代码形状：

```elixir
@enforce_keys [:id, :name, :workflow_generated, :workspace_root, :logs_root, :enabled, :worker_port]
defstruct [:id, :name, :workflow_generated, :workspace_root, :logs_root, :enabled, :worker_port]
```

```elixir
%ProjectConfig{
  id: project_id,
  name: String.trim(project["name"]),
  workflow_generated: canonical_path(project["workflow_generated"]),
  workspace_root: canonical_path(project["workspace_root"]),
  logs_root: canonical_path(project["logs_root"]),
  enabled: normalize_enabled(project["enabled"]),
  worker_port: normalize_worker_port(project["worker_port"], index)
}
```

- [ ] **Step 3: 保持 `config_invalid` 仍为投影语义，不直接写死进 registry 内部状态**

要求：

- `ProjectRegistry.Entry.runtime_state.status` 仍只保存真实 runtime 状态
- `workflow_generated` 文件不存在时，不把 `validation_result` 改成 `invalid`
- 后续由 presenter / manager 投影成 `config_invalid`

- [ ] **Step 4: 重新跑定向测试，确认静态层绿灯**

Run:

```bash
cd elixir && mix test \
  test/symphony_elixir/project_config_store_test.exs \
  test/symphony_elixir/project_registry_test.exs
```

Expected: PASS

### Task 2: 引入 ProjectProcessManager 与测试用 fake worker

**Files:**
- Create: `elixir/lib/symphony_elixir/project_process_manager.ex`
- Create: `elixir/test/symphony_elixir/project_process_manager_test.exs`
- Create: `elixir/test/support/project_process_manager_fake_worker.exs`
- Modify: `elixir/lib/symphony_elixir.ex`
- Modify: `elixir/test/symphony_elixir/control_plane_runtime_test.exs`

- [ ] **Step 1: 先写失败测试，固定 manager 的最小 contract**

至少覆盖这些测试名：

```elixir
test "starts a project worker and records pid, port, stdout/stderr paths"
test "stops one project without affecting another running project"
test "restarts a project worker with a new pid"
test "marks crashed when fake worker exits unexpectedly"
test "marks start_failed when worker command exits during startup"
test "projects with invalid static config or missing workflow file project as config_invalid"
test "reconciles persisted pid after control-plane restart"
```

- [ ] **Step 2: 实现测试专用 fake worker 脚本**

脚本要求：

- `normal`：绑定 `--port` 并返回最小 JSON
- `hang`：绑定 `--port` 但不返回内容
- `crash`：快速异常退出

脚本入口示例：

```bash
elixir test/support/project_process_manager_fake_worker.exs --mode normal --port 4311
```

- [ ] **Step 3: 在 manager 中实现真实状态机与持久化**

必须覆盖：

- start / stop / restart
- `runtime.json` + `worker.pid` + stdout/stderr 路径
- `starting` / `running` / `stopping` / `stopped` / `crashed` / `start_failed`
- 对 `enabled: false` 投影 `disabled`
- 对配置非法或 workflow 缺失投影 `config_invalid`

生产命令构造必须精确到：

```bash
./bin/symphony --logs-root <logs_root> --port <worker_port> <workflow_generated>
```

- [ ] **Step 4: 把 manager 挂入 control-plane child tree**

要求：

- `workflow` mode child tree 不变
- `control_plane` mode child tree 增加 `SymphonyElixir.ProjectProcessManager`
- 现有 `ControlPlaneSnapshotServer` 保留

- [ ] **Step 5: 重新跑 manager 与 runtime 定向测试**

Run:

```bash
cd elixir && mix test \
  test/symphony_elixir/project_process_manager_test.exs \
  test/symphony_elixir/control_plane_runtime_test.exs
```

Expected: PASS

### Task 3: 让控制面 API / Dashboard 动态读取 manager，并接入 start/stop/restart

**Files:**
- Modify: `elixir/lib/symphony_elixir/http_server.ex`
- Modify: `elixir/lib/symphony_elixir_web/presenter.ex`
- Modify: `elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex`
- Modify: `elixir/lib/symphony_elixir_web/router.ex`
- Modify: `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`
- Modify: `elixir/test/symphony_elixir/extensions_test.exs`

- [ ] **Step 1: 先写失败测试，固定控制面动作路由与动态 registry 读取**

至少覆盖：

```elixir
test "projects api reads dynamic runtime state from project process manager"
test "project summary projects config_invalid when workflow file is missing"
test "project control api starts stops and restarts a fake worker"
```

- [ ] **Step 2: 实现动态 project registry 解析**

读取顺序必须是：

1. `Endpoint.config(:project_registry)` 测试注入值
2. `ProjectProcessManager.project_registry/0`
3. `ProjectRegistryLoader.load/0`

- [ ] **Step 3: 扩展 Presenter payload**

目标 JSON 结构：

```elixir
runtime_state: %{
  status: "running",
  pid: 12345,
  worker_port: 4101,
  started_at: "...",
  exit_code: nil,
  exit_reason: nil,
  stdout_path: "/tmp/logs/alpha/control-plane/worker.stdout.log",
  stderr_path: "/tmp/logs/alpha/control-plane/worker.stderr.log",
  error_summary: nil
}
```

- [ ] **Step 4: 新增 `POST /api/v1/projects/:project_id/{start|stop|restart}`**

控制器要求：

- `404`：项目不存在
- `409`：`config_invalid` / `disabled` / 非法当前状态
- `202`：动作已接受，并返回最新项目 summary

- [ ] **Step 5: 重新跑控制面定向测试**

Run:

```bash
cd elixir && mix test test/symphony_elixir/extensions_test.exs
```

Expected: PASS

### Task 4: 同步示例配置与最小文档，并完成最终验证

**Files:**
- Modify: `symphony.projects.example.yaml`
- Modify: `elixir/README.md`

- [ ] **Step 1: 同步示例配置**

要求：

- 为每个项目增加 `enabled: true`
- 为每个项目增加稳定 `worker_port`

- [ ] **Step 2: 只补最小 README 说明**

需要提到：

- control-plane 项目配置新增 `enabled` / `worker_port`
- start/stop/restart 由控制面管理独立 worker
- 当前阶段仍未实现 worker health poll

- [ ] **Step 3: 跑本轮需要的定向验证**

Run:

```bash
cd elixir && mix test \
  test/symphony_elixir/project_config_store_test.exs \
  test/symphony_elixir/project_registry_test.exs \
  test/symphony_elixir/project_process_manager_test.exs \
  test/symphony_elixir/control_plane_runtime_test.exs \
  test/symphony_elixir/extensions_test.exs
```

Expected: PASS

- [ ] **Step 4: 跑启动/执行流最终门禁**

Run:

```bash
cd elixir && make all
```

Expected: PASS

- [ ] **Step 5: 验证原单项目入口没有回归**

至少重新跑已有 CLI 定向测试：

```bash
cd elixir && mix test \
  test/symphony_elixir/cli_test.exs \
  test/symphony_elixir/control_cli_test.exs
```

Expected: PASS
