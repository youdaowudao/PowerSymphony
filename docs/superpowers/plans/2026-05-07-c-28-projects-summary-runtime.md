# C-28 Projects Summary 真实轻量运行态 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `/api/v1/projects` 与 `/api/v1/projects/:project_id/summary` 收口为真实但轻量、脱敏、兼容的 project summary 输出。

**Architecture:** 复用 `ProjectProcessManager` 已提供的真实运行态，不改 runtime 真源；只在 `Presenter` 做投影收口，把新的轻量字段提升到顶层，同时保留 `runtime_state.status` 兼容层。用现有 Phoenix 集成测试驱动 shape 收敛，并同步最小 dashboard 文案。

**Tech Stack:** Elixir, Phoenix Controller/LiveView, ExUnit

---

### Task 1: 用失败测试固定新的 summary shape 和脱敏边界

**Files:**
- Modify: `elixir/test/symphony_elixir/extensions_test.exs`

- [ ] **Step 1: 先写 `/api/v1/projects` 轻量 summary 的失败断言**

在现有 `projects api reads dynamic runtime state from project process manager` 测试附近，把期望改成轻量字段，例如：

```elixir
assert [
         %{
           "project_id" => "alpha",
           "project_name" => "Alpha",
           "enabled" => true,
           "validation_result" => "valid",
           "validation_errors" => [],
           "worker_status" => "not_started",
           "worker_port" => ^port,
           "last_seen_at" => nil,
           "last_health_check_at" => nil,
           "last_error" => nil,
           "runtime_state" => %{"status" => "not_started"}
         }
       ] = payload["projects"]
```

- [ ] **Step 2: 跑定向测试，确认它因旧 shape 失败而不是因测试写错失败**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test test/symphony_elixir/extensions_test.exs
```

Expected: FAIL，且失败点是旧 payload 仍包含 `pid/stdout_path/stderr_path/...`

- [ ] **Step 3: 再写 `/summary` 明细、`disabled`、`config_invalid`、`start_failed` 的失败断言**

补这些断言：

```elixir
detail = json_response(get(build_conn(), "/api/v1/projects/alpha/summary"), 200)
assert detail["project"]["worker_status"] == "running"
assert detail["project"]["runtime_state"] == %{"status" => "running"}
refute Map.has_key?(detail["project"]["runtime_state"], "pid")
refute Map.has_key?(detail["project"], "stdout_path")
```

以及：

```elixir
assert detail["project"]["worker_status"] == "config_invalid"
assert detail["project"]["last_error"] in [nil, "worker command exited during startup"]
```

- [ ] **Step 4: 增加脱敏回归断言，明确 summary 不含重字段**

用 `refute Map.has_key?` 或 `refute get_in(...)` 覆盖至少这些字段：

```elixir
refute Map.has_key?(project, "pid")
refute Map.has_key?(project, "stdout_path")
refute Map.has_key?(project, "stderr_path")
refute Map.has_key?(project, "prompt_body")
refute Map.has_key?(project, "shell_output")
```

- [ ] **Step 5: 再跑一次定向测试，确认失败集中在实现缺口**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test test/symphony_elixir/extensions_test.exs
```

Expected: FAIL，但错误只剩 payload shape 不匹配

### Task 2: 在 Presenter 收口轻量字段，并保持 `runtime_state.status` 兼容

**Files:**
- Modify: `elixir/lib/symphony_elixir_web/presenter.ex`

- [ ] **Step 1: 只写最小实现，先让 summary 顶层字段出现**

目标代码形状：

```elixir
defp project_entry_payload(entry) do
  worker_status = project_worker_status(entry)

  %{
    project_id: entry.project_id,
    project_name: entry.project_name,
    enabled: project_enabled(entry),
    validation_result: to_string(entry.validation_result),
    validation_errors: Enum.map(entry.validation_errors, &project_validation_error_payload/1),
    worker_status: worker_status,
    worker_port: project_worker_port(entry),
    last_seen_at: iso8601(runtime_value(entry, :last_seen_at)),
    last_health_check_at: iso8601(runtime_value(entry, :last_health_check_at)),
    last_error: project_last_error(entry),
    runtime_state: %{status: worker_status}
  }
end
```

