# 错误续跑分析纠正：背景入口

日期：2026-05-05  
对应事项：`M1-6 / C-21`  
文档角色：正式规划参考入口

## 这份文档是做什么的

这不是完整分析，也不是实现方案正文。

它只负责给后续接手的人一个最短入口，回答 4 个问题：

1. 这次讨论的对象是什么
2. 为什么它值得单独立项
3. 现有结论放在哪
4. 后续实现时先看什么、不要误解什么

## 讨论对象

当前讨论对象是 Symphony 单项目执行链中与 `turn/completed`、run 结束判定、active issue continuation 相关的语义错位问题。

现象上表现为：

- 同一张 active Linear issue 会在业务上尚未闭环时，连续开启多个 turn
- 人看到 `completed` 类日志时，容易误以为任务完成
- 系统会把 turn 级结束放大成继续续跑的边界

这次讨论不涉及：

- 多项目 Control Plane 新功能设计
- Web 展示层设计
- Trace / RawEventStore 方案设计
- Workflow 模块化生成

## 为什么单独立项

这不是单纯日志文案问题，也不是一次偶发卡死。

它影响的是单项目执行链的基线语义：

- `turn/completed` 到底代表什么
- 什么情况下允许把一次 turn 结束解释成 run 结束
- `AgentRunner` 和 `Orchestrator` 应该如何分工
- active issue 的 continuation 应该在哪一层收敛

如果这层语义不先捋顺，后续多项目控制面会建立在不稳定的执行基线上。

## 现有结论放在哪

当前主分析文档：

- [20_turn_closeout_analysis.md](/home/ssss/projects/powersymphony/DOCS/plan_rerun_fix/20_turn_closeout_analysis.md)

后续冻结边界与实现约束：

- [90_decision_and_scope.md](/home/ssss/projects/powersymphony/DOCS/plan_rerun_fix/90_decision_and_scope.md)

## 后续执行者先看什么

建议顺序：

1. 先看本文件，确认问题边界
2. 再看 `20_turn_closeout_analysis.md`，理解证据链和当前判断
3. 最后看 `90_decision_and_scope.md`，确认哪些已经冻结、哪些还不能直接动手

## 当前最重要的提醒

后续实现时，不要一上来就把问题理解成下面任一项：

- “只是 `completed` 文案不准”
- “只是调度器多跑了几轮”
- “只要改 prompt 就够了”
- “只要改 `app_server.ex` 就够了”

当前已达成的共识是：

- 真正该拦的是 `turn_completed` 被过早升级成健康 run 边界
- 主修点在 `agent_runner` / `orchestrator` 的边界
- 但又不能破坏 `max_turns` 之后继续 active ticket 的合法路径

## 当前状态

当前目录已经作为 `M1-6 / C-21` 的本地规划参考集合存在。

含义是：

- 文档用于冻结问题边界与方案方向
- 当前目录中的结论服务于阶段 1 的正式规划与后续实现卡
- 当前结论仍未进入代码实现，后续应以实现卡和代码变更继续推进
