# C-41 Event Detail 与事件级重数据懒加载

## 目标

为 run 深看页补齐单事件 detail 与事件级重数据懒加载，让人类在 timeline 中点开一条事件后，先读懂这条事件是什么，再按需查看该事件关联的 payload、raw、prompt-like、shell-like 片段，而不是退回全局 raw 浏览。

## 需求快照

### 要解决什么问题

- 当前 run 深看页只有 timeline 浏览和 `Open detail placeholder`，没有真实的单事件 detail 面板。
- 当前 trace 存储已经具备 `payload_ref` / `raw_payload` 落盘能力，但没有事件级 detail 与单 surface 读取合同。
- 用户需要在“只看当前事件”的范围内继续深挖，而不是被迫打开全局 raw 或跨事件上下文。

### 成功标准

- 点击单个 timeline item 后，页面能异步加载该事件的 detail 元数据与摘要。
- detail 默认只返回轻量字段与摘要，不默认返回重数据正文。
- `raw`、`payload`、`prompt`、`shell` 只在用户显式请求时才懒加载。
- 重数据读取有第一版大小约束和基础脱敏，不扩成无边界原文浏览。
- detail 或单 surface 失败时，只影响 detail 面板，不影响 summary 与 timeline 浏览。

### 明确不做什么

- 不新增 `run_id` 路由键，不改现有 `project_id + issue_identifier` 深看入口。
- 不做跨事件 thread / turn / conversation / sub-agent 串联。
- 不做全局 raw 浏览层。
- 不做依赖关系、attention 总面板或深看页全局产品收口。
- 不重做 timeline 基础合同，也不把重数据塞回首页或项目详情页。

### 固定约束

- 当前 run 的解析语义继续沿用 `C-51`：`issue_identifier -> 当前唯一 running entry -> run_trace`。
- 当前 deep-view 入口继续沿用 `C-39/C-51` 已冻结的 `/projects/:project_id/runs/:issue_identifier` 与 worker `/api/v1/runs/:issue_identifier/...` 语义。
- 这里的 `issue_identifier` 是当前 deep-view 链路的既有身份键，不是 `run_id` 的替代物；本卡不修改其他 `run_id` 语义，也不新增对外 `run_id` 路由。
- 事件 detail 查找范围固定为：**当前 run_trace 内的单个 `event_id`**。不得扫描历史 run 目录，不得跨 issue_identifier 查找。
- detail 与 surface 读取失败时，必须是独立错误态；summary 与 timeline 不能回退成 `run missing`。
- 第一版 `prompt` surface 不重建 outbound `turn/start` prompt；只消费当前事件 payload 中已经存在的 prompt-like 字段。

## 实现合同

### 1. 事件查找合同

- worker 侧新增“单事件 detail”读取入口，查找顺序固定为：
  1. 按 `issue_identifier` 命中当前唯一 running entry。
  2. 读取该 entry 上的当前 `run_trace`。
  3. 仅在该 `run_trace` 的事件流中按 `event_id` 精确命中单条事件。
- 若 running entry 不存在或缺少 `run_trace`，返回 `404 run_not_found`。
- 若同一 `issue_identifier` 命中多条 running entry，返回 `409 duplicate_run`。
- 若当前 `run_trace` 存在但找不到该 `event_id`，返回 `404 event_not_found`。
- 若 trace 文件或 payload 文件读取/解码失败，返回 `503 event_detail_unavailable` 或 `503 event_surface_unavailable`。

### 2. Detail 响应 schema

`detail` 响应固定为：

