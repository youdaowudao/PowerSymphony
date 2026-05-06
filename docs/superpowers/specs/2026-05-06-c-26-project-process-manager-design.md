# C-26 ProjectProcessManager 与 Worker 生命周期真源设计

## 目标

在现有 `ProjectRegistry`、`symphony_control`、`/api/v1/projects` 与 `DashboardLive` 骨架上，为每个项目补上真实 worker 生命周期真源，使控制面能够按项目启动、停止、重启独立 worker，并对外投影最小运行态。

这次只解决 control-plane 如何管理 per-project worker 进程，不提前实现 M2-2 的 health poll、M2-3 的真实 summary 聚合、M2-4 的 Web 收口。

## 已确认现状

1. `ProjectRegistry` 目前只保存静态配置校验结果，所有 entry 的 `runtime_state.status` 都写死为 `:not_started`。
2. `Presenter.projects_payload/1` 只是把 entry 原样投影给 API 和 LiveView。
3. `DashboardLive` 与 `ObservabilityApiController` 读取的 `project_registry` 默认来自 `Endpoint.config(:project_registry)`，这在 `HttpServer.start_link/1` 时只会装载一次，无法承载真实运行态更新。
4. 当前基线测试 `cd elixir && mix test test/symphony_elixir/extensions_test.exs:929` 已通过，并明确断言 `/api/v1/projects` 返回的两个项目状态都还是 `not_started`。

## 关键约束

- 必须承接现有 `ProjectRegistry / ProjectConfigStore / ProjectRegistryLoader`，不另起平行静态配置层。
- 不修改 `Orchestrator / AgentRunner / Codex AppServer` 主链路语义。
- `./bin/symphony ./WORKFLOW.md` 单项目入口必须继续可用。
- `./bin/symphony_control` control-plane 入口必须继续可用。
- `config_invalid` 作为对外 summary 投影值存在，不与可变 runtime 状态混写。
- 本卡不做 worker HTTP health poll，但允许做 OS pid 级别的最小 reconcile。

## 设计决策

### 1. 静态配置继续由 ProjectConfigStore 负责，但补上两个项目级静态字段

`ProjectConfig` 增加两个字段：

- `enabled :: boolean()`，默认 `true`
- `worker_port :: non_neg_integer()`，默认按配置顺序分配 `4101 + index`

原因：

- `disabled` 是本卡建议运行态之一，没有静态开关就只能硬编码为永远启用。
- worker 启动命令必须稳定带上 `--port <worker_port>`，把端口放回静态配置比在运行态临时发号更可预测。
- 历史设计文档已经把 `enabled` 和 `worker_port` 视作项目级配置的一部分。

同时保留现有约束：

- `workflow_generated`、`workspace_root`、`logs_root` 仍要求绝对路径并做 canonicalize。
- `workflow_generated` 文件不存在时，不把 `validation_result` 改写成 `invalid`，而是在对外 summary 投影为 `config_invalid`。

### 2. 新增 ProjectProcessManager 作为 control-plane 的运行态真源

新增 `SymphonyElixir.ProjectProcessManager`，只在 `:control_plane` child tree 中启动。

职责：

- 保存每个项目的可变 runtime 状态。
- 负责 start / stop / restart。
- 构造并执行真实 worker 启动命令。
- 记录 pid、启动时间、退出码、退出原因、stdout/stderr 路径。
- 在控制面重启后对已有 pid 做最小 reconcile。

公开接口：

- `project_registry/0`
- `start_project(project_id)`
- `stop_project(project_id)`
- `restart_project(project_id)`

`project_registry/0` 不是返回内存里的静态快照，而是：

1. 每次先重新调用 `ProjectRegistryLoader.load/0` 读取最新静态配置。
2. 把 manager 保存的 runtime 状态按 `project_id` merge 回 entry。
3. 对 running / starting / stopping 且带 pid 的项目执行一次轻量 pid reconcile，避免长期盲信旧状态。
4. 返回合并后的 `ProjectRegistry`，供 presenter/API/LiveView 使用。

### 3. runtime_state 只保存可变运行态，config_invalid 单独投影

entry 内部 `runtime_state` 扩展为最小可观测字段：

