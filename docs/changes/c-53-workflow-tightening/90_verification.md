# C-53 一致性验证与收口检查

## 用途

本文件定义 C-53 规则收紧在文档与规则层面的最小验证集，避免目标态只停留在单个 change 文档里，没有真正落到仓库生效文本。

## 计划中的验证项

### 1. 口径一致性检查

- 根 `AGENTS.md`、`elixir/WORKFLOW.md`、`elixir/README.md`、治理文档与模板中：
  - 默认协作模式统一为 `1+2`
  - `1+1` 只保留给“小修小改 / 强探索”例外
  - 不再残留“`1+2` 只是计数表达”或默认 `1+3` 的旧说法

### 2. reviewer 输出一致性检查

- `Implementation Review` 全部替换为 `Change Review`
- `Push Readiness` 在各文件中都只表达：
  - 现在能不能 push
  - 如果不能，push 前最小还缺什么
- `Push Readiness` 取值保持二值：`ready | not ready`
- 无后续 push 时，只能写在 `Next Push Gate` 或 `Push Readiness Notes`，不能把 `Push Readiness` 扩成第三值
- 不把 `Push Readiness` 写成新 gate、state、审批层或 merge 权限来源

### 3. document-phase gate 一致性检查

- `proceed` 后进入 `spec freeze`
- freeze 后只允许一次 reviewer 触发的定点补查
- `light document refresh path` 已被定义为：只刷新既有 frozen artifact，不重开广谱探索，不额外增加 focused recheck，完成后恢复实现/验证
- 相关表述在 workflow、README 高层说明和治理/模板里不互相冲突

### 4. 条件触发风险门检查

- 至少覆盖 BEAM / typed core path、event normalization、state machine / concurrency boundary、reviewer 明确标记 type / integration risk、返工后多风险 diff
- 明确这是条件触发式中途风险验证，不是所有卡默认重门禁
- 明确它只影响最小补证与下一次 push gate，不新增状态层
- 明确唯一一次 focused recheck 只能由 reviewer 触发

### 5. `## Codex Workpad` 真相源检查

- 活状态板与流程指标只留在 issue body / `## Codex Workpad`
- `Status Board` 与 `Flow Metrics` 字段在 workflow 模板中可见
- `Status Board` 最小板统一为：当前阶段 / 已完成 gate / 当前 blocker / 下一 gate / 当前 reviewer 结论 / 返工次数
- risk gate 与 focused recheck 不再作为额外主字段扩张 `Status Board`，而是落在 `Current Blocker / Next Gate` 或 `Notes`
- repo 文档只定义语义边界，不复制实时值

## 轻量自检方式

- 用 `rg` 检查旧词是否残留：
  - `1+3`
  - `Implementation Review`
  - `1+2` 只是计数
- 用人工通读检查：
  - 是否还存在“目标态尚未生效”的过时措辞
  - 是否有模板、README 或治理文档漏改

## 收口标准

满足以下条件时，才算本 change 的文档/规则层实现收口：

1. 允许改动范围内的规则文件已全部更新。
2. 新旧口径不再在仓库内并存。
3. C-53 change 文档、治理层和 workflow 合同对同一概念没有冲突定义。
4. 轻量静态自检已完成，并记录剩余风险。
