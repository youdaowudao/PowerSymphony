# C-51 Run 深看页 Timeline 浏览层

## 目标

为 control-plane 的 run 深看页补齐第一版 timeline 浏览层，让人类进入 `/projects/:project_id/runs/:issue_identifier` 后，能先看到最近一段压缩事件，再继续向前加载历史，而不是只看到 summary 骨架。

## 需求快照

### 要解决什么问题

- 当前 run 深看页只有顶部 summary 与多个骨架区块，Timeline 区块仍停留在 “Not loaded by default.”，无法实际浏览主要过程。
- `RunTrace.timeline/2` 已经具备 recent window 与 cursor 分页能力，但 control-plane 页面链路还没有把这份 timeline 接到 run 深看页。
- 人类需要先从页面上读懂主要过程和关键注意点，而不是先打开 raw log 或单 event detail。

### 成功标准

- run 深看页默认显示最近一段 timeline，而不是全量展开。
- 页面上存在继续加载更早 timeline 的入口，并复用既有 cursor 分页能力。
- 第一版页面层能辨认异常、attention、quiet 等阅读信号，并为后续 `M4-3` 保留单 event 下钻入口。
- 仍然保持首屏轻量，不在本卡引入 raw payload、prompt、shell、thread/turn/context 正文。

### 明确不做什么

- 不重开 `M4-2A` 的 timeline item 基础合同定义。
- 不在本卡引入 `run_id` 新身份键或重写现有页面路由。
- 不在本卡实现单 event detail 正文、raw payload、prompt、shell output、thread/turn/context/依赖展示。
- 不把首页 dashboard 或项目详情页升级成 timeline 主视图。

### 固定约束

- 继续沿用 `project_id + issue_identifier` 作为 run 深看页身份键。
- timeline 默认窗口与分页必须复用现有 `RunTrace.timeline/2` recent window / cursor 机制。
- 第一版“重试 / 状态切换”强调只消费当前稳定信号；若现有投影无法稳定表达，不在本卡强行扩成重合同。
- 这张卡允许补“最小 timeline 数据通路”，但不把它扩成 raw/detail 卡。
- timeline 查找语义固定为：`project_id + issue_identifier` 只解析到“当前 run summary 对应的运行中 `run_trace`”，不得按 `issue_identifier` 去扫描历史 `run_id` 目录；若当前 summary 无法解析到可读 `run_trace`，接口返回 `404 run_not_found`。
- timeline 失败降级语义固定为：只要 run summary 能命中，深看页 summary 区块必须继续可见；timeline recent window 拉取失败、load more 失败、cursor 非法或 worker 不可达时，只允许 Timeline 面板降级为独立错误态，不得把整页回退成 `run missing`。

## 实现合同

### 1. summary 到当前 `run_trace` 的解析面

- run 深看页顶部 summary 继续只读 `project_id + issue_identifier -> run_summaries` 的轻量投影，不把 `run_trace`、`run_instance_id` 或其他运行时句柄塞回 summary 合同。
- Timeline 不从 `run_summaries` 反查历史目录，也不要求 control-plane 持久保存 `run_trace` 句柄；它必须在“当前 worker 的当前运行态”里按 `issue_identifier` 命中唯一 running entry，再读取该 entry 上的 `run_trace`。
- worker 侧命中条件固定为：当前 running entry 存在、`issue_identifier` 相等、且 entry 上同时存在当前运行对应的 `run_trace`。
- 若 worker 当前 running 态里出现多条相同 `issue_identifier` 的 entry，这视为当前运行态不满足“唯一 running entry”前提；worker timeline 入口返回 `409 duplicate_run`，control-plane 与 LiveView 都只把它当作 Timeline 面板独立错误，不尝试猜测该选哪一条。
- 若当前 running entry 不存在，或 entry 上没有 `run_trace` 句柄，则 worker timeline 入口返回 `404 run_not_found`。
- `run_instance_id` 只用于保证 worker 侧 summary 与 timeline 都绑定当前运行中的同一条 trace，不在本卡提升为新的页面路由键，也不要求 control-plane 对外暴露。
- `run_trace` 句柄一旦命中，其 `trace_file` 尚未生成或文件不存在，视为“当前 run 已命中但 timeline 为空”，返回 `200` + 空 `items`，不回退为 `404`。
- `run_trace` 句柄已命中但时间线读取过程出现真实读取/解码失败时，视为 timeline 不可用，返回 `503 timeline_unavailable`，而不是 `404 run_not_found`。
- retrying 队列、历史 run 目录、已结束但仍留在磁盘上的 trace 都不属于本卡的 timeline 查找范围。

### 2. control-plane 到 worker 的读取合同

- 本卡不把 timeline 塞进 `project_summary_payload/2` 或 `project_run_summary_payload/3`；summary 仍是轻量首屏，timeline 继续按需懒加载。
- control-plane 新增按项目代理的 timeline 读取入口，页面内部语义等价于：
  - `GET /api/v1/projects/:project_id/runs/:issue_identifier/timeline?cursor=...`
- control-plane 代理到 worker 的读取入口语义固定为：
  - `GET /api/v1/runs/:issue_identifier/timeline?cursor=...`
