# C-42 Run 深看页上下文串联设计

## 1. 范围判断

这张卡不是在现有占位文案上补几行静态文案，而是要把 run_trace 中已经存在但尚未串联的上下文线索，聚合成新的只读读取面并接到 `RunLive`。它触及：

- `RunTrace` / `RunStateStore` 的读取能力扩展
- control-plane 代理接口
- `RunLive` 的行为与渲染
- 对应的后端 / LiveView 测试

因此本卡按仓库规则属于 `Large change`。

## 2. 为什么不能只靠现有接口

当前已有三类读取面：

- `project_run_summary_payload/3`
  - 只返回轻量 run summary。
- `run_timeline`
  - 只返回固定 shape 的 timeline item：`timestamp/source/event_group/summary/event_type/event_id/status_markers`。
- `run_event_detail`
  - 只返回单事件 metadata、summary 与 surface preview。

这三类接口都不足以直接回答 C-42 的核心问题：

- timeline item 没有 conversation / continuation / sub-agent 级摘要。
- 单事件 detail 只能看一条事件，不能建立“最近链路”。
- 现有 `Context surfaces` 占位区没有任何真实数据来源。

因此必须补一个“最近窗口上下文聚合”层，但聚合结果仍保持轻量。

## 2.1 generation 边界

context summary 不能只按“当前 trace 最近窗口”聚合。

固定规则：

1. 先命中当前唯一 running entry。
2. 读取该 entry 的当前 `run_trace`。
3. 只保留与该 entry 当前 `run_instance_id` 相同的事件。
4. 再在这个 generation 内取 recent window 并做聚合。

若不先做这层过滤，旧 attempt 的 reasoning / tool / shell / retry 事件会污染当前 run 的 context。

## 3. 新读取面合同

### 3.1 worker 侧入口

新增只读入口：

- `GET /api/v1/runs/:issue_identifier/context`

读取语义固定为：

1. 命中当前唯一 running entry。
2. 读取该 entry 对应的当前 `run_trace`。
3. 仅在该 `run_trace` 的当前 `run_instance_id` generation 最近窗口事件内做轻量聚合。

错误语义沿用现有 run 深看读取面：

- `404 run_not_found`
- `409 duplicate_run`
- `503 context_unavailable`

### 3.2 control-plane 代理入口

新增代理：

- `GET /api/v1/projects/:project_id/runs/:issue_identifier/context`

规则：

- `project_not_found` 独立返回 `404 project_not_found`
- worker 的 `404/409` 保持原语义
- worker transport failure / timeout / manager 不可达统一映射为 `503 context_unavailable`

### 3.3 响应 shape

第一版 context summary 固定返回轻量结构：

```json
{
  "anchor": {
    "session_id": "thread-1-turn-3",
    "thread_id": "thread-1",
    "turn_id": "turn-3",
    "turn_count": 3
  },
  "conversation": {
    "items": [
      {
        "event_id": "evt-11",
        "kind": "reasoning_summary",
        "label": "reasoning",
        "text": "comparing retry paths"
      },
      {
        "event_id": "evt-12",
        "kind": "user_input_request",
        "label": "tool input request",
        "text": "Continue?"
      }
    ],
    "truncated": false
  },
  "continuation": {
    "status": "continuation_required",
    "label": "continuation required",
    "event_id": "evt-13"
  },
  "tools": {
    "items": [
      {
        "event_id": "evt-14",
        "tool": "shell",
        "status": "completed",
        "summary": "git status --short"
      }
    ]
  },
  "shell": {
    "items": [
      {
        "event_id": "evt-14",
        "kind": "command",
        "text": "git status --short"
      }
    ]
  },
  "subagents": {
    "items": [],
    "status": "unavailable"
  }
}
```

要求：

- 所有顶层 key 必须稳定存在。
- `items` 为空时返回 `[]`，不缺 key。
- 每个 item 都必须带 `event_id`，作为回到 timeline / event detail 的只读锚点。
- `subagents.status` 允许是 `ready` / `unavailable` / `none_observed`。
- 第一版不返回 raw 正文、cursor 或独立 surface。
- 每个面板的 `items` 固定按时间倒序，且只保留少量最近项：
  - `conversation.items`: 最多 3 条
  - `tools.items`: 最多 3 条
  - `shell.items`: 最多 3 条
  - `subagents.items`: 最多 3 条
- 这个读取面是 best-effort 的 summary endpoint，不承诺完整链路。

## 4. 字段来源

### 4.1 anchor

直接来自当前 run summary / running entry 已有字段：

- `session_id`
- `thread_id`
- `turn_id`
- `turn_count`

### 4.2 recent interaction signals

