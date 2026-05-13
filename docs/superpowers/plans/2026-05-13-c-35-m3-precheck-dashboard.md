# C-35 M3 Precheck Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `M3-1A` 已冻结的 runtime 结果形状，以轻量且稳定的方式暴露到 `m3_precheck` API、project proxy 和 Dashboard，确保控制面只消费 worker 真结果，不再依赖 Dashboard 上的纯文本摘要。

**Architecture:** 保留 `SymphonyElixir.M3Precheck` 的 runtime 计算不动，把收口放在 `Presenter` 与 `DashboardLive`。`Presenter.m3_precheck_payload/1` 统一归一化 atom/string keyed 输入、保留 worker 生成时间、输出最终轻量字段；`ObservabilityApiController.project_m3_precheck_payload/1` 继续只做代理，但在返回前经过 presenter 归一化；Dashboard 直接渲染 `blocked_todos / eligible_todos / capacity_queued_todos / dispatched_todos / anomalies / current_work`，不默认展示 raw `text`。

**Tech Stack:** Elixir, Phoenix LiveView, ExUnit, Req, mise

---

### Task 1: 用回归测试锁定最终 payload 与 Dashboard 展示口径

**Files:**
- Modify: `elixir/test/symphony_elixir/extensions_test.exs`
- Read: `elixir/lib/symphony_elixir_web/presenter.ex`
- Read: `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`

- [ ] **Step 1: 先把 `/api/v1/m3_precheck` 的旧兼容字段从断言里拿掉，并锁定最终轻量字段**

在 [elixir/test/symphony_elixir/extensions_test.exs](/home/ss/data/projects/symphony-workspaces/C-35/elixir/test/symphony_elixir/extensions_test.exs) 的两个 workflow endpoint 用例里，把断言改成只关注最终结果字段，并新增“旧字段不再暴露”的断言：

```elixir
refute Map.has_key?(payload, "eligible")
refute Map.has_key?(payload, "dispatch")
refute Map.has_key?(payload, "blocked")

assert payload["eligible_todos"] == []
assert payload["dispatched_todos"] == []
assert payload["capacity_queued_todos"] == []
assert payload["blocked_todos"] == %{"MT-1" => ["m3 disabled for project"]}
assert payload["current_work"] == %{"count" => 0, "entries" => []}
assert payload["anomalies"] == []
```

- [ ] **Step 2: 锁定 control-plane project proxy 会把 worker body 归一化成同一份最终 payload**

继续在同一个测试文件的 `control-plane project m3 precheck route proxies worker result` 用例里补两类断言：

```elixir
assert payload["generated_at"] == "2026-05-12T00:00:00Z"
refute Map.has_key?(payload, "eligible")
refute Map.has_key?(payload, "dispatch")
refute Map.has_key?(payload, "blocked")

assert payload["eligible_todos"] == [
  %{"issue_identifier" => "MT-CP-1", "issue_id" => "cp-1", "state" => "Todo"}
]
assert payload["blocked_todos"] == %{"MT-CP-2" => ["waiting on non-terminal blockers: MT-CP-9"]}
assert payload["anomalies"] == [
  %{
    "type" => "blocked_but_in_progress",
    "issue_identifier" => "MT-CP-3",
    "issue_id" => "cp-3",
    "state" => "In Progress",
    "blocking_identifiers" => ["MT-CP-10"]
  }
]
```

- [ ] **Step 3: 先写失败的 Dashboard 结构化展示断言**

把 `control-plane dashboard renders m3 precheck result on demand` 改成验证结构化区块，而不是纯文本：

```elixir
rendered = render(view)
assert rendered =~ "运行预检"
assert rendered =~ "依赖阻塞"
assert rendered =~ "容量排队"
assert rendered =~ "本轮已派发"
assert rendered =~ "异常执行态"
assert rendered =~ "当前执行中"
assert rendered =~ "MT-CP-2"
assert rendered =~ "MT-CP-1"
assert rendered =~ "RUN-CP-1"
assert rendered =~ "MT-CP-3"
refute rendered =~ "fake worker m3 precheck"
```

- [ ] **Step 4: 运行定向测试，确认先红在展示/归一化缺口上**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test \
  test/symphony_elixir/extensions_test.exs:1676 \
  test/symphony_elixir/extensions_test.exs:1698 \
  test/symphony_elixir/extensions_test.exs:1742 \
  test/symphony_elixir/extensions_test.exs:1803
