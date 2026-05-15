# C-50 Ownership Gate Design

## Goal

把 `C-50 / M3 紧急修复：错误多开线程` 收敛成一条可验证的控制面 correctness contract：

- 在单个健康 orchestrator 实例内，同一 `issue_id` 在 ownership 未明确释放前，绝不允许并发多跑两个活 worker。
- 单个 worker 生命周期内，连续 turn 继续复用同一个 Codex thread。
- 当系统无法确认旧 owner 是否已经安全结束时，优先保守持有 claim 或降级为 blocked claim，不乐观重派发。

本卡不把目标定义成“永远不再出现第二个 Codex thread”。现有架构和当前协议能力不足以对跨 worker、跨进程、跨重启场景给出这个承诺。

## Scope Interpretation

### In Scope

- 为每次 dispatch attempt 引入稳定的 `run_instance_id` / generation。
- 修正 stall / stop 路径的 ownership 释放时机，消除“先放权、后确认远端是否结束”的 split-brain 窗口。
- 给 worker 增加协作式 stop 协议，让 orchestrator 能先请求当前 turn interrupt，再决定是否释放 gate。
- 把 `RunTrace` / `RunStateStore` / snapshot 的 `session_id`、`thread_id`、`turn_id` 约束到同一 generation，禁止跨代混拼。
- 补齐高风险回归测试，覆盖 stall、stale update、interrupt、summary generation mismatch。

### Out of Scope

- 不承诺跨 worker 恢复时继续复用原 thread。
- 不承诺 orchestrator 进程重启后恢复旧 ownership。
- 不新增“全局远端线程注册中心”或“远端 thread 扫描器”。
- 不把 snapshot / dashboard 升格为 ownership 真相来源。
- 不在本轮实现持久化 lease / fencing token。

## Confirmed Current State

### 1. 当前 split-brain 窗口是真实存在的

- `restart_stalled_issue/5` 在命中 stall 后会先 `terminate_running_issue(issue_id, false)`，再 `schedule_issue_retry(...)`。
- `terminate_running_issue/3` 会直接删掉 `running`、`claimed`、`blocked_claims`、`retry_attempts`。
- `should_dispatch_issue?/6` 只依赖本地 `claimed/running`，不看远端 thread 是否仍活着。

所以，只要旧 worker 的远端 thread 还没真正停掉，本地就已经允许新 attempt 重新 dispatch。

### 2. 当前 worker 生命周期内可以复用 thread，但跨 worker 不行

- `AgentRunner.run_codex_turns/5` 先 `AppServer.start_session(...)`，之后在同一 session 上连续 `run_turn`。
- `AppServer.start_session/2` 当前固定使用 `thread/start`，并把 `thread_id` 绑在当前 app-server session 上。

这说明：

- 单 worker 多 turn 复用同一 thread 已经成立。
- worker 一旦退出，下一次 attempt 默认只能新开 thread，不能把“resume old thread”当成本轮修复前提。

### 3. `stop_session/1` 现在只关本地 port

`AppServer.stop_session/1` 当前只 `stop_port(port)`。它不会主动发送 `turn/interrupt`，也没有可靠的远端 stop / close / ack 流程。

### 4. 观测层当前允许跨代混拼

- `RunStateStore.summary_for_running_entry/2` 会把 raw events reducer 结果和 running entry 元数据混合归并。
- orchestrator snapshot 里 `thread_id/turn_id` 来自 summary，但 `session_id` 直接取 `metadata.session_id`。

只要同一条 trace 或 running entry 里混入不同 attempt 的字段，UI 就能展示出“同一行里 session 属于老代、thread/turn 属于新代”的假现场。

### 5. 协议层现状决定了本轮要走保守修复

通过本机 `codex app-server generate-json-schema` 校验，当前协议层明确存在：

- `turn/interrupt`
- `thread/resume`

但当前仓库的 app-server client 只实现了：

- `thread/start`
- `turn/start`

没有现成的远端 close / stop 收口，也没有现成的 orchestrator-level resume 路径。因此本轮应优先实现：

- 协作式 interrupt
- generation 隔离
- gate 延迟释放

而不是把目标膨胀成“跨 worker thread continuity”。

## Correctness Contract

本轮修复完成后，系统只对下面五条合同负责：

