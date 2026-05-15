# 单次变更模板

建议至少从一个入口文件开始，例如：

```text
docs/changes/<change-id>/
  README.md
  10_design.md
  20_plan.md
  90_verification.md
```

入口文件 `README.md` 或等价文件应至少包含：

- 目标
- 非目标
- 需求快照
- 成功标准
- 固定约束
- 风险
- 文档索引

说明：

- 这里的“需求快照”不是复制整条 Linear 历史，而是给 repo 内 review 提供最小、稳定、可审查的目标说明。
- reviewer 应能只看 change 文档、diff 和测试，就判断实现是否命中需求。
- change 入口还应点名这次必须看的 `SPEC/` 或 `阶段规划/` 文档，避免 coder 自己猜。