```

Expected:

- 失败来自 payload 仍暴露旧字段、project proxy 仍直接透传 worker body、Dashboard 仍只显示 `text`
- 不是端口占用、fake worker 残留或 endpoint 未启动

- [ ] **Step 5: 每轮测试后立即确认 fake worker / 端口已回收**

Run:

```bash
ps -ef | rg "project_process_manager_fake_worker|beam.*symphony_elixir" || true
ss -ltnp | rg "127.0.0.1:" || true
```

Expected:

- 没有本轮测试遗留的 fake worker 持续堆积
- 没有异常新增的监听端口残留到下一轮

### Task 2: 收口 Presenter 和 project proxy 的轻量最终 payload

**Files:**
- Modify: `elixir/lib/symphony_elixir_web/presenter.ex`
- Modify: `elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex`
- Test: `elixir/test/symphony_elixir/extensions_test.exs`

- [ ] **Step 1: 让 presenter 同时接受 atom/string keyed 输入，并只输出最终字段**

在 [elixir/lib/symphony_elixir_web/presenter.ex](/home/ss/data/projects/symphony-workspaces/C-35/elixir/lib/symphony_elixir_web/presenter.ex) 中，把 `m3_precheck_payload/1` 改成通过统一 helper 取值，不再把旧兼容字段放到 API payload 里：

```elixir
%{
  generated_at: m3_generated_at(payload),
  m3_enabled: m3_payload_value(payload, :m3_enabled),
  eligible_todos: m3_issue_entries(payload, :eligible_todos),
  dispatched_todos: m3_issue_entries(payload, :dispatched_todos),
  capacity_queued_todos: m3_issue_entries(payload, :capacity_queued_todos),
  blocked_todos: m3_payload_value(payload, :blocked_todos, %{}),
  current_work: m3_current_work_payload(payload),
  anomalies: m3_anomalies_payload(payload),
  structural_errors: m3_payload_value(payload, :structural_errors, []),
  warnings: m3_payload_value(payload, :warnings, []),
  convergence_points: m3_payload_value(payload, :convergence_points, []),
  text: m3_payload_value(payload, :text, "")
}
```

补齐最小 helper，保证以下兼容路径成立：

```elixir
defp m3_payload_value(payload, key, default \\ nil),
  do: Map.get(payload, key, Map.get(payload, Atom.to_string(key), default))
```

- [ ] **Step 2: `generated_at` 优先保留 worker/runtime 原值，没有时才兜底当前时间**

在 presenter 内新增类似 helper：

```elixir
defp m3_generated_at(payload) do
  case m3_payload_value(payload, :generated_at) do
    value when is_binary(value) and value != "" -> value
    _ -> generated_at()
  end
end
```

这样 control-plane 不会把 worker 生成时间抹掉，本地 `/api/v1/m3_precheck` 仍可继续用当前时间兜底。

- [ ] **Step 3: project proxy 返回前先走 presenter 归一化，但不重算 runtime 逻辑**

在 [elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex](/home/ss/data/projects/symphony-workspaces/C-35/elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex) 中，把 `project_m3_precheck_payload/1` 改成：

```elixir
def project_m3_precheck_payload(project_id) when is_binary(project_id) do
  with {:ok, body} <- project_worker_request(project_id, "/api/v1/m3_precheck") do
    {:ok, Presenter.m3_precheck_payload(body)}
  end
end
```

约束：

- 只做字段归一化
- 不读取 tracker
- 不在 controller 重算 `blocked / eligible / dispatch`

- [ ] **Step 4: 跑 Task 1 的定向测试，确认 payload 已经统一**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test \
  test/symphony_elixir/extensions_test.exs:1676 \
  test/symphony_elixir/extensions_test.exs:1698 \
  test/symphony_elixir/extensions_test.exs:1742
```

Expected:

- PASS
- 两条 API 路由都只暴露最终字段
- project proxy 保留 worker `generated_at`

### Task 3: 把 Dashboard 从 `text` 切到结构化轻量结果面板

**Files:**
- Modify: `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`
- Test: `elixir/test/symphony_elixir/extensions_test.exs`

- [ ] **Step 1: 统一 `run_m3_precheck` 事件结果格式，错误分支也返回 atom keyed map**

在 [elixir/lib/symphony_elixir_web/live/dashboard_live.ex](/home/ss/data/projects/symphony-workspaces/C-35/elixir/lib/symphony_elixir_web/live/dashboard_live.ex) 中，确保两条分支都返回 presenter 形状，错误值也保持一致：

```elixir
case ObservabilityApiController.project_m3_precheck_payload(project_id) do
  {:ok, body} -> body
  _ -> %{text: "m3 precheck request failed"}
end
```

