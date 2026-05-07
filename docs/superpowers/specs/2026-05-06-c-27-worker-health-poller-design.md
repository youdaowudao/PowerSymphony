# C-27 WorkerHealthPoller 与 Worker 可达性探测设计

## 目标

在 `C-26` 已落地的 `ProjectProcessManager` 生命周期真源之上，补一层独立的 reachability 探测，回答“worker 进程仍存在时，这个 worker 现在是否还能响应控制面探测、最近一次响应是什么时候”。

本卡只补轻量可达性，不重写 `C-26` 的生命周期主判断，不提前做 `C-28` 的完整 summary shape，也不引入 raw/timeline/payload 级接口。

## 已确认现状

1. `ProjectProcessManager` 已经负责 per-project worker 的 `start / stop / restart`、pid 持久化、stdout/stderr 路径、启动失败/异常退出投影，以及 pid 级最小 reconcile。
2. 当前 worker HTTP 面只有 `GET /api/v1/state`、`GET /api/v1/:issue_identifier`、`POST /api/v1/refresh`，没有专用轻量 health 端点。
3. 现有 control-plane `/api/v1/projects` 与 `/api/v1/projects/:project_id/summary` 直接读取 `ProjectProcessManager.project_registry/0` 的投影结果；如果 reachability 要变成 `unreachable`，这里会自然感知。
4. 目前 `ProjectProcessManager` 的单一 `runtime_state.status` 同时承担内部生命周期状态和对外投影状态；如果 health poll 直接把它改成 `:unreachable`，会干扰 `start / stop / restart` 的生命周期语义。
5. control-plane child tree 当前只有 `ControlPlaneSnapshotServer`、`ProjectProcessManager` 和 `HttpServer`，缺少周期性后台探测进程。

## 关键约束

- `crashed / stopped / start_failed / disabled / config_invalid` 不得被 health poll 覆盖成 `running`。
- poller 只处理生命周期主状态仍为 `running` 的项目；其他状态必须跳过。
- 必须记录 `last_seen_at`、`last_health_check_at`、`last_error`，并保留稳定的 timeout 配置入口。
- 必须证明 poller 不会拉 `state`、`issue`、raw、timeline、payload、shell output 等重接口。
- 不新增复杂 retry/backoff；poller 失败后只在下一次周期继续探测。
- 前端不在本卡范围内；如需对外可见状态变化，只通过现有 summary/status 投影自然体现。

## 设计决策

### 1. 生命周期状态与可达性状态分层

保留 `ProjectProcessManager` 内部 `runtime_state.status` 作为生命周期真源，仅新增一组 health 字段：

```elixir
%{
  status: :not_started | :starting | :running | :stopping | :stopped | :crashed | :start_failed,
  health_status: :unknown | :healthy | :unreachable,
  last_seen_at: DateTime.t() | nil,
  last_health_check_at: DateTime.t() | nil,
  last_error: String.t() | nil,
  health_check_timeout_ms: pos_integer() | nil
}
```

对外投影时采用覆盖规则：

1. `validation_result == :invalid` 或 workflow 文件缺失 -> `config_invalid`
2. `enabled == false` -> `disabled`
3. 内部生命周期 `status == :running` 且 `health_status == :unreachable` -> 对外 `status == :unreachable`
4. 其他情况直接返回生命周期 `status`

这样能满足：

- `running -> unreachable -> running` 的对外回转；
- `stop / restart / crash reconcile` 仍基于内部生命周期真源；
- `crashed / stopped / start_failed / disabled / config_invalid` 不会被 health poll 误刷。

### 2. worker 新增专用轻量 health 端点

新增 `GET /api/v1/health`，由 worker 与 control-plane 共用 router/controller，但实现必须保持纯轻量：

- 不调用 `Orchestrator.snapshot/2`
- 不读取 issue/timeline/raw/prompt/shell output
- 只返回最小 JSON，如：

```json
{
  "generated_at": "2026-05-06T15:00:00Z",
  "status": "ok",
  "runtime_mode": "workflow"
}
```

`WorkerHealthPoller` 只请求这个端点，避免误复用 `GET /api/v1/state` 之类的重接口。

### 3. 新增 WorkerHealthPoller 作为 control-plane 子进程

新增 `SymphonyElixir.WorkerHealthPoller`，只在 `:control_plane` child tree 中启动，职责是：

- 按固定周期读取 `ProjectProcessManager.health_poll_targets/0`
- 只探测生命周期内部状态仍为 `:running` 的项目
- 对每个目标执行 `GET http://127.0.0.1:<worker_port>/api/v1/health`
- 成功则回写 success；失败或超时则回写 failure

第一版保持串行探测即可，原因：

