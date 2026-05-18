# C-44 实施计划

## 实现策略

这张卡只在 LiveView 展示层收口现有能力，不新增新的后端数据合同。实现顺序遵循：

1. 先用测试冻结目标交互与状态表现。
2. 再在 `RunLive` 中引入产品层视图状态、折叠与过滤逻辑。
3. 最后补样式与移动端收口，并用现有 LiveView 测试证明懒加载边界未被打破。

## 改动边界

### 预计修改文件

- `elixir/lib/symphony_elixir_web/live/run_live.ex`
  - 深看页概览层级、折叠 / 过滤状态、统一区块状态和移动端信息顺序。
- `elixir/priv/static/dashboard.css`
  - 为 run deep view 补局部样式：概览卡、区块折叠、过滤 chips、统一状态块和移动端收口。
- `elixir/test/symphony_elixir/extensions_test.exs`
  - 新增 / 调整 run deep view 行为测试，覆盖产品层交互与回归边界。

### 不计划修改

- `Presenter`、`ProjectProcessManager`、`RunTrace`、`RunStateStore`、`ObservabilityApiController`
  - 除非实现中发现现有 payload 无法支撑前端本地过滤或区块摘要；当前冻结边界下默认不动这些模块。

## TDD 路线

### 任务 1：冻结新的深看页产品层结构

- 在 `extensions_test.exs` 新增或扩展 run deep view 测试，先描述：
  - 概览区应前置显示主状态、`attention_count` / `blocked_by_count` / `blocks_count` 三类固定 counts，以及只来自 `attention_items[0]` 的首要 attention 摘要。
  - 页面应出现统一的产品层区块标题和折叠按钮。
  - 默认只展开 `Overview`、`Action Needed`、`Timeline`，`Context` 与 `Event Detail` 以 collapsed 入口出现。
- 红灯验证：
  - `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/extensions_test.exs --only run_live_product`
  - 先确认现有 DOM 不满足新断言。

### 任务 2：实现区块折叠和 timeline 本地过滤

- 在 `RunLive` 新增前端本地视图状态：
  - 区块折叠状态 map
  - timeline filter 状态
- 保持 timeline 懒加载不变，只对已加载 items 做本地筛选；filter allowed set 固定为 `all`、`attention`、`retry`、`session`、`turn_completed`、`run_result`。
- 需要新增交互测试：
  - 点击折叠不会触发 detail / surface / context 的额外请求。
  - timeline filter 只改变渲染结果，不改变底层 items。
  - active filter 在 `load_more` 之后重新应用到累计 items。

### 任务 3：统一空态 / 异常态 / 加载态

- 在 `RunLive` 把 timeline、context、detail、dependencies、attention 的文案与容器统一成相同模式。
- 测试覆盖：
  - summary 正常但 timeline/context 局部失败时，概览仍保留。
  - 空 dependencies / attention / context items 时显示统一空态。
  - `Checking` 且 `attention_items == []` 时，`Action Needed` 保持空态，不回退到 `current_action` 或 `health`。
  - 无 identifier 的 blocker placeholder 在压缩概览和 dependencies 列表里仍可见。
  - 懒加载中的文案和结构稳定。

### 任务 4：移动端最小可用布局与视觉收口

- 在 `dashboard.css` 增量增加：
  - run deep view 概览网格
  - filter chips / section toggle
  - mobile breakpoint 下的单列布局和摘要压缩
- 测试侧以 DOM 结构 / class 为主，不做像素断言。

## 验证路线

### 开发期定向验证

- `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/extensions_test.exs`
- 如需只跑局部，可先用行号或 `--only` 跑新增的 run deep view 测试，再回到整文件。
- 每轮测试结束后检查无残留 server / port / env 污染。

### Closeout Gate

- `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix format --check-formatted`
- `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix lint`
- `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/extensions_test.exs`

### Next Push Gate

- 因累计 diff 命中 `elixir/**`，PR create/update 前必须执行：
  - `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- make all`

## 已知风险与对应证明

- 风险：折叠 / filter 误触发额外加载。
  - 证明：保留并扩展现有 stub request 断言，确认未发生新的 detail/surface/context 请求。
- 风险：`Action Needed` 或 counts 越界推断 summary 之外的语义。
  - 证明：测试明确锁定首条重点只来自 `attention_items[0]`，counts 只来自三类 summary list length。
- 风险：统一状态文案时掩盖局部失败。
  - 证明：保留 timeline/context/detail 独立失败回归测试。
- 风险：产品层重排破坏 dependency / attention 只读语义。
  - 证明：既有 Dependencies / Attention 测试继续通过，并补概览摘要断言但不改底层 message；workflow/control-plane 两条链都覆盖同一口径。