```json
{
  "event": {
    "event_id": "evt-123",
    "timestamp": "2026-05-17T01:02:03Z",
    "source": "codex",
    "event_type": "item_commandExecution_outputDelta",
    "event_group": "codex_activity",
    "summary": "command output streaming"
  },
  "run": {
    "issue_identifier": "C-41",
    "run_id": "run-123"
  },
  "context": {
    "session_id": "thread-1-turn-3",
    "thread_id": "thread-1",
    "turn_id": "turn-3"
  },
  "summaries": {
    "tool_call": "shell",
    "payload": "JSON object with 3 top-level keys",
    "prompt": "question: Continue?",
    "shell": "git status --short"
  },
  "surfaces": {
    "raw": { "available": true, "byte_size": 2048, "preview": "{\"method\":\"...\"}", "truncated": true },
    "payload": { "available": true, "byte_size": 1024, "preview": "{\"params\":{\"tool\":\"shell\"}}", "truncated": true },
    "prompt": { "available": false, "byte_size": 0, "preview": null, "truncated": false },
    "shell": { "available": true, "byte_size": 64, "preview": "git status --short", "truncated": false }
  }
}
```

字段约束：

- `event.*` 必填；缺值时返回 `null`，但 key 不缺失。
- `run.issue_identifier` 必填；`run.run_id` 允许只作为 detail 内部元数据返回，不提升为外部路由键。
- `context.*` 允许为 `null`。
- `summaries.*` 允许为 `null`。
- `surfaces.<name>.available` 必填布尔值。
- `surfaces.<name>.byte_size` 必填非负整数，无内容时返回 `0`。
- `surfaces.<name>.preview` 在不可用时返回 `null`。
- `surfaces.<name>.truncated` 必填布尔值。

### 3. Surface 映射合同

四类 surface 只允许按下列已知来源构建，不得泛化成任意原文浏览：

- `payload`
  - 来源：`payload_ref` 指向的 payload 文件中的 `payload` 根对象；若 payload 文件本身就是 map，则直接使用该 map。
- `raw`
  - 来源：`payload_ref` 指向的 payload 文件中的 `raw_payload`；若不存在则视为 unavailable。
- `prompt`
  - 来源仅限当前事件 payload 中已存在的 prompt-like 字段：
    - `params.prompt`
    - `params.question`
    - `params.input[*].text`
    - `params.summaryText`
  - 不尝试回放 `turn/start` 的 outbound prompt，不跨事件拼接 reasoning 或 plan。
- `shell`
  - 来源仅限当前事件 payload 中已存在的 shell-like 字段：
    - `params.parsedCmd`
    - `params.command`
    - `params.outputDelta`
    - `params.tool == "shell"` 时的 tool 名与相关参数
  - 只展示当前事件可见的命令或输出片段，不拼接整段 shell 会话。

若某个 surface 按以上规则取不到内容，必须返回 `available: false`，而不是回退到别的 surface 或扫描其他事件。

### 4. 截断与脱敏合同

第一版统一只做**截断，不做分页**；pagination 延后到后续卡。

- detail preview 固定上限：`512` bytes。
- surface lazy-load 正文固定上限：`4096` bytes。
- 返回 shape 固定为：

```json
{
  "surface": "payload",
  "available": true,
  "content": "{\"params\":{\"tool\":\"shell\"}}",
  "byte_size": 1024,
  "truncated": false
}
```

- 若原内容超过上限：
  - `content` 只返回前 `N` bytes 的 UTF-8 安全截断结果。
  - `truncated` 返回 `true`。
- 处理顺序固定为：
  1. 先按 surface 映射抽取候选内容。
  2. 若候选内容是结构化 map / JSON，先做结构化脱敏，再序列化为字符串。
  3. 若候选内容是纯文本，先做文本模式脱敏。
  4. 脱敏后的字符串再做 UTF-8 安全截断。
  5. `byte_size` 记录的是**脱敏后、截断前**内容大小。
- `detail.surfaces.*.preview` 与单 surface endpoint 的 `content` 使用同一套脱敏与截断顺序：
  - preview 上限 `512` bytes；
  - endpoint content 上限 `4096` bytes。
- `detail` 与单 surface 成功响应字段名固定分离：
  - detail 里只返回 `preview`；
  - 单 surface endpoint 里只返回 `content`；
  - 两者都返回 `available`、`byte_size`、`truncated`。
