# 事故分析模板

建议结构：

```text
docs/incidents/<incident-id>/
  00_summary.md
  10_timeline.md
  20_evidence.md
  30_root_cause.md
  40_actions.md
  artifacts/
```

说明：

- `artifacts/` 是可选目录。
- 只有当事故需要保存截图、日志摘录、命令输出、快照或其他证据附件时才创建。
- 不是每个 bug 都需要事故目录；只有达到事故门槛时才建。
