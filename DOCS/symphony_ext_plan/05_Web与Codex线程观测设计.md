# 05. Web 展示与 Codex 线程观测设计

## 1. 核心原则

> 后台记录足够多，前端默认展示足够少，但状态必须足够清楚。

Web 不是日志系统。总览页只回答三个问题：

1. 谁正在做事？
2. 谁可能卡住？
3. 谁需要人介入？

---

## 2. 前端数据分层

### 2.1 总览层

页面：

```text
/projects
```

默认只加载：

```text
ProjectSummary
Counts
Health badges
```

项目详情页或显式展开后才加载 `RunSummary list`。

不加载：

```text
Raw Codex event
完整 timeline
完整 prompt
完整 Linear payload
完整 shell output
完整 tool response
```

### 2.2 详情层

页面：

```text
/projects/:project_id/runs/:run_id
```

默认加载：

- run summary；
- 最近 50 条压缩 timeline；
- 最近错误摘要；
- token/rate limit 摘要；
- workflow hash 与 prompt meta。

### 2.3 事件层

页面或抽屉：

```text
/projects/:project_id/runs/:run_id/events/:event_id
```

点击后才加载：

- event payload 摘要；
- 相关 shell output 摘要；
- 相关 tool call 摘要；
- 原始 JSON 的可展开入口。

### 2.4 Raw 层

页面：

```text
/projects/:project_id/runs/:run_id/raw
```

只给调试使用。默认分页、折叠、脱敏。

---

## 3. 后端数据分层

```text
RawEventStore
  - 原始事件
  - JSONL / payload files
  - 不默认给前端

TimelineStore
  - 压缩事件
  - 人类可读
  - 详情页分页加载

RunStateStore
  - 当前状态摘要
  - 总览页和项目页使用
```

前端总览页只访问 `RunStateStore` 生成的 summary。

---

## 4. Codex 线程状态三元组

每个运行中的 run 必须有：

```text
current_phase
current_action
health
```

### 4.1 current_phase

`current_phase` 是机器可枚举的大阶段。

建议枚举：

```text
queued
claiming_issue
loading_workflow
preparing_workspace
running_after_create_hook
running_before_run_hook
building_prompt
starting_codex_process
starting_codex_thread
starting_codex_turn
codex_reasoning
codex_reading_files
codex_editing_files
codex_running_shell
codex_waiting_shell
codex_waiting_tool
codex_waiting_linear_graphql
codex_waiting_approval_resolution
codex_waiting_user_input_policy
codex_waiting_next_event
turn_completed
checking_tracker_state
continuing_thread
updating_tracker
creating_or_updating_pr
review_handoff
retry_scheduled
retrying
stopping_non_active
cleanup_terminal
completed
failed
stopped
unknown
```

### 4.2 current_action

`current_action` 是给人看的短句，由后端生成。

示例：

```text
正在读取 Linear 事项
正在判断是否符合执行条件
正在准备 workspace
正在运行 after_create hook
正在展开 workflow prompt
正在启动 Codex app-server
正在创建 Codex thread
正在发送第 1 轮 prompt
Codex 正在分析需求
Codex 正在读取文件
Codex 正在修改文件
Codex 正在运行命令
正在等待 shell 命令返回
正在等待 linear_graphql 返回
正在处理 Codex approval / user-input 事件
正在检查 Linear 当前状态
正在准备下一轮 continuation
正在进入 Human Review
正在等待重试
最近一段时间没有新事件
```

### 4.3 health

`health` 是风险判断。

建议枚举：

```text
normal
slow
quiet
possibly_stalled
stalled
retry_scheduled
needs_attention
rate_limited
tool_blocked
workspace_error
workflow_error
codex_error
linear_error
worker_unreachable
unknown
```

---

## 5. quiet / stalled 判断

官方 spec 已有 `codex.stall_timeout_ms`，默认 300000 ms。不要另起一套互相冲突的卡住逻辑。

建议：

```text
stall_timeout_ms = worker workflow 中的 codex.stall_timeout_ms
slow_after_ms = min(60000, stall_timeout_ms * 0.25)
quiet_after_ms = min(180000, stall_timeout_ms * 0.60)
stalled_after_ms = stall_timeout_ms
```

解释：

- `slow`：开始变慢，但仍可能正常。
- `quiet`：明显安静，应提醒观察。
- `possibly_stalled`：接近官方 stall timeout。
- `stalled`：已经达到 worker 的 stall 判定。

不要让 UI 自己计算最终卡住状态。后端 reducer 输出即可。

---

## 6. EventNormalizer

不同来源事件统一成标准格式。

