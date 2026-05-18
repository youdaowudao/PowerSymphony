# C-43 依赖关系与关注事项只读面板实施计划

## 目标

在不新增编辑能力和专用接口面的前提下，为 `RunLive` 深看页补齐依赖关系与关注事项只读面板，并用现有测试体系证明：

- 关系展示来自当前运行态的稳定投影。
- attention 复用既有健康度 / Checking 语义。
- timeline、event detail 和 summary 的既有降级边界不被破坏。

## 实施步骤

### 1. 冻结数据形状

- 检查 `Presenter.running_entry_payload/1`、`ProjectProcessManager.project_run_summary_from_running_entry/1`、`Presenter.project_run_summary_payload/1` 的现有字段。
- 设计 C-43 需要的最小新增字段：
  - `blocked_by`
  - `blocks`
  - `attention_items`
- 确保这些字段都能从当前 worker `running` entries 或既有 summary 语义推导，不新增 Linear 二次读取。

### 2. 先写失败测试

- 在 `elixir/test/symphony_elixir/extensions_test.exs` 增加 control-plane / LiveView 用例，证明当前占位实现不满足以下行为：
  - 深看页展示 `blockedBy` / `blocks` 列表。
  - 深看页展示 `needs attention` 类只读提示。
  - `Checking` cooldown 期间不展示 attention。
- 如需要，在 `Presenter` 或 `ProjectProcessManager` 相关测试文件补最小单测，固定新字段投影。

### 3. 最小化扩展运行态投影

- 在 worker `/api/v1/state` payload 的 running entry 投影中加入 `blocked_by`。
- 在 control-plane 刷新 `run_summaries` 的投影逻辑中：
  - 透传 `blocked_by`。
  - 基于同一项目当前 `run_summaries` 反向计算 `blocks`。
  - 基于现有 summary 字段生成 `attention_items`。
- 保持 project detail / run detail 的轻量语义，不引入新按需加载接口。

### 4. 落地页面面板

- 修改 `elixir/lib/symphony_elixir_web/live/run_live.ex`：
  - 替换 `Dependencies & attention` placeholder。
  - 分开渲染 `Dependencies` 与 `Attention` 两个只读区块。
  - 对依赖项提供 issue 标识与链接。
  - 对 attention 提供稳定、可测试的文案。
  - 保留空态文案，避免无数据时出现空白区块。

### 5. 复跑测试并清理

- 先跑新增 / 相关定向测试，确认 red -> green。
- 必要时补 presenter / project detail 的回归验证。
- 自查：
  - 是否错误把正常 `Checking` 包装成 attention。
  - 是否把 `blocks` 算成跨项目 / 历史目录扫描。
  - 是否破坏既有 timeline / detail 行为。

## 目标文件

- `docs/changes/c-43-deep-view-dependencies-attention/README.md`
- `docs/changes/c-43-deep-view-dependencies-attention/20_plan.md`
- `elixir/lib/symphony_elixir_web/presenter.ex`
- `elixir/lib/symphony_elixir/project_process_manager.ex`
- `elixir/lib/symphony_elixir_web/live/run_live.ex`
- `elixir/test/symphony_elixir/extensions_test.exs`

## 本地验证

按当前累计 diff 命中 `elixir/**`，后续 PR create/update push 的 `Next Push Gate` 必然是 `local make all`。开发阶段先跑定向测试，收口前再执行：

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/extensions_test.exs
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- make all
```

## 协作模式

- 默认 `1+2`
- 子线程 1：实现与定向验证
- 子线程 2：零上下文复核
- 主线程：冻结目标、派发、验收、执行 gate、推送、PR 收口、auto-merge 跟踪