```elixir
%{
  status: :not_started | :starting | :running | :stopping | :stopped | :crashed | :start_failed | :disabled,
  pid: integer() | nil,
  worker_port: integer() | nil,
  started_at: DateTime.t() | nil,
  exit_code: integer() | nil,
  exit_reason: String.t() | nil,
  stdout_path: String.t() | nil,
  stderr_path: String.t() | nil,
  error_summary: String.t() | nil
}
```

Presenter 对外投影状态时遵循：

1. `validation_result == :invalid` -> `config_invalid`
2. `normalized_config.workflow_generated` 不存在 -> `config_invalid`
3. `enabled == false` -> `disabled`
4. 其他情况直接使用 runtime 状态

这样能满足 issue 对 `config_invalid` 的边界要求，同时不把“配置非法”混进 manager 的可变状态机。

### 4. worker 启动方式采用外部 OS 进程 + Port 监控

生产启动命令固定为：

```bash
./bin/symphony --logs-root <logs_root> --port <worker_port> <workflow_generated>
```

执行策略：

- `ProjectProcessManager` 用 `Port.open/2` 启动 `/bin/sh -lc`，通过 `exec` 把 shell 进程替换成真实 `./bin/symphony`。
- 标准输出和错误输出通过 shell 重定向写入单独文件。
- manager 通过 port `:exit_status` 事件感知 worker 退出。
- `:erlang.port_info(port, :os_pid)` 作为 pid 真源。

这样可以同时满足：

- 真正执行 `./bin/symphony ...`
- 保留退出监听
- 不修改 worker 主链路
- 支持 stdout/stderr 分文件落盘

### 5. 每个项目的 manager 元数据落在各自 logs_root 下

每个项目在 `<logs_root>/control-plane/` 下保存：

- `worker.stdout.log`
- `worker.stderr.log`
- `worker.pid`
- `runtime.json`

原因：

- 与 issue 要求的项目隔离一致。
- control-plane 重启后可直接按项目恢复最小状态。
- 不引入新的全局状态目录。

`runtime.json` 记录最近一次已知状态、pid、端口、stdout/stderr 路径、时间戳与退出摘要。`worker.pid` 只保留当前最近一次 pid，便于最小化 reconcile。

### 6. 启停状态机采用“异步动作 + 明确中间态”

- `start`
  - `config_invalid` / `disabled` 项目直接拒绝启动。
  - 合法项目先进入 `starting`。
  - 成功拿到 pid 且短暂确认进程仍存活后转为 `running`。
  - 若命令立即退出、端口冲突或 shell/脚本失败，则转为 `start_failed` 并写入最小错误摘要。

- `stop`
  - `running` / `starting` 项目先进入 `stopping`。
  - 先发 `TERM`，超时后补 `KILL`。
  - 正常停下后转为 `stopped`。

- `restart`
  - 顺序执行 `stop` 再 `start`。
  - 不引入单独 `restarting` 状态，避免本卡状态机过早膨胀。

- 非预期退出
  - 若 `running` 进程收到 exit status，则转为 `crashed`。
  - 若退出发生在 `starting` 阶段，则转为 `start_failed`。

### 7. control-plane 重启后的最小 reconcile 只看 OS pid，不做 worker HTTP 轮询

重启后的 manager 无法重新接管旧 port 的 `:exit_status` 订阅，因此策略是：

1. 初始化时读取每个项目的 `runtime.json` / `worker.pid`
2. 若记录中有 pid，则执行 `kill -0 <pid>` 级别的轻量检查
3. pid 存活 -> 恢复为 `running`
4. pid 已死 -> 恢复为 `stopped` 或 `crashed`，并清掉脏 pid
5. 在每次 `project_registry/0` 查询时，再对持久化恢复出来的 pid 做一次轻量检查，防止长期显示脏 `running`

这满足“最小 reconcile，不能长期盲信旧状态”，同时不越界实现 M2-2 health poll。

### 8. API 与 Web 只接 manager 的动态 registry，不再依赖启动时静态注入

`HttpServer` 保留现有 endpoint 配置模式，但项目列表读取逻辑改为：

1. 若测试显式注入 `Endpoint.config(:project_registry)`，继续优先使用该静态值。
2. 否则若 `ProjectProcessManager` 存在，则实时调用 `ProjectProcessManager.project_registry/0`。
3. 最后才回退到 `ProjectRegistryLoader.load/0`。

这样可以：

- 保持现有 endpoint 测试注入模式不回归。
- 让 control-plane 页面和 API 拿到真实运行态。
- 不需要修改 Phoenix endpoint 的生命周期模型。

