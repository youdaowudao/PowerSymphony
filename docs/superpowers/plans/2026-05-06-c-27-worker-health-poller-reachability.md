# C-27 WorkerHealthPoller Reachability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 control-plane 的 per-project worker 增加轻量 health poll，使 `running` worker 能在无响应时投影为 `unreachable`，恢复后回到 `running`，并记录最近探测元数据。

**Architecture:** 在 `ProjectProcessManager` 内保留生命周期 `status` 作为内部真源，并新增 `health_status` 与时间戳字段做 reachability 覆盖层；对外 summary/status 通过投影把 `running + unreachable` 暴露为 `unreachable`。新增 `WorkerHealthPoller` 周期性请求 worker 的轻量 `GET /api/v1/health`，并把结果回写到 `ProjectProcessManager`。

**Tech Stack:** Elixir, Phoenix Controller/Router, Req, ExUnit

---

### Task 1: 先固定 control-plane health 配置与 worker 轻量端点

**Files:**
- Modify: `elixir/lib/symphony_elixir/config/schema.ex`
- Modify: `elixir/test/support/test_support.exs`
- Modify: `elixir/test/symphony_elixir/core_test.exs`
- Modify: `elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex`
- Modify: `elixir/lib/symphony_elixir_web/router.ex`
- Modify: `elixir/test/symphony_elixir/extensions_test.exs`

- [ ] **Step 1: 先写失败测试，固定 control-plane health config 默认值与校验**

在 `elixir/test/symphony_elixir/core_test.exs` 增加类似断言：

```elixir
assert Config.settings!().control_plane.health_poll_interval_ms == 3_000
assert Config.settings!().control_plane.health_check_timeout_ms == 1_000
```

并补一个非法值用例：

```elixir
write_workflow_file!(Workflow.workflow_file_path(),
  control_plane_health_poll_interval_ms: 0
)

assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
assert message =~ "control_plane.health_poll_interval_ms"
```

- [ ] **Step 2: 扩展 schema 与 test support，允许 `control_plane` 段透传**

目标代码形状：

```elixir
defmodule ControlPlane do
  embedded_schema do
    field(:health_poll_interval_ms, :integer, default: 3_000)
    field(:health_check_timeout_ms, :integer, default: 1_000)
  end
end
```

并在 `test_support.exs` 里把 override 写成：

```yaml
control_plane:
  health_poll_interval_ms: 3000
  health_check_timeout_ms: 1000
```

- [ ] **Step 3: 先写失败测试，固定 worker 轻量 `GET /api/v1/health` 端点**

在 `elixir/test/symphony_elixir/extensions_test.exs` 新增断言：

```elixir
payload = json_response(get(build_conn(), "/api/v1/health"), 200)
assert payload["status"] == "ok"
assert payload["runtime_mode"] == "workflow"
assert is_binary(payload["generated_at"])
```

- [ ] **Step 4: 实现 `GET /api/v1/health`，并保持它完全轻量**

要求：

- 不调用 `Presenter.state_payload/2`
- 不调用 `Orchestrator.snapshot/2`
- 不读取 issue/raw/timeline

目标返回形状：

```elixir
json(conn, %{
  generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
  status: "ok",
  runtime_mode: to_string(SymphonyElixir.runtime_mode())
})
```

- [ ] **Step 5: 重新跑定向测试，确认配置与 health 端点都变绿**

Run:

```bash
cd elixir && mix test \
  test/symphony_elixir/core_test.exs \
  test/symphony_elixir/extensions_test.exs
```

Expected: PASS

### Task 2: 扩展 ProjectProcessManager 运行态，支持 health 元数据与 `unreachable` 投影

**Files:**
- Modify: `elixir/lib/symphony_elixir/project_process_manager.ex`
- Modify: `elixir/test/symphony_elixir/project_process_manager_test.exs`

- [ ] **Step 1: 先写失败测试，固定 health 元数据与投影规则**

至少新增这些测试名：

```elixir
test "project registry projects running lifecycle with unreachable health as unreachable"
test "health updates do not overwrite stopped crashed start_failed disabled or config_invalid states"
test "health metadata persists and reloads from runtime.json"
```

建议关键断言：

```elixir
assert entry.runtime_state.status == :unreachable
assert %DateTime{} = entry.runtime_state.last_health_check_at
assert entry.runtime_state.last_error == "request timed out"
assert entry.runtime_state.health_check_timeout_ms == 50
```

- [ ] **Step 2: 扩展内部 runtime_state 与持久化字段**

目标代码形状：

```elixir
%{
  status: :running,
  health_status: :unknown,
  last_seen_at: nil,
  last_health_check_at: nil,
  last_error: nil,
  health_check_timeout_ms: current_health_check_timeout_ms()
}
```

并同步：

- `@type runtime_state`
- `default_runtime_state/2`
- `persist_runtime/2`
- `normalize_loaded_runtime/1`

