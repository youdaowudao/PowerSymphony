# C-36 Run Trace Design

## Goal

把 `C-36 / M3-2` 收敛成一条最小可用的线程观测真源链：同一次 worker run 内的关键运行事件，能够经过统一标准化后落到稳定的后端真源存储里，并能为后续 reducer 提供最小读取入口。

本卡只回答两件事：

- 线程运行真相如何统一记录。
- 后续 reducer 从哪里读这份真相。

本卡明确不回答：

- `current_phase / current_action / health` 的最终合同是什么。
- Web / API / Dashboard 应如何展示这些状态。
- timeline 压缩、run detail 页面、raw 浏览页面如何对外暴露。

## Scope Interpretation

### In Scope

- 新增 `RunTrace`，作为单次 worker run 的最小上下文和读取载体。
- 新增 `EventNormalizer` 第一版，统一 `codex / orchestrator / agent_runner / linear_tool / workspace_hook` 的标准字段形状。
- 新增 `RawEventStore`，以 append-only 方式写入标准化事件。
- 为大 payload 提供单独文件落盘与 `payload_ref` 引用，不把完整 payload 直接混入 summary 消费面。
- 为后续 reducer 提供最小事件读取入口，但不提前落地 reducer、自定义状态枚举或最终摘要语义。
- 固定“trace 写入失败不会拖垮 worker / orchestrator correctness”这条边界。

### Out of Scope

- 不新增 `StateReducer` 的最终行为。
- 不新增 `RunStateStore` 的最终状态合同。
- 不新增 `TimelineStore` 压缩与聚合逻辑。
- 不新增新的 HTTP API、LiveView assign、Dashboard 展示字段。
- 不新增 raw event 浏览、run detail 页面或 timeline 页面。
- 不把前端默认接到 raw event 真源上。

## Confirmed Current State

### 1. 现有系统已有分散事件源，但还没有统一真源链

当前仓库里已经存在几类可观测的运行信号：

- `codex`：`SymphonyElixir.Codex.AppServer.emit_message/4` 会把 `session_started`、`turn_completed`、`tool_call_completed`、`approval_required` 等事件发回调用方。
- `agent_runner`：`SymphonyElixir.AgentRunner` 负责 worker attempt、workspace 准备、run result 上报。
- `workspace_hook`：`SymphonyElixir.Workspace` 已有 hook 执行、失败、超时日志。
- `linear_tool`：`SymphonyElixir.Tracker` 暴露 `create_comment/2` 与 `update_issue_state/2`。
- `orchestrator`：`SymphonyElixir.Orchestrator` 负责 dispatch、retry、continuation、异常退出等关键控制流。

但这些信号目前只分散存在于：

- 进程消息；
- 运行态内存结构；
- 应用日志；
- 零散测试 trace；

系统还没有把它们统一到一条“标准化 -> 真源落盘 -> 可读取”的链路里。

### 2. `logs_root` 已存在，是本卡最合适的落盘根

当前 worker 启动路径已经支持外部传入 `--logs-root`：

- `bin/symphony_start` 默认会补 `--logs-root`
- `SymphonyElixir.CLI` 会把它转成 `:log_file`
- `SymphonyElixir.LogFile.default_log_file/1` 会把真实日志文件落到 `<logs_root>/log/symphony.log`

因此本卡不需要再发明一套新的运行时根目录。最小落点可以直接放在：

```text
<logs_root>/runs/<run_id>/
```

### 3. 当前 API / Presenter 仍只消费轻量 summary

`Presenter.state_payload/2` 与 `Presenter.projects_payload/1` 目前只消费 orchestrator snapshot 和 control-plane summary，并未暴露 raw event 列表。

这和 `C-36` 的边界一致：本卡应只建立真源链，不改变当前对外展示层。

## Design Decision

### 1. 用 `RunTrace` 固定一次 worker run 的最小上下文

新增 `SymphonyElixir.RunTrace`，职责只限于：

- 生成 `run_id`
- 固定当前 run 的最小上下文
- 约定 run 目录和 payload 目录
- 为写入和读取提供同一份载体

