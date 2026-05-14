# C-39 Run 深看入口与页面骨架 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为控制面补齐项目轻量详情页与 run 深看页，让用户能先在项目详情中浏览轻量 run summary，再进入独立的 run 深看骨架页，而不会在首屏默认加载 timeline/raw 等重数据。

**Architecture:** 继续复用 `Presenter.project_summary_payload/2` 已冻结的轻量 `run_summaries` 合同，不新增 raw/timeline API。新增两个 LiveView 页面：项目详情页负责轻量 run 列表和入口，run 深看页只消费现有 summary 字段并渲染一层骨架占位区。首页 control-plane Dashboard 只补导航入口，不把重内容堆回总览页。

**Tech Stack:** Elixir, Phoenix LiveView, ExUnit

---

### Task 1: 用路由与页面回归测试锁定分层边界

**Files:**
- Modify: `elixir/test/symphony_elixir/extensions_test.exs`
- Read: `elixir/lib/symphony_elixir_web/router.ex`
- Read: `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`

- [ ] 为 control-plane 场景新增项目详情页测试，证明 `/projects/:project_id` 只展示轻量 run summary，并包含进入 run 深看页的明确入口。
- [ ] 为 control-plane 场景新增 run 深看页测试，证明 `/projects/:project_id/runs/:issue_identifier` 顶部 summary 字段齐全，且 timeline、event detail、thread/turn/context、依赖与关注事项都只是骨架占位，不默认加载正文。
- [ ] 为导航路径新增测试，证明首页项目行能进入项目详情页，项目详情页能进入 run 深看页。
- [ ] 先运行定向测试并确认失败原因来自缺少新路由/页面，而不是测试环境或端口残留。

### Task 2: 新增项目详情页并把轻量 run 主视图从总览层切出来

**Files:**
- Create: `elixir/lib/symphony_elixir_web/live/project_live.ex`
- Modify: `elixir/lib/symphony_elixir_web/router.ex`
- Modify: `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`
- Modify: `elixir/lib/symphony_elixir_web/presenter.ex`

- [ ] 新增 `ProjectLive`，基于 `project_id` 读取现有轻量 project summary，并渲染项目级轻量主视图。
- [ ] 项目详情页只展示轻量字段和 run summary 列表，不接 timeline/raw/prompt/shell output。
- [ ] 在 run 列表里为每个 summary 提供进入深看页的链接，形成明确入口。
- [ ] 首页项目区域补 `View details` 或等价入口，让人类能从项目总览进入项目详情。

### Task 3: 新增 run 深看页骨架并保持首开轻载

**Files:**
- Create: `elixir/lib/symphony_elixir_web/live/run_live.ex`
- Modify: `elixir/lib/symphony_elixir_web/router.ex`
- Modify: `elixir/lib/symphony_elixir_web/presenter.ex`

- [ ] 新增 `RunLive`，按 `project_id + issue_identifier` 读取对应 run summary。
- [ ] 顶部 summary 至少展示 `issue_identifier`、`title`、`linear_state`、`current_phase`、`current_action`、`health`、`thread_id`、`turn_id`、`last_event_at`、`run_duration_seconds`。
- [ ] 页面正文只建立以下骨架区块，不加载重数据正文：
  - `timeline`
  - `event detail`
  - `thread / turn / conversation / tools / sub-agent context`
  - `dependencies & attention`
- [ ] 页面文案要明确这些区块是“预留入口/按需加载”，避免误导成已实现完整内容。

### Task 4: 定向验证与收口

**Files:**
- Verify: `elixir/test/symphony_elixir/extensions_test.exs`

- [ ] 运行本卡定向测试：
```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test test/symphony_elixir/extensions_test.exs
```
- [ ] 如范围允许，补充更窄的单文件或单行测试重跑，确认新增路由和 LiveView 页面稳定。
- [ ] 每轮测试后立即检查并清理 fake worker、beam 进程和端口残留，避免叠加污染下一轮验证。
- [ ] 最终确认本卡没有新增 timeline/raw/event detail 正文 API，也没有把 run 深看重内容塞回项目轻量页。