第一版不承诺完整 user / assistant 原文，只聚合最近窗口中已有稳定 payload 的交互摘要：

- `item/reasoning/summaryTextDelta`
  - 作为 `reasoning_summary`
- `item/reasoning/textDelta`
  - 作为 `reasoning_text`
- `item/tool/requestUserInput`
  - 提取优先级固定为：
    1. `params.question`
    2. `params.prompt`
    3. `params.questions[*].question`
  - 作为 `user_input_request`

文本处理约束：

- `reasoning_text` 只能做轻量截断摘要，不能演化成正文浏览。
- 若 `questions[*].question` 不存在或不可稳定提取，直接降级为空项，不回退为猜测文本。

若没有稳定来源，则返回空数组。

### 4.3 continuation

从最近窗口内的两类稳定线索提取：

- agent_runner `run_result` 且 `payload.status == "continuation_required"`
- orchestrator `retry_scheduled`
  - 只表达 `retry_scheduled` / `checking_recheck` / 其他 hold 信号
  - 不默认等同于“continuation queued”

优先级固定为：

1. 若存在 `run_result.status == continuation_required`，则 `continuation.status = "continuation_required"`。
2. 否则若存在 `retry_scheduled.delay_type == "checking_recheck"`，则 `continuation.status = "checking_recheck"`。
3. 否则若存在其他 `retry_scheduled`，则 `continuation.status = "retry_scheduled"`。
4. 否则返回 `continuation.status = "none"`、`label = "none observed"`、`event_id = null`。

### 4.4 tools

从最近窗口聚合最近几条 tool 痕迹：

- `tool_call_completed`
- `tool_call_failed`
- `unsupported_tool_call`
- `notification` / `item/tool/call`

优先提取：

- `tool`
- tool 状态
- `StatusDashboard` 已能稳定 humanize 的摘要

### 4.5 shell

从最近窗口聚合 shell-like 痕迹：

- `item/commandExecution/outputDelta`
- `codex/event/exec_command_begin`
- `codex/event/exec_command_end`
- `tool == shell` 的 tool call 事件

只保留最近几条命令/输出摘要，不返回正文。

### 4.6 subagents

第一版只做保守承诺：

- 若 payload / raw event 中已有稳定 sub-agent 线索，则提取最近摘要。
- 若当前 trace 中没有稳定可读线索，则返回：
  - `items: []`
  - `status: "unavailable"` 或 `none_observed`

这里明确不编造、不过度推断，也不为了支持 sub-agent 面板去新增重 trace 合同。
在当前仓库里，如果没有专门且可命名的 sub-agent trace 事件，这个面板默认就是降级态。

## 5. 聚合策略

- 默认只读取当前 generation 的最近窗口，不扫描全量历史。
- 每个面板只保留少量最近摘要项。
- 相邻重复项允许压缩成一条，但第一版只做简单去重，不做复杂聚类。
- 聚合时优先复用 `StatusDashboard.humanize_codex_message/1` 已有的稳定表述，避免 UI 和 summary 口径分裂。

## 6. LiveView 呈现

把 `Context surfaces` 占位卡替换为真实上下文卡片：

- `Thread & Turn`
  - 展示 `thread / turn / session / turn_count`
- `Recent interaction signals`
  - 展示最近 reasoning / requestUserInput 摘要
- `Continuation & Retry`
  - 展示当前 continuation / retry 状态标签
- `Tools & Shell`
  - 展示最近 tool/shell 摘要
- `Sub-agent`
  - 展示最近 sub-agent 摘要，或显式显示 unavailable

交互约束：

- 页面 mount 时与 timeline 一样异步加载。
- context summary 失败时，只影响该卡片，不回退整页 summary / timeline。
- 第一版 item 只承诺回到 timeline / event detail 的只读锚点，不承诺新的深层跳转。
- 不新增默认展开正文。

## 7. 风险与控制

### 风险 1：recent interaction signals 承诺过度

控制：

- 文档与接口都只承诺“最近交互信号摘要”，不承诺完整 user / assistant 原文。

### 风险 2：sub-agent 线索不稳定

控制：

- 第一版允许显式返回 `unavailable` 或 `none_observed`，不为了补齐 UI 去猜测。

### 风险 3：接口再次演化成重数据面

控制：

- response shape 不含 raw 正文、cursor、surface。
- 每个面板只返回轻量摘要项。
- item 数量、排序和锚点能力固定，避免无限扩张。

### 风险 4：与 C-41 / C-51 合同冲突

控制：

- context summary 是新增只读读取面，不修改 timeline / event detail 既有 schema。

### 风险 5：跨 generation 污染

控制：

- context summary 强制按当前 running entry 的 `run_instance_id` 过滤，再聚合 recent window。