第一版 `RunTrace` 最少应包含：

```elixir
%RunTrace{
  run_id: "...",
  project_id: nil | "...",
  project_slug: nil | "...",
  issue_id: "...",
  issue_identifier: "...",
  worker_host: nil | "...",
  workspace_path: nil | "...",
  logs_root: "...",
  run_dir: "...",
  trace_file: "...",
  payload_dir: "...",
  started_at: %DateTime{}
}
```

目录结构固定为：

```text
<logs_root>/runs/<run_id>/
  meta.json
  trace.jsonl
  payloads/
```

其中：

- `meta.json` 保存 run 元信息；
- `trace.jsonl` 只保存标准化后的事件；
- `payloads/` 保存需要单独落盘的原始 payload。

### 2. 用 `EventNormalizer` 固定第一版标准字段形状

新增 `SymphonyElixir.EventNormalizer`，把不同来源统一成稳定 shape。

第一版标准字段至少包括：

```json
{
  "event_id": "evt_...",
  "run_id": "...",
  "project_id": "...",
  "project_slug": "...",
  "issue_id": "...",
  "issue_identifier": "...",
  "session_id": "...",
  "thread_id": "...",
  "turn_id": "...",
  "source": "codex|orchestrator|agent_runner|linear_tool|workspace_hook",
  "event_type": "session_started|turn_completed|hook_failed|state_update|retry_scheduled|...",
  "event_group": "codex_activity|lifecycle|hook|tracker|control",
  "timestamp": "2026-05-13T00:00:00Z",
  "summary": "human readable summary",
  "payload_ref": "payloads/evt_....json",
  "payload_size_bytes": 123,
  "redacted": false
}
```

要求：

- shape 必须固定；
- `summary` 可以先求稳，不要求非常智能；
- 后续 reducer 应能直接基于这些字段消费，而不再依赖 source-specific payload 结构。

### 3. 用 `RawEventStore` 固定 append-only 真源

新增 `SymphonyElixir.RawEventStore`，只负责两件事：

- 按顺序把标准化事件追加到 `trace.jsonl`
- 把需要单独落盘的 payload 写入 `payloads/`

第一版写入策略：

- `trace.jsonl` append-only；
- 有 payload 时优先单独文件落盘，再把 `payload_ref` 填回标准化事件；
- 若 payload 文件写失败，允许退化成 `payload_ref: nil`；
- 不做 rotate，不做 timeline 压缩，不做外部索引。

### 4. 用 `RunTrace` 自己承担“最小读取入口”

本卡不新增 HTTP 读取 API。

最小读取入口定义为：

- `RunTrace.read_meta/1`
- `RawEventStore.list_events/1`
- `RawEventStore.stream_events/1`

后续 reducer 只要拿到 `RunTrace`，就能获得：

- 这次 run 的目录位置；
- 按时间顺序读取标准化事件的入口。

这样 `RunTrace` 本身就可以作为“供 reducer 读取的最小事件读取 / 索引载体”。

### 5. 事件接入采用“显式上下文 + best-effort 记录”

本卡不引入新的常驻 collector 进程。

第一版采用：

- `AgentRunner` 在 run 开始时创建 `RunTrace`
- 当前执行路径在需要记录时显式调用 `RunTrace.record(...)` 或在 `RunTrace.with_context(...)` 中执行
- `Tracker` 与 `Workspace` 在存在当前 trace context 时补记 trace；没有 context 时仍按现有行为运行

这样可以做到：

- 最小侵入；
- 不改动现有对外接口太多；
- 不把 trace 写入变成新的调度依赖。

### 6. 第一版各来源的最小接入点

#### `codex`

通过 `AgentRunner` 收到的 `codex_worker_update` 原始消息进入 `EventNormalizer`。

至少覆盖：

- `session_started`
- `turn_completed`
- `turn_failed`
- `turn_cancelled`
- `turn_input_required`
- `approval_required`
- `tool_call_completed`
- `tool_call_failed`
- `notification`

