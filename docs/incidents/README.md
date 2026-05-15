# 事故文档

本目录用于事故分析与复盘。

不是每个 bug 都需要建立事故目录。

满足以下任一情况时，建议升级为事故文档：

- 问题影响真实运行、真实数据或真实自动化流转
- 问题跨多个 ticket、PR、session 或线程
- 需要保留时间线、证据链和根因分析，供后续复盘
- 这次排查和归因本身具有长期复用价值

推荐结构：

```text
docs/incidents/<incident-id>/
  00_summary.md
  10_timeline.md
  20_evidence.md
  30_root_cause.md
  40_actions.md
```

当前事故目录：

- [c-50-ownership-split-brain/README.md](./c-50-ownership-split-brain/README.md)

补充规则：

- 如果事故修复本身也复杂或高风险，可以并行建立 `docs/changes/<change-id>/`。
- `incident` 关注事实、时间线、证据、根因和后续动作。
- `change` 关注具体实现方案、执行计划和验证结果。
- 两者可以同时存在，但不要互相重复抄写。
