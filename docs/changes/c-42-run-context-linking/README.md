# C-42 Run 深看页上下文串联

## 目标

让人类在 `/projects/:project_id/runs/:issue_identifier` 中，不只看到当前 run 的 summary、timeline 和单事件 detail，还能直接看见这次 run 属于哪个 thread、哪个 turn，以及它与最近交互信号、continuation / retry、tool、shell、sub-agent 线索之间的只读关联。

## 非目标

- 不做 raw / payload / prompt / shell 正文默认展开。
- 不做新的全量会话原文浏览器。
- 不做依赖关系与 attention 总面板。
- 不重写 `project_id + issue_identifier` 深看页身份键。
- 不改变 C-41 / C-51 已冻结的 timeline 与单事件 detail 合同。
- 不把上下文串联做成新的执行决策入口。

## 需求快照

### 要解决什么问题

- 当前 run 深看页已经有 summary、timeline、event detail 与 surface 懒加载，但 `Context surfaces` 仍只是占位文案。
- 用户仍然很难回答“这次异常是某条单事件的问题，还是整条 thread / turn / tool / continuation 链的问题”。
- 现有 trace 数据已经记录了 thread / turn、timeline、tool call、requestUserInput、shell-like 片段和 orchestrator retry/continuation 线索，但页面上还没有把这些线索聚合成可阅读的上下文摘要。

### 成功标准

- run 深看页能稳定展示当前 run 的 thread / turn 锚点与 session 关系。
- 页面能展示最近交互信号摘要，但以摘要为主，不默认展示完整 user / assistant 原文。
- 页面能展示 continuation / retry / recent tool / shell 的轻量摘要。
- sub-agent 面板在没有稳定 trace 线索时，必须明确降级为 `unavailable` 或 `none_observed`，而不是伪造摘要。
- 每个上下文面板都保持只读、轻量、按需跳转，不新增重数据正文默认加载。
- 这些面板退化或失败时，不影响 summary、timeline 和 event detail 的既有能力。

### 明确不做什么

- 不新增新的 raw surface 类型，不扩展到 conversation 正文分页。
- 不回扫历史 run 目录，不跨 issue_identifier 拼接历史会话。
- 不为了做上下文串联而新增数据库或持久索引。
- 不承诺 UI 层做完整去重、聚类、跨 run 对比或产品级总收口。

## 固定约束

- 深看页身份键继续沿用 `project_id + issue_identifier`。
- summary、timeline、event detail 的已有接口与错误语义必须保持稳定。
- 本卡若需要新增读取面，只能建立在“当前唯一 running entry 的当前 run_trace”之上，不得退化成历史扫描。
- context summary 必须像 event detail 一样先限定到“当前唯一 running entry 的当前 `run_instance_id` / generation”，再读取该 generation 的最近窗口；不得把旧 attempt 事件混进当前 run。
- 返回内容必须是轻量摘要、标签、锚点与只读入口，不能默认返回 raw 正文。
- 第一版 conversation 只能承诺“recent interaction signals / 最近交互信号摘要”，不能承诺完整 user / assistant 原文回放。
- 第一版 sub-agent 只能承诺“是否观察到稳定的 sub-agent trace 线索”；若 trace 中没有稳定线索，必须显式降级而不是编造。
- 第一版 context summary 是 best-effort 的当前 generation 最近窗口摘要，不是完整上下文浏览器。

## 设计结论

本卡采用“在当前 run_trace 之上新增轻量 context summary 聚合层”的方案：

- 复用当前 run 的 `RunTrace.timeline/2`、`RunTrace.event_detail/3` 与既有 raw event 存储。
- 新增 worker 侧只读 context summary 读取入口，聚合“当前 generation 最近窗口内”的 thread / turn / recent interaction signals / continuation / tool / shell / sub-agent 线索。
- control-plane 只做代理，不把 context summary 混进 summary 首屏合同。
- `RunLive` 把现有 `Context surfaces` 占位区替换为真实摘要卡片，但保留轻量、独立失败态和只读边界。

## 文档索引

- `10_design.md`：上下文聚合合同、字段来源与 UI 边界。
- `20_plan.md`：实现顺序、测试路线与风险控制。