1. 在单个健康 orchestrator 实例内，同一 `issue_id` 任一时刻最多只有一个被当前进程承认的 active owner。
2. owner 一旦建立，直到满足 release condition 前，不得重新 dispatch 同一 `issue_id`。
3. release condition 只能是：
   - issue 已 terminal；
   - issue 已不再属于 active candidate；
   - worker 正常完成且本次生命周期已收口；
   - 协作 stop 已拿到足够的“当前 turn 已收口”证据。
4. 单个 owner 生命周期内，连续 turn 必须复用同一个 app-server thread。
5. 当系统无法确认旧 owner 是否已经安全结束时，必须退化为“继续持有 claim / 转 blocked claim / 等待人工或状态重检”，而不是乐观新开 attempt。

## Design Decision

### 1. 用 `run_instance_id` 给每次 dispatch attempt 加代际边界

每次 `dispatch_issue(...)` 接受一个 issue 时，都生成新的 `run_instance_id`，并把它贯穿到：

- `state.running[issue_id]`
- `retry_attempts[issue_id]`
- `blocked_claims[issue_id]`
- `worker_runtime_info`
- `codex_worker_update`
- `agent_run_result`
- `RunTrace` normalized events
- `RunStateStore` summary 过滤

这条 generation 是本轮真正的 fencing key。它不是远端 `thread_id`，因为 `thread_id` 是远端分配值，且跨 worker 不稳定；它也不是 `session_id`，因为 `session_id` 只有 turn 启动后才可得。

### 2. 把“停 worker”与“释放 dispatch gate”拆成两个阶段

当前 `terminate_running_issue/3` 把这两件事混在了一起。本轮改成：

- `request_running_issue_stop(...)`
  - 保留 `running` 和 `claimed`
  - 标记 `release_state`
  - 向 worker 发协作 stop 请求
  - 启动 grace deadline timer
- `finalize_running_issue_release(...)`
  - 只在满足 release condition 时执行
  - 决定是 `release_issue_claim/2`、`schedule_issue_retry/4` 还是 `block_issue_claim/3`

这样 `should_dispatch_issue?/6` 无需引入远端查询，只要继续尊重本地 `running/claimed/blocked_claims` 即可防止同实例内双活。

### 3. stall 恢复改成“请求 stop -> 等收口 -> 再决定后续”

新的 stall 路径不再是：

- kill task
- 立刻删 claim
- 直接 schedule retry

而是：

1. orchestrator 命中 stall。
2. 对当前 running entry 标记 `release_state: :interrupt_requested`。
3. 向 worker 发送 interrupt 请求。
4. 等待下面两类结果之一：
   - worker 收到远端 terminal turn 事件后退出；
   - grace deadline 到期，仍无足够收口证据。
5. 再决定：
   - 若已经看到当前 turn 的 terminal 事件，则允许走 retry / recheck 路径；
   - 若没有看到足够证据，则转 `blocked_claim`，reason 记为 `:remote_stop_unconfirmed`，禁止自动 redispatch。

这是本轮最重要的“安全优先于活性”裁决。

### 4. 协作 stop 由 worker 内的 app-server receive loop 执行

orchestrator 不能直接调用当前 worker 内部的 `AppServer.stop_session(session)`，因为 session handle 只存在于 worker task 内。

因此 stop 协议应改成：

- orchestrator 向 worker pid 发送 `{:interrupt_codex_turn, run_instance_id, reason}`；
- worker 当前正阻塞在 `AppServer.receive_loop(...)`；
- `receive_loop` 捕获这条消息后，发送 `turn/interrupt(threadId, turnId)`；
- 继续等待 `turn/cancelled`、`turn/completed`、`turn/failed`、port exit 等终态事件；
- 把终态事件作为“当前 turn 已收口”的证据回传给 orchestrator。

这要求：

- `AppServer.run_turn/4` 把当前 `thread_id` / `turn_id` 传进 `receive_loop`；
- `receive_loop` 增加 interrupt 分支；
- `AgentRunner` 给所有 update / result 带上当前 `run_instance_id`。

### 5. 对 timeout 和异常退出一律做 generation-aware 收口

如果 worker 在 `release_state` 挂起期间直接退出：

