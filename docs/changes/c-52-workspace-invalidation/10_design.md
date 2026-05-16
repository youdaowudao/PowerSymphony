# C-52 Workspace Lifecycle Fencing Design

## Goal

把 `C-52` 收敛成一条“先修资源生命周期 fencing，再补 invalidation 语义”的保守修复，而不是再发明第二套 owner 系统，也不是把 marker 当主修复。

本轮设计只对下面五条合同负责：

1. workspace 资源必须有可校验的 run generation 归属。
2. cleanup 删除前必须有 generation-aware 的资源确认。
3. 删除前必须拿到足够的 run 终态证据，或退回保守不删。
4. 所有 terminal cleanup side-path 必须统一走同一条 cleanup fencing contract。
5. invalidation record、per-turn gate、错误翻译只能建立在前四条之上。

## Confirmed Current State

### 1. 已有控制面不该重复发明

当前主线已经有：

- `claimed / running / blocked_claims`
- `run_instance_id`
- `current_generation?/2`
- `turn/interrupt`
- `blocked_claim(reason: :remote_stop_unconfirmed)`

因此本轮不新增第二套 owner arbitration，也不新增另一条 generation 体系。

### 2. 消息 generation 已受保护，workspace 资源 generation 没有

当前 `run_instance_id` 已用于：

- orchestrator 当前代消息过滤
- run trace 事件归并
- stalled run cooperative stop

但 workspace 路径仍只由 `safe_identifier(identifier)` 决定，目录存在就直接复用。

所以当前系统有：

- message generation fencing

没有：

- resource generation fencing

### 3. cleanup side-path 都共享同一个粗粒度删目录模型

当前至少有四条 terminal cleanup 路径：

- `terminate_running_issue/3`
- `run_terminal_workspace_cleanup/0`
- `handle_terminal_retry_issue/4`
- `release_terminal_blocked_claim_issue/2`

它们的共同点是：

- 看 issue terminal
- 按 `identifier` 定位目录
- 不证明当前目录仍属于旧 run

### 4. 停机确认当前不够强

stalled path 已经能请求 cooperative interrupt，但：

- `AppServer.stop_session/1` 只做 `Port.close`
- 当前没有统一的“底层 terminal/app-server 已可靠退出”的终态确认链

所以“先 stop 再 delete”本身还不够，必须明确定义 stop 证据。

## Design Decision

### 1. 主修复不是 invalidation record，而是 workspace resource binding

本轮首要任务不是“写一个 marker”，而是给 workspace 资源补上一层与 `run_instance_id` 对应的资源绑定关系。

这个绑定关系至少要支持回答两件事：

1. 当前这个 workspace 是否仍属于旧 run
2. 新 run 是否已经接管了同一路径

没有这层绑定，后续所有 invalidation 语义都不稳。

### 2. resource binding 需要与物理 workspace 生命周期一起更新

当前 workspace 是按 issue 固定复用的，所以 binding 不能只依赖 issue identifier。

binding 至少要和下面这些状态变化同步：

- `Workspace.create_for_issue/2` 首次创建
- 复用已有 workspace 并由新 run 接管
- retry 沿用旧路径继续运行
- cleanup 进入 closing
- cleanup 完成物理删除

也就是说，binding 不是一条“额外日志”，而是资源生命周期的一部分。

### 3. cleanup fencing 分成三个阶段

#### 阶段 A：声明 closing

- 标记该 workspace 资源正在被某个旧 `run_instance_id` 收口
- 该标记必须能和资源 binding 对应上
- 若当前 binding 已不再属于旧 run，则 cleanup 必须立即放弃物理删除

#### 阶段 B：收集 stop 证据

- 对 running path，优先复用现有 cooperative interrupt 通道
- 对 startup sweep / retry / blocked-claim 路径，必须先确认该资源当前没有被 live run 占有
- stop 证据至少要回答：
  - worker task 是否退出
  - 当前 app-server / terminal 是否已终止
  - 当前 binding 是否仍属于旧 run

若证据不足：

