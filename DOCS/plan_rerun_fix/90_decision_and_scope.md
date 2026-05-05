# 错误续跑分析纠正：定稿边界与实现范围

日期：2026-05-05  
对应事项：`M1-6 / C-21`  
文档角色：正式规划定稿边界

## 目的

本文件用于冻结当前已经确认的结论，避免后续实现时再次把“现象”“推理”“实现前提”混在一起。

它不是完整分析正文；完整证据链见：

- [20_turn_closeout_analysis.md](/home/ssss/projects/powersymphony/DOCS/plan_rerun_fix/20_turn_closeout_analysis.md)

## 当前冻结结论

### 1. 问题不是协议误报 ticket 完成

当前已确认：

- 下游 `codex app-server` 发出的是真实的 `turn/completed`
- 本地 `AppServer` 没有自己脑补完成
- 真正的问题是上层把 turn 级完成过早解释成健康的 run 边界

### 2. 主修点不在 `app_server.ex`

`app_server.ex` 的职责应保持在：

- 接收协议层 `turn/completed`
- 表达 turn 级结束

这个文件可以改日志、命名和人类可见语义，但不应承担 run 结束判定。

### 3. 主修点在 `agent_runner.ex`

当前冻结判断：

- 真正该拦的是 `turn_completed -> run_completed`
- 不能让 active issue 下的 `turn_completed` 自动升级成健康 run 完成
- 需要为“错误收口”引入本地派生分类，例如 `premature_turn_end`

### 4. `orchestrator.ex` 不能简单删 continuation

当前冻结判断：

- 外层 continuation 不只是误续跑放大器
- 它当前还承担 `agent.max_turns` 打满后，继续 active ticket 的合法职责

所以后续实现不能只做“砍 continuation”，而必须保住这条合法路径。

### 5. 结构化 run 终态不能只靠改返回值

当前冻结判断：

- `Orchestrator` 当前只直接拿到子进程 `:DOWN` reason
- 它不会直接消费 `AgentRunner.run/3` 的普通返回值

所以后续如果要引入：

- `run_completed`
- `run_blocked`
- `premature_turn_end_limit`

这类 run 级终态，必须连同结果上报机制一起设计。

## 当前不冻结为既定事实的部分

下面这些方向可以讨论，但当前还不能当作已经证实的实现事实：

### 1. `allowed_exit?` 的具体判定面

当前只能确认：

- 方向是对的
- 现有代码库没有现成的 closeout 聚合判定

但还没有最终定稿：

- 由谁负责 closeout 判定
- 判定输入有哪些
- 评论 / body / workpad 回读如何做

### 2. 首轮 prompt policy 的最终归属点

当前只能确认：

- 首轮 prompt 也需要补“禁止过早结束”的约束

但还没有最终定稿：

- 约束放在 `PromptBuilder` 代码里
- 还是放在 workflow prompt 模板 / 默认 prompt 配置里

### 3. `premature_turn_end` 的最终命名

当前只能确认：

- 需要一个独立于 crash / timeout / success 的本地派生分类

但名字本身还不是冻结接口。

## 后续实现范围

如果后续要开实现卡，建议范围只覆盖下面这些点：

1. turn 级完成与 run 级完成的语义拆层
2. active issue 下的 run 结束闸门
3. 错误收口的本地派生分类
4. `AgentRunner` 到 `Orchestrator` 的 run 级结果传递
5. 保住 `max_turns` 之后的合法 continuation

## 明确不在本卡范围内

后续实现时，默认不把下面这些内容混进来：

1. 多项目 Control Plane 新功能
2. Project Worker 生命周期管理扩展
3. Web 页面新功能
4. Trace / RawEventStore 方案
5. Workflow 模块化生成
6. 与本问题无关的 Linear 评论工作流改造
7. 大规模 prompt 系统重构

## 后续实现前必须再次确认的前提

后续真正开始写代码前，应再次确认：

1. 当前主线是否已有其他执行链改动进入
2. `AgentRunner` 与 `Orchestrator` 的结果传递准备怎么落
3. closeout 判定输入从哪里来
4. 本轮是否会触碰单项目核心执行链，从而提升到 `L2 - 全量验证`

## 给后续执行者的一句话

后续实现不要从“改日志”开始思考，也不要从“砍调度器 continuation”开始思考。

正确入口是：

- 先定义 turn 级和 run 级的边界
- 再决定 run 级终态如何从 `AgentRunner` 传给 `Orchestrator`
- 最后再收敛 active issue continuation 的去留