不要再混用 `%{"text" => ...}`。

- [ ] **Step 2: 把控制面项目行下方的预检展示改成结构化分组**

把当前只显示：

```heex
<pre class="code-panel"><%= get_in(@m3_precheck_results, [project.project_id, "text"]) || "" %></pre>
```

替换成轻量分组面板，至少覆盖：

```heex
<div class="session-stack">
  <p class="mono">可放行 <%= length(m3_issue_entries(result, :eligible_todos)) %> · 容量排队 ...</p>
  <section :if={m3_blocked_entries(result) != []}>...</section>
  <section :if={m3_issue_entries(result, :dispatched_todos) != []}>...</section>
  <section :if={m3_issue_entries(result, :capacity_queued_todos) != []}>...</section>
  <section :if={m3_current_work_entries(result) != []}>...</section>
  <section :if={m3_anomalies(result) != []}>...</section>
</div>
```

展示文案至少直接包含这些区块标题：

- `依赖阻塞`
- `可放行 Todo`
- `容量排队`
- `本轮已派发`
- `当前执行中`
- `异常执行态`

约束：

- 不默认渲染 raw `text`
- 不新增 timeline / raw event / prompt / shell output
- 结果为空时保持页面轻量，可显示 `(none)` 或不渲染该区块

- [ ] **Step 3: 新增最小 helper，避免模板里直接处理 atom/string 差异和 map 遍历**

在 `dashboard_live.ex` 里增加只服务视图的私有 helper，例如：

```elixir
defp m3_issue_entries(nil, _key), do: []
defp m3_issue_entries(result, key), do: Map.get(result, key, [])

defp m3_blocked_entries(result) do
  result
  |> Map.get(:blocked_todos, %{})
  |> Enum.sort_by(fn {identifier, _reasons} -> identifier end)
end
```

如果需要渲染 `current_work` / `anomalies`，也用同类 helper，把模板逻辑压平。

- [ ] **Step 4: 运行 Dashboard 定向测试，确认结构化展示通过**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test \
  test/symphony_elixir/extensions_test.exs:1803
```

Expected:

- PASS
- 页面能直接看到 `blocked / capacity queued / dispatched / anomalies / current_work`
- 页面不再依赖 `fake worker m3 precheck` 这类 raw 文本

- [ ] **Step 5: 运行局部格式检查并再次确认测试残留已清理**

Run:

```bash
cd elixir && mise exec -- mix format --check-formatted \
  lib/symphony_elixir_web/presenter.ex \
  lib/symphony_elixir_web/controllers/observability_api_controller.ex \
  lib/symphony_elixir_web/live/dashboard_live.ex \
  test/symphony_elixir/extensions_test.exs
```

然后立即执行：

```bash
ps -ef | rg "project_process_manager_fake_worker|beam.*symphony_elixir" || true
ss -ltnp | rg "127.0.0.1:" || true
```

Expected:

- 格式检查 PASS
- 没有额外 fake worker / 测试端口残留

### Task 4: 分层验证与收尾

**Files:**
- Verify: `elixir/lib/symphony_elixir_web/presenter.ex`
- Verify: `elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex`
- Verify: `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`
- Verify: `elixir/test/symphony_elixir/extensions_test.exs`

- [ ] **Step 1: 跑本卡完整定向验证，不扩大到全量 suite**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test \
  test/symphony_elixir/extensions_test.exs
```

Expected:

- `m3_precheck` 的 workflow endpoint、project proxy、Dashboard on-demand rendering 全绿
- 不需要本地 `make all`

- [ ] **Step 2: 做结果清单式复核**

逐条确认：

```text
- API payload 只暴露 M3-1A 最终字段
- project proxy 继续只做代理 + 归一化
- Dashboard 能直接区分 blocked / eligible / capacity queued / dispatched / anomalies / current work
- 现有 /api/v1/m3_precheck 与 control-plane 入口路径保持不变
- 页面没有默认 raw/timeline 展示
```

- [ ] **Step 3: 如需提交，使用中文提交信息**

```bash
git add \
  docs/superpowers/plans/2026-05-13-c-35-m3-precheck-dashboard.md \
  elixir/lib/symphony_elixir_web/presenter.ex \
  elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex \
  elixir/lib/symphony_elixir_web/live/dashboard_live.ex \
  elixir/test/symphony_elixir/extensions_test.exs
git commit -m "feat(c-35): 收口 m3 结果接口与面板展示"
```