- [ ] **Step 2: 实现字段辅助函数，保证默认值稳定**

至少补这些 helper：

```elixir
defp project_worker_status(entry), do: entry |> runtime_value(:status, :not_started) |> to_string()
defp project_enabled(entry), do: get_in(entry, [:normalized_config, :enabled]) != false
defp project_worker_port(entry), do: runtime_value(entry, :worker_port) || get_in(entry, [:normalized_config, :worker_port])
defp project_last_error(entry), do: runtime_value(entry, :last_error) || runtime_value(entry, :error_summary)
```

- [ ] **Step 3: 删除 summary 中的旧重字段投影**

`project_runtime_payload/1` 只保留：

```elixir
%{status: runtime_state_status(runtime_state)}
```

兜底分支也只保留：

```elixir
%{status: "not_started"}
```

- [ ] **Step 4: 跑 summary 定向测试，确认新 shape 通过**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test test/symphony_elixir/extensions_test.exs
```

Expected: PASS

- [ ] **Step 5: 小幅重构，消除重复并保持 helper 名称清晰**

如果测试已绿，再做最小整理，例如把 `entry.runtime_state` 读取统一收进 `runtime_value/3`，但不要扩功能。

### Task 3: 同步最小 dashboard 文案，并补足控制面动作回归验证

**Files:**
- Modify: `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`
- Modify: `elixir/test/symphony_elixir/extensions_test.exs`

- [ ] **Step 1: 先写失败断言，固定 dashboard 文案不再称 placeholder**

在现有 dashboard 断言附近加入：

```elixir
refute html =~ "placeholder runtime state"
assert html =~ "lightweight runtime summary"
```

如果项目文案需要中文或现有风格不同，按仓库现有英文页面风格写等价文本即可。

- [ ] **Step 2: 更新 dashboard 文案，但不增加新字段渲染**

目标文案类似：

```elixir
<p class="section-copy">Per-project lightweight runtime summary for the active control plane.</p>
```

- [ ] **Step 3: 补控制面动作接口回归断言，确认成功返回也走轻量 summary**

在 `start/stop/restart` 测试里，把成功断言收口为：

```elixir
assert start_payload["project"]["worker_status"] == "running"
assert start_payload["project"]["runtime_state"]["status"] == "running"
refute Map.has_key?(start_payload["project"]["runtime_state"], "pid")
```

`stop/restart` 同理。

- [ ] **Step 4: 跑定向测试，覆盖 summary + dashboard + control actions**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test test/symphony_elixir/extensions_test.exs
```

Expected: PASS

### Task 4: 完成本地验证并整理交付证据

**Files:**
- Modify: `docs/superpowers/specs/2026-05-07-c-28-projects-summary-runtime-design.md`
- Modify: `docs/superpowers/plans/2026-05-07-c-28-projects-summary-runtime.md`

- [ ] **Step 1: 运行本卡最轻验证集合**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test test/symphony_elixir/extensions_test.exs
```

Expected: PASS

- [ ] **Step 2: 如 summary 改动波及控制面生命周期断言，再补单个相关测试文件**

仅在需要时运行：

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test test/symphony_elixir/project_process_manager_test.exs
```

Expected: PASS

- [ ] **Step 3: 记录验证结果与风险**

把以下事实同步到 Linear workpad/comment：

```text
- 已验证 `/api/v1/projects` 和 `/api/v1/projects/:project_id/summary` 返回轻量 summary
- 已验证 invalid project_id 继续返回原 404 envelope
- 已验证 summary 不再包含 pid/stdout/stderr 等重字段
```

- [ ] **Step 4: 提交前自查 diff 只包含本卡范围**

Run:

```bash
git diff -- elixir/lib/symphony_elixir_web/presenter.ex elixir/lib/symphony_elixir_web/live/dashboard_live.ex elixir/test/symphony_elixir/extensions_test.exs docs/superpowers/specs/2026-05-07-c-28-projects-summary-runtime-design.md docs/superpowers/plans/2026-05-07-c-28-projects-summary-runtime.md
```

Expected: 只看到 summary shape、测试和最小文案/文档更新
