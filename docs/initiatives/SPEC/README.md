# 专题 SPEC 入口

本目录用于维护当前项目长期有效、可被 coder 和 reviewer 直接引用的专题 SPEC。

这些文档回答的是：

- 架构怎么分层
- Web 展示和线程观测怎么做
- Workflow 生成方案怎么做
- 质量门禁和验收边界是什么

它们不是：

- 阶段计划
- 单次 change 实施步骤
- 即时执行提示词

当前专题 SPEC：

- [30_总体架构.md](./30_总体架构.md)
- [31_Web展示与线程观测.md](./31_Web展示与线程观测.md)
- [32_Workflow生成方案.md](./32_Workflow生成方案.md)
- [33_质量门禁与验收边界.md](./33_质量门禁与验收边界.md)

coder 阅读建议：

1. 先看上一级 `README.md`
2. 再看当前任务对应的 `docs/changes/<change-id>/README.md`
3. 只读取该 change README 明确点名的专题 SPEC

写作者路由：

- 写长期有效的架构、观测、Workflow、质量边界：
  - 写在本目录
- 写某阶段的临时交付范围和门禁：
  - 改到 `阶段规划/`
- 写单次高风险变更的设计和实施：
  - 改到 `docs/changes/`
