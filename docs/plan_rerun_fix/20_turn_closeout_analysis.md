# Symphony `turn/completed` 与错误续跑分析结论

日期：2026-05-04  
仓库：`/home/ssss/projects/powersymphony`  
对应事项：`M1-6 / C-21`  
结论性质：只读分析，不含代码修改

## 目标

把这次现象彻底讲清楚：

- 为什么同一张 Linear ticket 会从第 1 轮续跑到第 7 轮
- 为什么 `app-server` 会收到结束信号
- 到底是谁把“这一轮结束”解释成了“可以继续下一轮”
- 后续在 `M1-6` 里真正该改哪里、为什么改

## 一句话结论

这次问题不是 `app-server` 错把工单标成完成，也不是调度器瞎猜结束。

真实链路是：

1. 下游 `codex app-server` 发出协议事件 `turn/completed`
2. 本地 `AppServer` 把它当成“当前 turn 成功结束”
3. `AgentRunner` 把这个 turn 成功直接升级解释成“本次 run 可以继续进入 active-state continuation 判断”
4. 因为 issue 仍在 active state，于是连续续跑下一 turn
5. 外层 `Orchestrator` 还会对 worker 正常退出再做一次 continuation check

所以根因不是单点 bug，而是两个边界混了：

- `Codex turn` 的结束边界
- `Linear ticket` 的结束边界

## 已确认的事实

### 1. `turn/completed` 不是本地 Elixir 猜出来的

文件：`/home/ssss/projects/powersymphony/elixir/lib/symphony_elixir/codex/app_server.ex`

关键代码：

- `Port.open(...)` 启动外部 `codex app-server`
- 本地通过 `stdio` 上的 JSON-RPC 与它通信
- 收到 `{"method": "turn/completed"}` 时，返回 `{:ok, :turn_completed}`

对应位置：

- [app_server.ex](/home/ssss/projects/powersymphony/elixir/lib/symphony_elixir/codex/app_server.ex:91)
- [app_server.ex](/home/ssss/projects/powersymphony/elixir/lib/symphony_elixir/codex/app_server.ex:107)
- [app_server.ex](/home/ssss/projects/powersymphony/elixir/lib/symphony_elixir/codex/app_server.ex:368)

这说明：

- `AppServer` 只有在下游真的发来 `turn/completed` 时，才认为当前 turn 成功结束
- 如果收不到，它会继续等，或者走超时/错误分支

### 2. `Codex session completed` 只是 turn 级日志

文件：`/home/ssss/projects/powersymphony/elixir/lib/symphony_elixir/codex/app_server.ex`

当前日志：

- `Codex session completed for ...`

对应位置：

- [app_server.ex](/home/ssss/projects/powersymphony/elixir/lib/symphony_elixir/codex/app_server.ex:109)

这条日志的真实含义是：

- 当前这一个 turn 正常结束了

它不表示：

- 整个 agent run 完成
- 整个 Linear ticket 完成

### 3. 真正把 turn 成功升级成 run continuation 的是 `AgentRunner`

文件：`/home/ssss/projects/powersymphony/elixir/lib/symphony_elixir/agent_runner.ex`

当前逻辑：

1. `AppServer.run_turn(...)` 成功返回
2. 立即记一条 `Completed agent run ... turn=N/20`
3. 立即调用 `continue_with_issue?`
4. 如果 issue 仍 active，则直接续下一轮

对应位置：

- [agent_runner.ex](/home/ssss/projects/powersymphony/elixir/lib/symphony_elixir/agent_runner.ex:95)
- [agent_runner.ex](/home/ssss/projects/powersymphony/elixir/lib/symphony_elixir/agent_runner.ex:102)
- [agent_runner.ex](/home/ssss/projects/powersymphony/elixir/lib/symphony_elixir/agent_runner.ex:104)
- [agent_runner.ex](/home/ssss/projects/powersymphony/elixir/lib/symphony_elixir/agent_runner.ex:135)

