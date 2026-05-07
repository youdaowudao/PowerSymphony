# C-28 Projects Summary 真实轻量运行态设计

## 目标

在现有 `GET /api/v1/projects` 与 `GET /api/v1/projects/:project_id/summary` 不改路径、不改错误 envelope 的前提下，把当前控制面 summary 从“能看到真实 runtime，但仍暴露重字段”的状态，收口成 M2 所需的真实轻量运行态输出。

本卡只定义 summary shape，不实现 Web 页面、不引入 M3 trace/state reducer，也不暴露 raw/prompt/shell/payload/token/env/Authorization。

## 已确认现状

1. `HttpServer.project_registry/0` 在 control-plane 下已经优先读取 `ProjectProcessManager.project_registry/1`，所以 `/api/v1/projects` 与 `/summary` 已经接到了真实 per-project runtime 真源。
2. `ProjectProcessManager` 已经维护并持久化这些运行态字段：`status`、`worker_port`、`last_seen_at`、`last_health_check_at`、`last_error`、`error_summary`、`health_status` 等。
3. `Presenter.project_entry_payload/1` 目前仍直接暴露 `runtime_state.pid`、`started_at`、`stdout_path`、`stderr_path`、`exit_code`、`exit_reason`、`error_summary` 等更重的内部字段。
4. 现有集成测试已经证明 `/api/v1/projects` 会返回真实动态状态；同时这些测试也明确断言了 `pid/stdout_path/stderr_path` 会出现在 summary 里。
5. `DashboardLive` 当前只消费 `project.runtime_state.status`，并没有依赖 `pid/stdout_path/stderr_path` 之类的重字段。

## 关键约束

- 保留现有 `/api/v1/projects`、`/api/v1/projects/:project_id/summary` 路径。
- 保留现有 `404/405` 等错误 envelope，不新增另一套错误结构。
- 保留兼容字段 `runtime_state.status`，避免现有 dashboard 和调用方硬断。
- `worker_status` 作为新的 UI 首选字段，与兼容层 `runtime_state.status` 同值。
- summary 必须脱敏，不暴露 raw event、prompt body、shell output、完整 Linear payload、token、env、Authorization。
- 不为了预留 M3 提前暴露 `pid/stdout/stderr` 这类执行细节。
- `counts` 不是本卡硬门槛；如不需要，可不输出。

## 设计决策

### 1. 轻量 summary 以顶层字段为主，`runtime_state` 仅保留兼容层

每个 project summary 统一投影为：

```elixir
%{
  project_id: String.t() | nil,
  project_name: String.t() | nil,
  enabled: boolean(),
  validation_result: String.t(),
  validation_errors: [map()],
  worker_status: String.t(),
  worker_port: non_neg_integer() | nil,
  last_seen_at: String.t() | nil,
  last_health_check_at: String.t() | nil,
  last_error: String.t() | nil,
  runtime_state: %{
    status: String.t()
  }
}
```

其中：

- `worker_status` 是新的一等字段，供后续 M2 Web 总览直接消费。
- `runtime_state.status` 作为兼容字段保留，值与 `worker_status` 一致。
- 其余旧的 `runtime_state.*` 字段全部从 summary 移除。

这样可以同时满足：

- 旧调用方继续通过 `runtime_state.status` 读状态；
- 新调用方不必再摸 `runtime_state` 内部结构；
- summary shape 明确轻量、稳定、可脱敏。

### 2. `enabled` 和 `worker_port` 来自静态配置，缺失时采用安全默认

- `enabled` 优先取 `entry.normalized_config.enabled`；取不到时默认 `true`。
- `worker_port` 优先取 `entry.runtime_state.worker_port`，否则回退 `entry.normalized_config.worker_port`。

原因：

- `enabled` 是项目是否允许启动的静态语义，不应从动态 runtime 猜。
- `worker_port` 已由 `ProjectProcessManager` 与静态配置共同约束，summary 只做轻量透出。

### 3. `worker_status` 直接复用已投影好的 runtime status

本卡不重写状态机，也不重新发明一套投影逻辑。状态来源采用以下顺序：

1. 若 `entry.runtime_state.status` 已存在，直接使用其字符串值；
2. 否则按兼容默认回退到 `"not_started"`。

这意味着 `disabled`、`config_invalid`、`start_failed`、`unreachable` 等状态都沿用 `ProjectProcessManager` 当前真源，不在 `Presenter` 里复制第二套复杂判断。

### 4. `last_error` 采用“健康错误优先，生命周期摘要兜底”的轻量策略

`last_error` 计算规则：

1. 优先使用 `runtime_state.last_error`；
2. 若为空，再使用 `runtime_state.error_summary`；
3. 若两者都为空，则返回 `nil`。

理由：

- health poll 的失败原因应该优先展示，因为它代表最新可达性事实；
- `start_failed/crashed` 的简要错误仍需要可见；
- 不直接输出 shell 原始输出，只输出已有的短摘要。

### 5. `config_invalid` 继续通过现有字段表达，不新增另一套错误载荷

本卡不为 `config_invalid` 发明新 envelope。表达方式保持：

- `validation_result` / `validation_errors` 继续保留；
- `worker_status == "config_invalid"`；
- `runtime_state.status == "config_invalid"`；
- `last_error` 在存在 `error_summary` 时可补一条轻量摘要，否则为 `nil`。

这样前端既能用状态位渲染，也能继续从 `validation_errors` 读取清晰原因。

### 6. 控制面动作接口自然跟随新的 summary shape

`POST /api/v1/projects/:project_id/start|stop|restart` 当前复用 `Presenter.project_summary_payload/2`。因此本卡调整 summary shape 后，这三个动作接口的成功返回也会自动变轻量。

这不是额外扩 scope，而是对已有“返回最新项目 summary”语义的兼容演进。

### 7. DashboardLive 只做最小文案同步，不扩页面能力

`DashboardLive` 目前只依赖 `runtime_state.status`。本卡只做两件事：

- 确保 `runtime_state.status` 仍存在；
- 如现有文案仍写着 “placeholder runtime state”，做最小同步，避免公开描述与真实行为明显失配。

不新增 UI 控件，不改布局，不把更多字段接到页面上。

## 需要修改的主要文件

- `elixir/lib/symphony_elixir_web/presenter.ex`
- `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`
- `elixir/test/symphony_elixir/extensions_test.exs`

视测试拆分需要，可能附带修改：

- `elixir/test/symphony_elixir/control_plane_runtime_test.exs`

## 验证策略

1. summary list
   - `/api/v1/projects` 返回多个项目轻量 summary
   - 不含 `pid/stdout_path/stderr_path/started_at/exit_code/exit_reason/error_summary`

2. summary detail
   - `/api/v1/projects/:project_id/summary` 返回单项目轻量 summary
   - invalid `project_id` 继续返回现有 404 envelope

3. 状态覆盖
   - `disabled` 项目正确表达为不可启动
   - `config_invalid` 项目正确表达并保留清晰错误摘要来源
   - `start_failed` / `unreachable` 能映射到 `worker_status` 与 `runtime_state.status`

4. 脱敏
   - summary 不包含 raw event、prompt body、shell output、完整 Linear payload、token、env、Authorization
   - 同时不再暴露 `pid/stdout/stderr` 这类内部运行细节

5. 本地验证
   - 优先跑 `extensions_test.exs` 定向测试
   - 如改动波及 control-plane 集成断言，再补相关定向测试