```json
{
  "event_id": "evt_...",
  "run_id": "...",
  "project_id": "...",
  "issue_identifier": "CHAT-12",
  "session_id": "thread-abc-turn-17",
  "thread_id": "thread-abc",
  "turn_id": "turn-17",
  "source": "codex|orchestrator|agent_runner|linear_tool|workspace_hook|control_plane",
  "event_type": "notification",
  "event_group": "codex_activity",
  "timestamp": "2026-05-03T12:00:00Z",
  "summary": "Codex 正在运行测试命令",
  "payload_ref": "payloads/evt_....json",
  "payload_size_bytes": 1234,
  "redacted": true
}
```

`payload_ref` 很关键：前端 summary 不带完整 payload。

---

## 7. StateReducer

StateReducer 根据事件更新 RunState。

### 输入

- normalized event；
- 当前 run state；
- 当前 workflow settings；
- 时间阈值；
- 最近错误。

### 输出

```json
{
  "current_phase": "codex_editing_files",
  "current_action": "Codex 正在修改文件",
  "health": "normal",
  "last_meaningful_event": "file_change_started",
  "last_event_at": "2026-05-03T12:00:00Z",
  "last_error": null
}
```

### 不允许

- 不把 humanized string 作为 orchestrator 决策依据。
- 不让 reducer 触发 retry / kill / cleanup。
- 不因 trace 写入失败影响 Codex 执行。

---

## 8. TimelineSummary

Timeline 不是 raw log，而是压缩事件流。

每条 timeline item：

```json
{
  "id": "tl_...",
  "at": "2026-05-03T12:00:00Z",
  "phase": "codex_running_shell",
  "message": "Codex 正在运行测试命令",
  "severity": "info",
  "event_refs": ["evt_1", "evt_2"],
  "has_payload": true
}
```

同类重复事件要合并：

```text
12:01:00 - 12:02:30 Codex 连续读取文件 18 次
```

而不是展示 18 行。

---

## 9. Web 页面布局

### 9.1 项目总览

```text
[Project] [Worker] [Running] [Quiet] [Stalled] [Retrying] [Needs Attention] [Last Activity] [Last Error]
```

### 9.2 项目详情

```text
[Issue] [Title] [Phase] [Action] [Health] [Thread/Turn] [Last Event] [Duration]
```

### 9.3 Run 详情

顶部 summary：

```text
Issue: CHAT-12
Status: codex_running_shell / slow
Action: 正在运行测试命令
Thread: thread-abc
Turn: turn-17
Last activity: 65 秒前
Duration: 8 分 31 秒
```

下面 timeline：

```text
12:01:03 领取 Linear 事项
12:01:05 准备 workspace
12:01:08 启动 Codex app-server
12:01:14 Codex 正在分析需求
12:01:46 Codex 正在修改文件
12:02:10 Codex 正在运行命令
```

### 9.4 Raw 入口

放在详情页底部或按钮里，不默认展开。

---

## 10. 前端性能硬规则

1. 总览页不调用 timeline API。
2. 总览页不调用 raw API。
3. 总览页不包含 raw event 列表。
4. LiveView 只推 summary diff。
5. Run 详情默认最多 50 条 timeline item。
6. Event payload 点击后才加载。
7. shell output 默认折叠和分页。
8. prompt 默认只显示 meta。
9. payload 超过阈值必须截断或分页。
10. raw event 存储失败不能阻塞 worker 执行。

---

## 11. 后端存储建议

第一版不用数据库。

推荐：

```text
RunStateStore: ETS 或 GenServer state
TimelineStore: ETS + JSONL mirror
RawEventStore: JSONL + payload files
```

写入策略：

- raw event append-only；
- 大 payload 单独文件；
- timeline 可压缩；
- summary 只保留当前状态；
- 文件按 run 目录分开；
- 支持简单 rotate / retention。

---

## 12. 隐私和脱敏

默认脱敏：

- API key；
- Authorization header；
- cookies；
- env；
- token-like strings；
- GitHub/Linear tokens；
- 本机绝对路径可按需隐藏 home 前缀。

Raw 页可以显示更多，但仍不显示 secret。

---

## 13. 验收样例

总览页应该像这样能直接判断：

```text
chatgpt-extension | running | 2 running | 1 quiet | 0 stalled | 1 retrying | 0 needs_attention | 18s ago | -
workbench         | running | 1 running | 0 quiet | 1 stalled | 0 retrying | 1 needs_attention | 9m ago | turn timeout
```

项目详情页应该像这样：

```text
CHAT-12 | codex_editing_files | Codex 正在修改文件 | normal | thread-a / turn-17 | 18s ago
CHAT-13 | codex_waiting_shell | 正在等待测试命令返回 | slow | thread-b / turn-03 | 72s ago
CHAT-14 | codex_waiting_next_event | 最近一段时间没有新事件 | possibly_stalled | thread-c / turn-08 | 4m ago
```

这就是“谁在做事，谁卡住了，一眼看出来”。