这就是本次错误续跑的第一现场。

### 4. 外层 `Orchestrator` 还会对正常退出再做 continuation check

文件：`/home/ssss/projects/powersymphony/elixir/lib/symphony_elixir/orchestrator.ex`

当前逻辑：

- worker `:normal` 退出时
- 记 `Agent task completed ... scheduling active-state continuation check`
- 然后调用 `schedule_issue_retry(... delay_type: :continuation)`

对应位置：

- [orchestrator.ex](/home/ssss/projects/powersymphony/elixir/lib/symphony_elixir/orchestrator.ex:133)
- [orchestrator.ex](/home/ssss/projects/powersymphony/elixir/lib/symphony_elixir/orchestrator.ex:135)

这说明系统有两层 continuation：

1. `AgentRunner` 内层 turn continuation
2. `Orchestrator` 外层 run continuation

### 5. 官方公开资料与本地实现一致

已核对资料：

- [Unlocking the Codex harness](https://openai.com/index/unlocking-the-codex-harness/)
- [An open-source spec for Codex orchestration: Symphony](https://openai.com/index/open-source-codex-orchestration-symphony/)
- [Introducing Codex](https://openai.com/index/introducing-codex/)

核对结果：

- `turn/completed` 的确是 turn 级完成信号
- Symphony 官方规范的确是“turn 正常结束后，如果 issue 仍 active，则继续下一 turn”
- worker 正常退出后，外层也会再做 continuation check

所以这不是本地私货，也不是偶发误判，而是现有架构默认行为。

## 对这次现象的准确解释

### 1. 为什么会看到“这一轮结束”

因为对面的 `codex app-server` 真的发来了 `turn/completed`。

本地并没有凭“停了一下”就脑补结束。

### 2. 为什么业务上没做完，协议层却结束了

因为系统并没有把“ticket 还没闭环”建模成“当前 turn 必须继续保持打开”的硬状态。

协议层只知道：

- 当前这一轮已经到了一个终态
- 终态类型是 `turn/completed`

而不知道：

- Linear closeout 还没做
- 只是阶段性汇报
- 还没 blocker closeout

### 3. 为什么会从第 1 轮滚到第 7 轮

因为当前内层逻辑近似等于：

1. 这一轮 turn 成功结束了吗
2. 是
3. issue 还 active 吗
4. 是
5. 那就继续下一轮

所以只要：

- turn 一次次成功结束
- issue 没及时切到 non-active

它就会一直滚。

## 不是根因的东西

下面这些都不是第一现场根因：

- 不是子代理一结束，主线程就被误杀
- 不是调度器无缘无故乱猜结束
- 不是 `turn/completed` 协议事件本身设计错了
- 不是单纯“日志文案有点歧义”这么轻

真正的问题是：

- `turn/completed` 被上层过早升级成了一个健康的 run 边界

## 最终责任划分

### `app_server.ex`

职责应该仅限于：

- 接收协议层 `turn/completed`
- 表达“当前 turn 结束”

它不应承担：

- 判断 run 是否可结束
- 判断 issue 是否该继续

所以这个文件的主问题是：

- 日志和对外表达过于模糊，把 turn 级完成说成了像 session/task 完成

### `agent_runner.ex`

这是本次修复的主战场。

它当前的问题是：

- 直接把 `turn_completed` 视为健康的 run 结束边界
- 然后立刻按 active issue 继续下一 turn

更准确地说，真正该拦的是：

- `turn_completed -> run_completed`

这次升级，而不是事后去否认 turn 已结束。

但这里有一个实现前提必须先说清：

- 当前 `AgentRunner` 的返回值不会被 `Orchestrator` 直接拿到
- 外层现在是通过 `Task.Supervisor.start_child(...)` 启动子进程，再用 `Process.monitor` 只看 `:DOWN` reason
- 所以如果要引入结构化的 run 终态，不能只改 `AgentRunner.run/3` 的返回 tuple，必须同时设计结果上报机制

### `prompt_builder.ex`

它不是根因层，但会影响发生概率。

当前 prompt 对“active issue 下禁止过早结束 turn”的约束不够硬，导致模型更容易把阶段性汇报当成当前 turn 的收口点。

但要注意：

- `PromptBuilder` 当前主要负责渲染 `Workflow.current()` 提供的 prompt 模板
- 首轮 prompt policy 的真实所有权，不一定在这个模块本身，更可能在 workflow prompt 模板或默认 prompt 配置
- 所以这里更像是首轮 prompt 约束的接入点，而不一定是唯一策略归属点

### `orchestrator.ex`

这是第二层放大器。

即使 `AgentRunner` 内部做了一部分修复，如果外层还把所有 `:normal` 退出都当成 continuation 候选，仍会留下误续跑空间。

但也不能把外层 continuation 简单当成纯副作用，因为它当前还承担一个合法职责：

- 当单次 `AgentRunner` 已经打满 `agent.max_turns`，但 issue 仍 active 时，控制权会回到外层
- 然后由 `Orchestrator` 再次安排 continuation retry

所以这个文件的真实问题不是“外层 continuation 不该存在”，而是“外层 continuation 现在不知道本次 `:normal` 退出到底是健康完成、错误收口，还是只是打满单次 turn 配额”。

## 对各类意见的综合判断

### 可以确认成立的部分

1. `turn/completed` 不能再被人类或上层日志理解成“任务完成”
2. `turn_completed`、`run_completed`、`ticket_completed` 必须严格分层
3. 调度器应尽量简单，主要还是看 issue 状态
4. 真正该加闸门的是 `AgentRunner`
5. `premature_turn_end` 应该作为 Symphony 本地派生状态引入
6. `premature_turn_end` 应与 `turn_timeout` / `turn_failed` / `port_exit` 分开处理

### 需要收紧表述的部分

1. 不能说“禁止 turn 结束”

更准确的说法是：

- turn 一旦收到 `turn/completed`，协议层已经结束
- 真正能做的是：禁止把这个 turn 完成升级成合法的 run 完成

2. 不能把 `premature_turn_end` 说成协议原生事件

更准确的说法是：

- 协议原生事件还是 `turn/completed`
- `premature_turn_end` 是 Symphony 编排层自己的解释和分类

3. 不能把主修点放在 `app-server`

更准确的说法是：

- `app_server.ex` 主要改语义表达
- `agent_runner.ex` 才是行为主修点
- `orchestrator.ex` 是续跑放大器，必须同步收紧

4. 不能把 `allowed_exit?` 写得像是现成就能判

更准确的说法是：

- 当前代码库已有 `Tracker.create_comment/2`、`Tracker.update_issue_state/2`、`Tracker.fetch_issue_states_by_ids/1`
- 所以 `AgentRunner` 并非完全做不到 closeout 写入和部分回读
- 但当前没有现成的“closeout 已完成”聚合判定，也没有评论 / body / workpad 的完整回读确认面
- 因此 `allowed_exit?` 的方向成立，但落地前必须先补齐判定输入与 owner

## 最终修复结论

### 实现前提

明天如果进入实现，先不要直接按“改 4 个文件”开工，还要先承认下面 3 个前提：

1. `Orchestrator` 当前只拿子进程 `:DOWN` reason，不直接消费 `AgentRunner` 返回值。
2. 当前 tracker 能写评论、改状态、按 id 刷 state，但没有现成的 closeout 聚合判定与完整回读确认面。
3. 外层 continuation 目前既是误续跑放大器，也是 `max_turns` 之后延续 active ticket 的合法机制。

明天真正要改的，是以下四处。

### 1. `app_server.ex`

目标：

- 只表达 turn 级完成
- 去掉模糊的“session completed”观感

应改：

- 把 `Codex session completed` 改成明确的 turn 级日志，例如 `Codex turn completed`
- 保留 `turn/completed` 的接收逻辑
- 若有人类可见但语义模糊的 telemetry / event / dashboard 文案，统一改成 `turn_completed` 或等价的 turn 级表达

### 2. `agent_runner.ex`

这是第一优先级。

应改：

- 新增 turn 结束后的分类闸门
- 不再让 `turn_completed` 自动升级成 `run_completed`
- 对 active issue 做 `allowed_exit?` 或等价分类
- 未满足合法结束条件时，归类为 `premature_turn_end`
- 在内部 continuation 中维护 `premature_turn_end_count`
- 连续达到阈值后熔断，不再无限续跑
- 只有真正合法结束时，才打印 `run completed` 语义日志
- continuation prompt 补上更强的“禁止过早结束”约束
- 同时设计把 run 级终态传出 `AgentRunner` 的机制，而不是只改函数返回值

### 3. `prompt_builder.ex`

目标：

- 把“active issue 下禁止过早结束 turn”的规则补进第 1 轮 prompt 入口

原因：

- `agent_runner` 的 continuation prompt 只覆盖第 2 轮以后
- 第 1 轮也必须具备同样约束
- 但真正需要修改的内容，可能位于 workflow prompt 模板或默认 prompt 配置，而不一定只在 `PromptBuilder` 模块代码里

### 4. `orchestrator.ex`

这是第二优先级。

应改：

- 不再把所有 `:normal` 退出都视为“可以 continuation check”
- 改为根据 `AgentRunner` 上报的结构化 run 终态决定后续动作
- 外层尽量只看 run 级终态和 issue 状态，不再误把 turn 级收口放大
- 同时保留 `max_turns` 打满后继续 active ticket 的合法续跑能力

## 建议的返回协议

`AgentRunner` 与 `Orchestrator` 之间不应继续只靠裸 `:ok` / `:error`。

但这里必须强调：这不是单纯的函数返回值设计，而是进程间结果传递协议设计。

建议至少结构化为：

```elixir
{:ok, :run_completed}
{:ok, :run_blocked}
{:ok, :stopped_issue_inactive}
{:error, :turn_timeout}
{:error, :turn_failed}
{:error, {:premature_turn_end_limit, count}}
```

这样外层才能正确区分：

- 健康完成
- 合法阻塞结束
- issue 外部已非 active
- 真失败
- 错误收口熔断

如果不先解决“结果怎么从 `AgentRunner` 传给 `Orchestrator`”，这一节只是目标形态，不是可直接落地的代码改动。

## 测试建议

### `agent_runner` 测试

至少覆盖：

1. active issue + `turn_completed` + 未满足结束条件  
   结果应继续内部 turn，而不是 `run_completed`

2. active issue + 连续 2 次 `premature_turn_end`  
   结果应熔断，不再无限续跑

3. issue 已变成 non-active  
   结果允许正常结束

4. blocker closeout 完成  
   结果允许结束

### `orchestrator` 测试

至少覆盖：

1. `run_completed` 不再被当成 turn 级 continuation 的默认触发器
2. `run_blocked` 不应再次自动调度
3. `premature_turn_end_limit` 应走收敛路径，而不是反复 retry
4. crash / timeout 仍按失败重试路径走

## 最后的总判断

这次问题可以概括成一句话：

**不是协议发错了完成信号，而是 Symphony 把 turn 级完成过早解释成了一个健康的 run 边界。**

因此真正的修复原则是：

1. 把 `completed` 的语义彻底拆层
2. 把 `turn_completed -> run_completed` 的升级路径加上硬闸门
3. 把错误收口单列为 `premature_turn_end`
4. 把 turn 级续跑留在 `AgentRunner` 内部收敛
5. 让 `Orchestrator` 只处理更粗的 run 级结果，同时保住 `max_turns` 之后的合法续跑

按这个方向改，才能同时满足：

- 调度器仍然尽量简单
- 卡死和异常仍然能抓
- 真 blocker 仍然能正常停
- 错误的反复轮询显著减少