#### `agent_runner`

至少覆盖：

- worker attempt started
- workspace prepared
- before_run starting / finished / failed
- run result reported
- after_run finished

#### `workspace_hook`

至少覆盖：

- hook started
- hook succeeded
- hook failed
- hook timed out

#### `linear_tool`

至少覆盖：

- `Tracker.create_comment/2` 调用成功 / 失败
- `Tracker.update_issue_state/2` 调用成功 / 失败

#### `orchestrator`

至少覆盖：

- dispatch started / accepted
- spawned todo transitioned to `In Progress`
- retry scheduled
- retry converged to blocked claim
- normal worker exit handling

这里不要求第一版覆盖 orchestrator 内每一个状态分支，但必须证明 orchestrator 已能把关键控制流写进同一条 trace 链。

## Failure Isolation

### 1. Trace 失败不影响主流程

这是本卡最硬的边界。

当发生下面任一情况时：

- run 目录创建失败
- meta 写入失败
- event 标准化失败
- trace append 失败
- payload 文件写入失败

处理原则都是：

- 记录 warning；
- 当前事件丢失或部分降级；
- 不影响 worker / orchestrator 的原始执行正确性；
- 不把 trace 层失败升级成 turn failure、workspace failure 或 dispatch failure。

### 2. 不让展示层反向依赖 trace

本卡完成后：

- 现有 `Presenter` / `DashboardLive` 不读取 `trace.jsonl`
- 现有 snapshot / summary 行为不因 trace 新增而改变

也就是说，trace 是后端真源增强，不是当前展示层的运行前置条件。

## Minimal Implementation Surface

### New Modules

- `elixir/lib/symphony_elixir/run_trace.ex`
- `elixir/lib/symphony_elixir/event_normalizer.ex`
- `elixir/lib/symphony_elixir/raw_event_store.ex`

### Existing Modules Touched

- `elixir/lib/symphony_elixir/agent_runner.ex`
- `elixir/lib/symphony_elixir/workspace.ex`
- `elixir/lib/symphony_elixir/tracker.ex`
- `elixir/lib/symphony_elixir/orchestrator.ex`
- `elixir/lib/symphony_elixir.ex`

### Test Surface

- 新增 focused test file，优先命名为：
  - `elixir/test/symphony_elixir/run_trace_test.exs`
- 如确有必要，再补：
  - `elixir/test/symphony_elixir/orchestrator_status_test.exs`

## Validation Strategy

### Targeted Tests First

本卡属于核心执行路径改动，但本地仍先做定向测试，不跑 full gate。

第一轮应至少覆盖：

1. `AgentRunner.run/3` 能创建 trace，并写入 `codex + agent_runner` 事件。
2. `Workspace` hook 在 trace context 下能写入 `workspace_hook` 事件。
3. `Tracker.update_issue_state/2` 或 `create_comment/2` 在 trace context 下能写入 `linear_tool` 事件。
4. `orchestrator` 的关键控制流能把事件写进同一条 trace。
5. `RawEventStore` 写入失败时，`AgentRunner.run/3` 仍保持原本成功语义。

### Process Cleanup

每次本地测试结束后，仍按仓库规则立即检查并清理：

- fake codex / fake ssh
- 端口占用
- 临时目录和 trace 文件

不能把残留带到下一轮测试。

## Exit Criteria

`C-36` 这张卡可以进入实现，当且仅当下面条件同时成立：

1. `RunTrace` 已固定为单次 run 的最小上下文与读取载体。
2. `EventNormalizer` 第一版字段 shape 已固定。
3. `RawEventStore` 已能 append-only 落盘标准化事件。
4. `codex / orchestrator / agent_runner / linear_tool / workspace_hook` 五类来源都已纳入统一采集链。
5. 已存在最小读取入口供后续 reducer 消费。
6. 已证明 trace 写入失败不会拖垮 worker / orchestrator correctness。
7. 本卡没有提前引入状态合同、timeline 合同或新的前端依赖。