- 当前并发项目数量有限
- 本卡不追求批量探测吞吐优化
- 串行实现更容易证明“不拉重接口”和“多项目状态不串线”

### 4. 配置入口走现有 WORKFLOW.md typed config

由于 `bin/symphony_control` 会在 `elixir/` 目录启动，`Config.settings!()` 在 control-plane 下可直接读取 `elixir/WORKFLOW.md`，因此本卡配置不额外引入 app env，而是扩展 workflow config：

```yaml
control_plane:
  health_poll_interval_ms: 3000
  health_check_timeout_ms: 1000
```

默认值选择：

- `health_poll_interval_ms`: `3000`
- `health_check_timeout_ms`: `1000`

理由：

- 与设计文档里的“项目总览 2-5 秒、worker API timeout 500-1000 ms”一致；
- 不会把控制面轮询打得过于频繁；
- 适合本地与 CI 测试通过较小 override 做快速验证。

### 5. success / failure 状态更新规则

#### success

当 `GET /api/v1/health` 在 timeout 内返回 `200`：

- `health_status <- :healthy`
- `last_seen_at <- checked_at`
- `last_health_check_at <- checked_at`
- `last_error <- nil`
- `health_check_timeout_ms <- 当前配置值`

内部生命周期 `status` 不变。

#### failure

当 health 请求超时、连接失败或返回非 `200`：

- `last_health_check_at <- checked_at`
- `last_error <- 归一化错误摘要`
- `health_check_timeout_ms <- 当前配置值`

然后按阈值判断是否进入 `:unreachable`：

- 参考时间优先使用 `last_seen_at`
- 若 `last_seen_at` 为空，则退回 `started_at`
- 若两者都为空，则本次仅记录错误，不立即进入 `:unreachable`
- 当 `checked_at - reference_time >= health_check_timeout_ms` 时，`health_status <- :unreachable`

这样可以避免“刚启动就第一次失败立即 unreachable”的抖动。

### 6. 恢复与持久化

`runtime.json` 需要新增持久化字段：

- `health_status`
- `last_seen_at`
- `last_health_check_at`
- `last_error`
- `health_check_timeout_ms`

重启 control-plane 后：

- 生命周期主状态仍沿用现有 pid reconcile
- health 字段从最近一次持久化结果恢复
- poller 下一轮会继续探测并自然修正 `unreachable -> running`

### 7. “不拉重接口”的证明方式

测试层给 fake worker 增加 request log 能力，记录每次请求 path。

验收时证明：

- request log 只出现 `/api/v1/health`
- 不出现 `/api/v1/state`
- 不出现 `/api/v1/<issue_identifier>`
- 不出现 raw/timeline/detail 路径

这比只看实现代码更稳，因为能覆盖未来不小心改坏调用路径的回归。

## 需要修改的主要文件

- `elixir/lib/symphony_elixir/config/schema.ex`
- `elixir/lib/symphony_elixir/project_process_manager.ex`
- `elixir/lib/symphony_elixir/worker_health_poller.ex`（新）
- `elixir/lib/symphony_elixir.ex`
- `elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex`
- `elixir/lib/symphony_elixir_web/router.ex`
- `elixir/test/support/test_support.exs`
- `elixir/test/support/project_process_manager_fake_worker.exs`
- `elixir/test/symphony_elixir/core_test.exs`
- `elixir/test/symphony_elixir/control_plane_runtime_test.exs`
- `elixir/test/symphony_elixir/project_process_manager_test.exs`
- `elixir/test/symphony_elixir/worker_health_poller_test.exs`（新）
- `elixir/test/symphony_elixir/extensions_test.exs`
- `elixir/README.md`

## 验证策略

1. 配置层
   - `control_plane.health_poll_interval_ms` / `health_check_timeout_ms` 默认值
   - 非法值校验

2. worker 轻量接口
   - `GET /api/v1/health` 可用
   - 不依赖 `Orchestrator.snapshot/2`

3. poller + manager
   - running worker 成功探测时保持 `running`
   - 连续无响应超过 timeout 后投影成 `unreachable`
   - 恢复响应后投影回 `running`
   - `stopped / crashed / start_failed / disabled / config_invalid` 不被误刷
   - 多项目 `last_seen_at`、`last_error` 不串线
   - request log 证明只调用 `/api/v1/health`

4. 集成层
   - control-plane child tree 包含 `WorkerHealthPoller`
   - 现有 `/api/v1/projects` 路径在 `unreachable` 投影下仍可用

5. 最终验证
   - 先跑定向测试
   - 再用低并发执行 `SYMPHONY_TEST_MAX_CASES=2 mise exec -- make all`
