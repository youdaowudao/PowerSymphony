# 仓库级 Agent 规则模板

> 这是模板，不是当前仓库成品。复制到新仓库后必须按真实情况改写。

## 身份与边界

- agent 在该仓库中的角色是什么
- 是否允许改动仓库外文件
- 是否存在生产环境、高风险数据或外部系统

## Issue / Tracker 规则

- 是否使用 Linear、GitHub Issues 或其他 tracker
- 哪些字段或状态变更属于高风险操作
- 更新 tracker 前需要满足什么门槛

## Git / 分支规则

- 是否禁止直推主线
- 默认分支策略是什么
- 提交和 PR 标题用什么语言

## PR / Review / Merge 规则

- 什么时候必须 review
- 什么时候允许 auto-merge
- 什么时候必须停止推进并请求人工帮助

## 文档路由摘要

- `docs/governance/` 放什么
- `docs/changes/` 放什么
- `docs/incidents/` 放什么
- `docs/initiatives/` 放什么
- 是否存在 `SPEC.md`，它在这个仓库里承载什么

## 测试与验证规则

- 本地最小验证要求
- closeout gate 要求
- 远端 full gate 要求
- 高风险路径是否有额外验证要求
- 是否存在条件触发的中途风险门，以及它只回答什么

## 高风险路径补充约束

按仓库真实情况补写：

- 并发
- 生命周期
- 持久化
- 权限 / 安全
- 外部副作用
- 启动 / 停止 / 清理

## 多 Agent 协作规则

- 是否要求 reviewer
- 顶级主轴是否采用“阶段角色制 + 角色独立性”，以及标准角色集合是什么
- 哪些任务必须具备哪些角色
- 哪些角色之间必须保持独立
- 是否定义 `观察层合同风险` 作为显式流程开关，以及命中条件是什么
- 命中 `观察层合同风险` 时，是否要求 `contract checker`、`contract matrix`、`baseline lock`
- reviewer 固定输出是否包含 `Change Review` 与 `Push Readiness`
- 什么时候必须停止当前线程并请求帮助
- `Push Readiness` 是否只回答“能否 push / 最小缺口”
- 文档阶段是否有 `spec freeze` 与一次 reviewer 触发的定点补查
- 活状态板与流程指标是否只允许写在 issue body / `## Codex Workpad`
- `blocker ledger`、`baseline lock` 等活字段是否只允许写在 Workpad
- closeout 是否要求同时定义主顺序、失效条件与最小回退规则

## 填充完成检查

至少确认以下问题都已有答案：

- 新开发者知道文档放哪里吗
- 新开发者知道测试怎么跑吗
- 新开发者知道什么时候能更新 tracker 吗
- 新开发者知道哪些路径最危险吗
- 新开发者知道什么时候必须停下来求助吗
- 新开发者知道最终汇报应该按角色到位性、独立性、返工、争议、验证和放行性来写吗