- 不删除资源
- 保持或转入保守状态，例如 blocked / needs-manual-reap

#### 阶段 C：generation-aware delete

- 只有在 binding 仍然指向旧 run，且 stop 证据满足时，才允许物理删除
- 删除完成后，再把 binding 和辅助 invalidation 语义推进到终态

### 4. startup sweep 必须降级成“reap candidate”而不是盲删器

当前 startup terminal sweep 最危险，因为它天然缺 live in-memory 上下文。

因此本轮设计里，startup sweep 不应继续扮演“看到 terminal issue 就直接删目录”的角色。
更安全的方向是：

- 先读取资源 binding
- 仅处理无 live owner、且 binding 已明确可回收的目录
- 遇到 live / uncertain / stale-but-ambiguous 状态时，保守跳过并记录

### 5. AppServer 不负责 owner 裁决，只负责配合 gate 与错误翻译

owner / generation 裁决更自然的边界在：

- orchestrator
- AgentRunner

`AppServer` 本轮只负责两件事：

1. 配合 `AgentRunner` 在 turn 启动前接受资源有效性结论
2. 在已有 invalidation / resource-closing 证据时，把底层路径错误翻译成 lifecycle 错误

这样可以避免把第二套 owner 真相塞进 `AppServer`。

### 6. per-turn validity gate 是配套防线，不是主修复

本轮仍然要做 per-turn gate，但它应建立在资源 binding 已存在的前提上。

它要回答的是：

- 我当前要碰的这个 workspace 资源是否仍属于我
- 它是否已经进入 closing / invalidated

而不是在没有资源 binding 的前提下，靠猜测去做 owner 判断。

### 7. invalidation record 降级为辅助机制

本轮不删除 invalidation record 这个想法，但要降级它的职责。

它适合承担的职责是：

- 用户可读语义
- 错误翻译依据
- 事故排查证据

它不适合承担的职责是：

- 作为唯一的 resource ownership 证明
- 代替 cleanup fencing
- 代替 run 终态确认

### 8. local 与 remote worker 路径必须统一语义

本轮 contract 不能只对本地文件系统成立。

需要同样覆盖：

- `Workspace.remove/2` 本地路径
- `Workspace.remove/2` remote SSH 路径
- startup terminal sweep
- remote `before_remove`

否则同类 bug 只会从本地消失，转移到 remote worker。

## Scope Boundary

### In Scope

- workspace resource binding
- cleanup fencing 三阶段协议
- stop 证据与保守不删分支
- startup / running / retry / blocked-claim cleanup 统一 contract
- `AgentRunner` 层 validity gate
- `AppServer` 层辅助错误翻译
- invalidation record 作为辅助语义

### Out of Scope

- 全局跨进程 owner ledger
- distributed lock / lease / fencing subsystem
- incident 中“第二顶层线程是否存在”的最终裁决
- 全量 dashboard / UI 重构

## Primary Risks To Control

1. 旧 cleanup 按 `identifier` 误删新 run workspace
2. stale resource-binding 或 stale invalidation record 污染新 run
3. resource binding 与现有 `claimed/blocked_claims` 打架，形成双真相源
4. 终态证据要求过强，导致资源永远回收不掉
5. 终态证据要求过弱，导致旧 race 仍在
6. 过度翻译错误，把普通基础设施故障误报成 invalidation
7. `before_remove` hook 在 closing 阶段继续扩大 side effect

## Verification Strategy

本轮验证重点不是“多开线程”，而是 resource fencing contract：

1. 活跃 turn 未完成时，running terminal cleanup 不得直接抽走 cwd
2. startup sweep 不得无条件删掉已被新 run 接管的 workspace
3. retry / blocked-claim terminal cleanup 与 running terminal cleanup 统一服从相同的 binding + closing 判定
4. cleanup 无法确认旧 run 已停干净时，必须保守不删
5. stale session 在 turn 前收到 lifecycle 错误，而不是底层路径错误
6. stale invalidation record 不会污染新 dispatch
7. local 与 remote worker 行为一致