- 基础脱敏规则固定为：
  - 对 map / JSON 结构，key 命中以下集合时，value 统一替换为 `"[REDACTED]"`：
    - `authorization`
    - `api_key`
    - `apikey`
    - `token`
    - `access_token`
    - `refresh_token`
    - `password`
    - `secret`
    - `cookie`
    - `set-cookie`
  - 对纯文本内容，至少替换以下模式：
    - `Bearer <non-space>`
    - `authorization: <value>`
    - `api_key=<value>` / `token=<value>` / `password=<value>`
- 第一版不做深层语义脱敏，不做 allowlist 外推断。

### 5. API 与错误语义

worker 新增接口：

- `GET /api/v1/runs/:issue_identifier/events/:event_id`
- `GET /api/v1/runs/:issue_identifier/events/:event_id/:surface`

control-plane 新增代理接口：

- `GET /api/v1/projects/:project_id/runs/:issue_identifier/events/:event_id`
- `GET /api/v1/projects/:project_id/runs/:issue_identifier/events/:event_id/:surface`

错误码固定为：

- `400 invalid_surface`
- `404 run_not_found`
- `404 event_not_found`
- `404 surface_not_available`
- `409 duplicate_run`
- `503 event_detail_unavailable`
- `503 event_surface_unavailable`

`/:surface` 允许值固定为：`raw`、`payload`、`prompt`、`shell`。

- 若 `surface` 不在允许值集合内，返回 `400 invalid_surface`。
- 若 `surface` 合法但当前事件按映射规则无法提供内容，返回 `404 surface_not_available`。

control-plane 代理规则：

- `project_not_found` 继续独立返回 `404 project_not_found`。
- worker 的 `400/404/409` 必须原样保留语义，不得吞并成泛化 `503`。
- worker transport failure、timeout、manager 不可达统一映射为对应 `503 *_unavailable`。
- detail / surface 代理失败不得影响既有 timeline / summary 的成功响应。

### 6. LiveView 行为合同

- 点击 timeline item 时，不再依赖当前 `selected_event` 的本地浅拷贝组装 detail。
- `RunLive` 只保存当前选中的 `event_id` 与独立的 detail state。
- detail 加载中、detail 错误、surface 加载中、surface 错误都必须是独立状态机，不能覆盖 timeline list。
- 默认进入页面时：
  - timeline 仍按既有 recent window 自动加载。
  - detail 仍为空态。
  - 不自动触发任一 heavy surface 请求。
- detail 成功后：
  - 展示稳定基础字段。
  - 展示 `tool/payload/prompt/shell` 摘要与按钮。
  - 只有用户点击具体按钮时才请求对应 surface。
- `context surfaces` 与 `dependencies & attention` 继续保留 placeholder，不在本卡补正文。

## 最小验收集

- 默认打开 `/projects/:project_id/runs/:issue_identifier` 时：
  - summary 可见。
  - timeline 可见。
  - detail 面板为空态。
  - 页面中不出现 raw/payload/prompt/shell 正文。
- 点击一个当前页事件后：
  - 只请求该 `event_id` 的 detail。
  - detail 展示 `event_id/timestamp/source/event_type/event_group/summary` 与 `session/thread/turn`。
  - 未点击 surface 按钮前，不请求 surface 接口。
- 点击具体 surface 按钮后：
  - 只请求当前 `event_id` 的该 surface。
  - 返回内容 obey 截断与脱敏合同。
- 当 event 不存在、surface 不可用、worker 不可达或 payload 文件损坏时：
  - detail 面板显示独立错误。
  - 已有 summary 与 timeline 保持可见。
- detail 查找不依赖当前 timeline 页内缓存：
  - 即使事件不在当前已加载页，也应按当前 run trace 直查其 `event_id`。
- 必须覆盖跨 run / 跨事件负例：
  - 若另一个 run_trace 中存在同名 `event_id`，当前请求仍只能在当前 run_trace 内命中；命不中时返回 `404 event_not_found`。
  - 若当前事件没有所请求的 surface，不得回落到其他事件或全局 raw，只能返回 `404 surface_not_available`。

## 文档索引

- 当前入口文件即本卡第二轮 document-phase 稳定快照。
