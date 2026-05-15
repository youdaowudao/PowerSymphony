# C-39 Run 深看入口与页面骨架

## 目标

为控制面补齐项目轻量详情页与 run 深看页，让用户能先在项目详情中浏览轻量 run summary，再进入独立的 run 深看骨架页，而不会在首屏默认加载 timeline、raw event 等重数据。

## 需求快照

### 要解决什么问题

- 当前 control-plane 总览页同时承担项目概览与 run 详情入口，run 深看缺少独立页面和明确导航层级。
- 用户需要先看轻量 run summary，再按需进入更深一层的 run 页面，而不是在首页默认加载重内容。

### 成功标准

- 新增项目详情页，能展示项目级轻量 summary 与 run 列表。
- 新增 run 深看页，顶部 summary 字段齐全，正文只保留骨架占位。
- 首页项目行可以进入项目详情页，项目详情页可以进入 run 深看页。
- 不新增 timeline/raw/event detail 正文 API，也不把重内容塞回总览页。

### 明确不做什么

- 不在本卡实现 timeline、raw event、conversation、tool context 的正文加载。
- 不把首页 dashboard 扩成完整 run 详情页。
- 不引入新的重型 summary 合同或 raw 数据接口。

### 固定约束

- 继续复用 `Presenter.project_summary_payload/2` 已冻结的轻量 `run_summaries` 合同。
- 只新增页面与路由分层，不改变现有轻量 summary 的职责边界。
- 验证以定向 LiveView / 路由测试为主。

## 文档索引

- [20_plan.md](./20_plan.md)