- 已看到 terminal turn 证据：
  - 可按 issue 当前状态继续 `retry`、`checking_recheck` 或 `release`
- 未看到 terminal turn 证据：
  - 不允许乐观 retry
  - 转成 `blocked_claim(reason: :remote_stop_unconfirmed)`

这条规则同样适用于：

- stall 触发的 stop
- 人工 stop
- 协作 stop grace timeout 之后的强杀

### 6. summary 只消费当前 generation 的事件

本轮不把 trace 按 attempt 切文件，而是保留现有同 issue trace 的演进方式；但必须给 reducer 增加 generation 过滤：

- `EventNormalizer` 标准化事件时带上 `run_instance_id`
- `RunStateStore.summary_for_running_entry/2` 仅 reduce 当前 running entry 的 generation 事件
- 同时 orchestrator `integrate_codex_update` 把当前 generation 的 `session_id/thread_id/turn_id` 落回 running entry
- snapshot 同一行的 `session_id/thread_id/turn_id` 必须全部来自同一 generation

这样可以修掉“同一条 trace 内多代 attempt 共存”造成的混拼问题，而不需要推倒 C-36 的 run trace 设计。

### 7. 继续把 blocked claim 当作“不确定 ownership 已释放”的保守收口器

当前系统已经有一条成熟的 blocked claim 语义：

- claim 保持占有
- 不再 dispatch
- 继续通过 tracker 状态重检来判断能否释放

本轮新增的 `:remote_stop_unconfirmed` 可以直接复用这条机制，而不必平地起一个新的全局 lease 子系统。

## State Machine Adjustment

### 正常完成

- running
- worker 正常退出
- issue 进入 terminal 或 active continuation 结束
- release / retry 与现有逻辑保持一致

### stall 命中

- running
- `release_state = :interrupt_requested`
- 发送 `turn/interrupt`
- 若看到 terminal turn 证据并 worker 退出：
  - 走正常 retry / recheck 收口
- 若 grace deadline 到期仍无证据：
  - 杀本地 task
  - 转 `blocked_claim(reason: :remote_stop_unconfirmed)`

### stop 请求后的 stale update

- 若 update 的 `run_instance_id` 不匹配当前 running entry：
  - 直接丢弃
  - 不更新 tokens / summary / session/thread/turn

### blocked claim 重检

- issue terminal 或不再 candidate：
  - 释放 claim
- issue 仍 active：
  - 保持 blocked claim

## Compatibility With Ongoing Mainline Work

### 保持不变的边界

- “一个 worker 生命周期内多 turn 复用同一 thread”的现有模型保持不变。
- `should_dispatch_issue?/6` 仍然是本地状态判定，不引入实时远端查询。
- dashboard / presenter 继续消费 orchestrator snapshot，不直接触碰 ownership 逻辑。

### 本轮新增边界

- 任何读取当前运行身份的代码都应走 running entry / summary 的统一字段，不再假设裸 `metadata.session_id` 就是完整真相。
- 任何决定“是否可以再次派发”的代码都必须走 orchestrator 的统一 gate，不得绕过 `claimed/running/blocked_claims`。

## Test Strategy

必须补的高风险测试：

1. `AppServer`：
   - worker 收到 interrupt 消息后会发送 `turn/interrupt`
   - `turn/cancelled` 能被正确转成 terminal result
2. `Orchestrator`：
   - stall 命中后不立即释放 claim，不立即 schedule retry
   - grace timeout 后进入 `blocked_claim(reason: :remote_stop_unconfirmed)`
   - stale generation update 不会污染当前 running entry
3. `RunStateStore`：
   - 同一条 trace 里混有老代、新代事件时，只归约当前 generation
   - `session/thread/turn` 不再跨代混拼

本地验证只跑定向测试，不跑 `make all`。

## Remaining Limits After This Card

本轮修完后，仍然不能严格保证：

- orchestrator 进程重启后不发生旧 owner 遗失；
- SSH / 远端链路异常下远端 thread 一定已经停止；
- 外部绕过 orchestrator 的 thread 启动路径被自动拦住；
- 跨 worker 生命周期继续复用原 thread。

这几类问题需要下一层抽象：

- durable lease / fencing
- app-server resume / close 协议接入
- 多实例或重启后的 orphan recovery

本轮不把它们伪装成“已经解决”。