- [ ] **Step 3: 新增 manager API，供 poller 获取 target 和回写结果**

至少暴露：

```elixir
@spec health_poll_targets(GenServer.name()) :: [map()]
@spec record_health_success(GenServer.name(), String.t(), DateTime.t()) :: :ok
@spec record_health_failure(GenServer.name(), String.t(), DateTime.t(), String.t()) :: :ok
```

`health_poll_targets/1` 返回最小字段：

```elixir
%{
  project_id: "alpha",
  worker_port: 4101,
  health_check_timeout_ms: 1_000
}
```

- [ ] **Step 4: 实现 `running + unreachable => unreachable` 的对外投影**

要求：

- 内部 `status` 保持生命周期真源
- 只在 registry merge/projection 时把 `health_status == :unreachable` 投成 `status == :unreachable`
- `start / stop / restart` 仍基于内部生命周期状态判断

- [ ] **Step 5: 重新跑 manager 定向测试，确认原有生命周期行为未回归**

Run:

```bash
cd elixir && mix test test/symphony_elixir/project_process_manager_test.exs
```

Expected: PASS

### Task 3: 新增 WorkerHealthPoller，并证明只打轻量接口

**Files:**
- Create: `elixir/lib/symphony_elixir/worker_health_poller.ex`
- Create: `elixir/test/symphony_elixir/worker_health_poller_test.exs`
- Modify: `elixir/test/support/project_process_manager_fake_worker.exs`
- Modify: `elixir/test/symphony_elixir/control_plane_runtime_test.exs`

- [ ] **Step 1: 先写失败测试，固定 poller 的最小 contract**

至少覆盖：

```elixir
test "poller keeps responsive running worker as running and stamps last_seen_at"
test "poller marks a running worker unreachable after timeout"
test "poller returns unreachable worker to running after a later successful response"
test "poller does not cross-write last_seen_at or last_error across projects"
test "poller only calls /api/v1/health"
```

- [ ] **Step 2: 扩展 fake worker，支持 `hang_once` 与 request log**

脚本新能力：

- `--mode hang_once`
- `--request-log /tmp/requests.log`

目标请求日志写法：

```elixir
File.write!(request_log, request_path <> "\n", [:append])
```

`hang_once` 预期行为：

- 第一次 `/api/v1/health` 请求不返回 body，让客户端超时
- 后续请求恢复为正常 `200`

- [ ] **Step 3: 实现 WorkerHealthPoller**

目标代码骨架：

```elixir
def handle_info(:poll, state) do
  schedule_poll(state.interval_ms)

  state.project_process_manager
  |> ProjectProcessManager.health_poll_targets()
  |> Enum.each(&probe_target(&1, state))

  {:noreply, state}
end
```

探测实现要求：

- URL 固定为 `http://127.0.0.1:<port>/api/v1/health`
- `retry: false`
- `receive_timeout == health_check_timeout_ms`
- success 回写 `record_health_success/3`
- failure 回写 `record_health_failure/4`

- [ ] **Step 4: 把 poller 接入 control-plane child tree**

`SymphonyElixir.Application.child_specs(:control_plane)` 目标顺序：

```elixir
[
  Phoenix.PubSub,
  Task.Supervisor,
  SymphonyElixir.ControlPlaneSnapshotServer,
  SymphonyElixir.ProjectProcessManager,
  SymphonyElixir.WorkerHealthPoller,
  SymphonyElixir.HttpServer
]
```

- [ ] **Step 5: 重新跑 poller/runtime 定向测试**

Run:

```bash
cd elixir && mix test \
  test/symphony_elixir/worker_health_poller_test.exs \
  test/symphony_elixir/control_plane_runtime_test.exs
```

Expected: PASS

### Task 4: 做最小文档同步并完成本卡验证

**Files:**
- Modify: `elixir/README.md`

- [ ] **Step 1: 把 README 中“尚未实现 health polling”改成当前真实行为**

需要明确：

- control plane 现在会做轻量 worker health poll
- 默认配置入口在 `WORKFLOW.md > control_plane`
- poll 只调用轻量 `GET /api/v1/health`

- [ ] **Step 2: 先跑本卡全部定向验证**

Run:

```bash
cd elixir && mix test \
  test/symphony_elixir/core_test.exs \
  test/symphony_elixir/extensions_test.exs \
  test/symphony_elixir/project_process_manager_test.exs \
  test/symphony_elixir/worker_health_poller_test.exs \
  test/symphony_elixir/control_plane_runtime_test.exs
```

Expected: PASS

- [ ] **Step 3: 跑最终仓库级门禁，降低本地并发**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- make all
```

Expected: PASS

- [ ] **Step 4: 回写 Linear closeout 所需事实**

必须准备好：

- 实际子 AGENT 数量与角色
- `1+2` 是否一次通过
- 是否发生返工 / 二次维修
- 最终验证命令与结果