本卡新增控制面 API：

- `POST /api/v1/projects/:project_id/start`
- `POST /api/v1/projects/:project_id/stop`
- `POST /api/v1/projects/:project_id/restart`

返回值统一沿用现有 JSON envelope 风格，返回最新项目 summary。

本卡不做：

- Dashboard 按钮收口
- 项目详情页
- worker 细节代理 API

### 9. fake worker 采用测试专用脚本 + 可注入命令构造器

为避免在测试里真的启动完整 `./bin/symphony`，`ProjectProcessManager` 提供可注入命令构造器。

生产默认构造器：

- 生成真实 `./bin/symphony --logs-root ... --port ... <workflow_generated>` 命令

测试构造器：

- 指向一个 test support fake worker 脚本
- 支持三种模式：
  - `normal`：启动后保持存活，并在端口上返回最小 HTTP 响应
  - `hang`：启动后保持存活但不返回响应
  - `crash`：启动后快速异常退出

这样可以在不污染生产语义的前提下覆盖本卡要求的 fake worker 三类场景。

## 需要修改的主要文件

- `elixir/lib/symphony_elixir/project_config.ex`
- `elixir/lib/symphony_elixir/project_config_store.ex`
- `elixir/lib/symphony_elixir/project_registry.ex`
- `elixir/lib/symphony_elixir.ex`
- `elixir/lib/symphony_elixir/http_server.ex`
- `elixir/lib/symphony_elixir/project_process_manager.ex`（新）
- `elixir/lib/symphony_elixir_web/presenter.ex`
- `elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex`
- `elixir/lib/symphony_elixir_web/router.ex`
- `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`
- `elixir/test/symphony_elixir/project_config_store_test.exs`
- `elixir/test/symphony_elixir/project_registry_test.exs`
- `elixir/test/symphony_elixir/control_plane_runtime_test.exs`
- `elixir/test/symphony_elixir/extensions_test.exs`
- `elixir/test/symphony_elixir/project_process_manager_test.exs`（新）
- `elixir/test/support/project_process_manager_fake_worker.exs`（新）
- `symphony.projects.example.yaml`
- `elixir/README.md`（最小同步）

## 验证策略

最小验证分层：

1. `ProjectConfigStore` 定向测试
   - `enabled` / `worker_port` 默认值和显式值
   - 非法类型与非法端口

2. `ProjectProcessManager` 定向测试
   - start / stop / restart
   - crash -> `crashed`
   - 端口冲突或命令失败 -> `start_failed`
   - workflow 文件缺失或静态配置非法 -> `config_invalid`
   - A/B 双项目并发隔离
   - 重启后 pid reconcile

3. Phoenix 控制面定向测试
   - `/api/v1/projects` / `/summary`
   - `POST /start` / `stop` / `restart`
   - Dashboard 项目表格显示真实 runtime 字段

4. 兼容性验证
   - 现有 `ControlCLI` / `HttpServer` / workflow CLI 定向测试
   - 最终 `cd elixir && make all`

## 风险与控制

- 风险：把 project registry 继续当作 endpoint 启动时静态值，会导致状态永远不刷新。
  - 控制：统一改成 manager 动态读取，测试仍保留静态注入兜底。

- 风险：worker 退出与主动 stop 混淆，导致 `stopped` / `crashed` 错判。
  - 控制：manager 内部显式记录当前动作和预期退出路径。

- 风险：control-plane 重启后把旧 pid 长期当作活进程。
  - 控制：初始化和查询时都执行 `kill -0` 级别 reconcile。

- 风险：把 `config_invalid` 混入 runtime 状态机会让后续 M2-2/M2-3 边界混乱。
  - 控制：始终把它作为 presenter 投影值，而不是 manager 内部状态。

## Follow-up Note

本次 M2-1 已完成仓库级验证政策收口，当前稳定基线为 `coverage >= 99%`，时间敏感测试基线为 `8000ms`。这两项作为当前仓库事实保留，后续问题留待后续工程工作处理，不应继续通过降低门槛解决。

后续工程方向限定为两类：一是 `ProjectProcessManager` 的可测性重构，降低控制面运行态验证对高成本集成路径的依赖；二是时间敏感测试去绝对阈值化，改为更稳健的同步/观察机制，逐步消除对固定毫秒阈值的依赖。