- worker timeline 成功响应只返回当前页 `items` 与 `next_cursor`，不回传 raw payload、event 正文、thread/turn/context，也不额外扩充 summary 合同。
- query 只允许透传 `cursor`；页大小继续由 worker 侧 recent window 默认值控制，本卡不在页面层新增“每页条数”配置。
- worker timeline 错误 body 与 control-plane 代理映射固定为：
  - worker `400` + `invalid_cursor` -> control-plane 保持 `400 invalid_cursor`
  - worker `404` + `run_not_found` -> control-plane 保持 `404 run_not_found`
  - worker `409` + `duplicate_run` -> control-plane 保持 `409 duplicate_run`
  - worker `503` + `timeline_unavailable` -> control-plane 保持 `503 timeline_unavailable`
  - worker transport timeout / connect failure / worker 不可达 -> control-plane 统一映射为 `503 timeline_unavailable`
- control-plane 禁止把 worker 明确返回的 `400/404/409` 吞并成泛化 `503`。

### 3. 错误映射与页面降级分界

- 页面首屏 mount 分两层判断：
  - 若 `project_id + issue_identifier` 连 summary 都命不中，整页保持现状，返回 `run missing`。
  - 若 summary 命中，则整页必须先展示 summary，再异步读取 timeline。
- timeline 读取阶段的失败全部收敛为 Timeline 面板独立状态，不得反向覆盖整页 summary：
  - worker 返回 `404 run_not_found`：表示 summary 仍在，但当前 worker 已无法解析到这条 summary 对应的 running trace；页面显示 Timeline unavailable。
  - worker 返回 `400 invalid_cursor`：表示 load more cursor 非法；页面保留已加载条目，并把 Timeline 面板切到 load more 错误态。
  - worker 返回 `409 duplicate_run`：表示 worker 当前运行态里同一个 `issue_identifier` 出现重复 running entry；页面保留 summary，并把 Timeline 面板切到独立错误态，不替人类猜测应该读哪条 run。
  - worker 返回 `503` / 连接失败 / timeout：表示 worker 不可达或 timeline 拉取失败；页面保留 summary 与已加载 timeline，Timeline 面板显示独立错误态。
- “summary 命中但 timeline 失败” 与 “整页 run missing” 的唯一区别，以 summary 是否命中为准；一旦 summary 已命中，本卡禁止再把整页回退成 `run missing`。

### 4. 第一版阅读强调合同

- 第一版 item 级强调只依赖 `RunTrace.timeline/2` 已稳定给出的字段：`timestamp`、`source`、`event_group`、`summary`、`event_type`、`event_id`、`status_markers`。
- 第一版允许稳定承诺的强调只有：
  - `attention`：直接消费 `status_markers` 中的 `attention`。
  - `completed` / `session_started`：直接消费 `status_markers` 中的 `completed`、`session_started`。
  - `retry`：仅当 `source == "orchestrator"` 且 `event_type == "retry_scheduled"` 时显示 retry 强调，不引入额外重试合同。
  - `状态切换`：第一版只强调 `session_started`、`turn_completed`、`run_result` 这几类当前已有稳定 `event_type` 的转折点，不做通用 phase diff，也不读取/推断 summary phase 差分解释。
- `quiet` 在本卡固定为页面/面板级阅读提醒，不是 timeline item 新字段：
  - 仅复用现有 run summary 的 `health`、`last_event_at`、`current_phase` 等稳定信号；
  - 若 summary 已显示 `possibly_stalled` / 同类安静过久信号，则在 Timeline 标题区或面板级展示 quiet attention；
  - 不为 timeline item 新增 quiet marker。
- 若某种阅读强调必须依赖 payload、raw event、prompt、shell 或 thread/turn 正文才能成立，则该强调后置给 `M4-3`，本卡不硬做。

## 当前实现判断

- worker 侧已有 `RunTrace.timeline/2`，能返回 `items + next_cursor`。
- control-plane 当前只有 `run_summaries` 数据链，尚无 run timeline 读取入口。
- 因此本卡不是“纯页面补壳”，而是“最小 timeline 数据通路 + 页面浏览层”联合改动。

## 验证路线

- `RunTrace` 单测继续覆盖 recent window / cursor / invalid cursor / stable item shape。
- worker timeline 入口测试覆盖默认窗口、cursor 透传、空数据、非法 cursor，以及“summary 对应 running entry 不存在或 entry 无 `run_trace` 时返回 `404 run_not_found`”。
- worker timeline 入口测试还要覆盖：重复 `issue_identifier` 时返回 `409 duplicate_run`，以及 `trace_file` 缺失时返回空 timeline 而不是 `404`。
- control-plane 侧测试覆盖 worker timeline 请求链路、错误映射、query 透传，以及 cursor/query 不串到其他 run；同时证明 summary payload 仍保持轻量，不被 timeline 合同污染。
- LiveView 测试覆盖默认 recent window、加载更多、阅读强调、detail 占位入口、summary 命中但 timeline recent window 失败、summary 命中但 load more 失败、summary 命中但 worker 返回 `404 run_not_found`、`409 duplicate_run`，以及 non-goal 边界。

## 文档索引

- 当前入口文件即本卡稳定目标快照。
