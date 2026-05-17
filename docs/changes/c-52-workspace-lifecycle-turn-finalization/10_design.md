# C-52 Workspace Lifecycle 与 Turn Finalization 设计

## 设计目标

这次设计只负责把 incident 中已确认的两条合同补齐：

1. `workspace lifecycle contract`
2. `turn finalization contract`

设计目标不是“再找一个更大的解释”，而是让当前已坐实的失败路径变成：

- 资源层面：旧 cleanup 不能误删新 run 仍在使用或已接管的 workspace
- turn 层面：continuation 不能建立在终态仍可能被回写的 provisional completion 上

## 已确认的当前事实

### 1. 现有 owner 控制面不能回退

当前主线已经有：

- `claimed / running / blocked_claims`
- `run_instance_id`
- generation 过滤
- cooperative `turn/interrupt`
- stop 未确认时进入 hold / blocked-claim 的保守路径

因此本轮不能：

- 放松 ownership gate
- 重开“旧 owner 未确认结束前乐观 redispatch”
- 再造第二套 owner registry

### 2. workspace 资源合同与 turn terminal 合同都还没闭环

当前仓库已经不是“完全没有任何 lifecycle 结构”：

- `Workspace` 已有 resource binding / invalidation 文件
- cleanup 也已经出现 `closing` / `removed-pending` 语义
- `AgentRunner` 在每轮 turn 前也已做一次 workspace owner 验证

但两条合同都还不够强：

- `workspace lifecycle`
  - side-path cleanup 的删目录证据链不够统一、不够闭环
  - startup sweep 天生缺 live in-memory 上下文，更容易误判
- `turn finalization`
  - `AppServer` 目前在第一次看到 `turn/completed` 时就返回成功
  - `AgentRunner` 会立即基于 issue state 决定 continuation
  - 晚到 `turn/cancelled` / `turn_aborted` 仍可能把同一 turn 回写成冲突终态

## 设计原则

### 1. 一套 owner 真相源，两条从属合同

owner 真相源继续由 orchestrator 控制面承担：

- `claimed`
- `running`
- `blocked_claims`
- `run_instance_id`

`workspace lifecycle` 与 `turn finalization` 都是围绕这套真相源收紧边界，而不是跟它竞争。

### 2. 先修合同，再修语义外显

优先级固定为：

1. resource binding / cleanup fencing
2. turn finalization / continuation gate
3. invalidation record / 错误翻译 / dashboard 口径

不能倒过来做。

### 3. 保守不删、保守不续跑，优先于乐观继续

面对不确定状态时，本轮选择：

- workspace 方向：保守不删
- turn 方向：保守不 continuation

这是与 `C-50/C-52` 一致的风格，而不是回到“先继续，出事再说”。

## 方案总览

### A. Workspace Lifecycle

#### A1. 保留现有 binding 结构，补强它的合同地位

本轮不重新发明一套新的 workspace identity store，而是沿用当前 `.symphony-resource.json` / `.symphony-invalidation.json` 结构，明确：

- resource binding 是 workspace 资源层的主事实
- invalidation record 是辅助语义与诊断证据

binding 至少持续回答四件事：

1. 当前 workspace 属于哪个 `run_instance_id`
2. 当前 workspace 处于 `active / closing / removed-pending` 哪个阶段
3. 当前路径由谁持有
4. 当前路径是否已经被新 run 接管

它**不能**独立回答：

- 谁“有权”接管
- 谁是 owner 真相源
- 哪个 run 应当被重新 dispatch

这些授权判断继续由 orchestrator 的 owner gate 承担。

#### A2. cleanup 必须统一走“三阶段协议”

所有 cleanup side-path 统一收敛为：

1. `declare closing`
   - 标记旧 run 正在收口
   - 若 binding 已被新 run 接管，立即放弃删除
2. `collect delete evidence`
   - 证明旧 run 已停干净，且当前 binding 仍属于旧 run
   - 证据不足则保守不删
3. `generation-aware delete`
   - 删除前再次确认 binding 未被新 run 抢占
   - 删除后再推进 invalidation / removed-pending 语义

这里的重点不是“删得更快”，而是“删之前知道自己删的是谁的目录”。

#### A2.1 删除授权模型必须唯一

本轮先裁决为：

- 只有当前 cleanup 调用者所在的 orchestrator 路径，才能发起删除授权判断
- resource binding 只提供资源事实，不提供 owner 授权
- 删除授权必须同时满足：
  1. 当前 binding 仍指向待收口的旧 `run_instance_id`
  2. 当前看不到更新的 active binding 已被新 run 接管
  3. delete evidence 达到最低门槛

若任一条件不成立：

- 不删
- 不改写成乐观接管
- 回到保守路径

#### A2.2 delete evidence 的最低门槛

本轮不接受“拍脑袋 TTL 就删”或“只看 terminal issue 就删”。

最低 delete evidence 分两档：

1. `live evidence`
   - 当前 orchestrator 进程里能证明对应 running task 已退出，或 stop 已被确认收口
   - 且 binding 二次确认仍指向旧 run
2. `reap evidence`
   - 当前没有 live owner 上下文
   - 但 binding / invalidation / issue terminal 状态共同证明该目录仍处于旧 run 的 closing 或 removed-pending 残态
   - 且没有任何新 run takeover 迹象

`startup sweep` 只能消费 `reap evidence`，不能假装拥有 `live evidence`。

若 evidence 冲突或不足：

- workspace 保守不删
- 记录为 ambiguous reap candidate
- 等待后续再判，而不是当前强删

#### A3. startup sweep 改成 reap candidate，不再是盲删器

startup sweep 与 running cleanup 的关键区别是：

- 它没有当前进程里的 live owner 上下文
- 它更依赖磁盘上的 binding / invalidation 证据

因此 startup sweep 不能继续扮演“terminal issue 一扫就删”的角色，而应改成：

- 只处理已有明确 reap evidence 的 workspace
- 对 live / ambiguous / stale-but-uncertain 目录保守跳过并记录

#### A3.1 ambiguous workspace 的治理闭环

startup sweep 保守跳过不等于“永远不管”。

本轮要明确：

- ambiguous workspace 必须进入可再次判定的 reap candidate 集合
- 后续再次判定仍使用同一 contract，而不是旁路
- 若长期无法达成 delete evidence，需要有告警/人工介入口径，而不是逼出新的盲删逻辑

本轮不要求一次性做完整的后台回收系统，但必须把“跳过之后怎么继续”写清楚。

#### A4. local 与 remote worker 必须同构

本轮 contract 不能只在本地文件系统上成立。

需要保证以下入口语义一致：

- `Workspace.create_for_issue/2`
- `Workspace.cleanup_issue_workspace/2`
- `Workspace.remove/2`
- `before_remove` hook

remote SSH 路径如果只是“有差不多的行为”而不是“同一合同”，这个 bug 只会转移。

### B. Turn Finalization

#### B1. `turn/completed` 只能表示 provisional completion

本轮不再把第一次 `turn/completed` 直接等价成 finalized。

新的内部语义分层应是：

- `turn/completed`
  - 已看到流式完成
  - 但同一生命周期内仍可能晚到 cancel / abort
- `turn finalized`
  - 终态稳定，不再允许同一 turn 被回写成 conflict terminal

这个 `turn finalized` 可以是内部派生语义，不要求底层协议先显式提供新字段。

#### B1.1 `turn finalized` 的最小状态机

本轮先把内部判定规则固定为：

- `completed` 后进入 `settling`
- `settling` 期间若晚到：
  - `turn/cancelled`
  - `turn/failed`
  - 等价 `turn_aborted`
  则归并为 `conflict terminal`
- `settling` 期间若没有再收到冲突 terminal，且达到 settle 结束条件，则归并为 `finalized success`
- transport/stream 中断本身不自动等于 `conflict terminal`；需要单独走错误分类优先级

这里先固定语义，不在文档里预设具体毫秒数实现。

#### B2. `AppServer` 负责收敛终态冲突，不负责 owner 裁决

`AppServer` 的职责边界是：

- 继续负责 turn 流式协议消费
- 在看到 `turn/completed` 后，不立即把 turn 当作 finalized 成功返回
- 增加一个有限、保守的 terminal settle 流程，吸收晚到 `turn/cancelled` / `turn/failed`

如果 settle 期间出现冲突终态：

- 返回 `{:turn_cancelled, ...}` 或等价 premature terminal

如果 settle 结束且未见冲突：

- 返回 finalized success

`AppServer` 不负责：

- owner 判定
- continuation 决策
- orchestrator claim 管理

#### B2.1 settle 裁决规则

本轮需要提前固定四个验收语义：

1. 什么事件组合算 `finalized success`
2. 什么事件组合算 `conflict terminal`
3. settle 超时后统一去向是什么
4. 健康路径允许增加的 continuation 延迟上界是什么

这些必须在实现前写成稳定口径，避免后续各层自己发明解释。

#### B3. `AgentRunner` 只在 finalized success 后判断 continuation

`AgentRunner` 的 continuation 决策点必须后移：

- 当前：第一次 `turn/completed` 后就立即看 issue state
- 目标：只有 `AppServer` 返回 finalized success 后，才判断是否继续下一轮

这样 `late cancel after completed` 会自然落入：

- `handle_turn_error`
- `premature_turn_end`
- orchestrator 现有 hold / blocked-claim 收口路径

而不是进入“先续跑，再被晚到 interrupted 打脸”的状态。

#### B4. 不把 terminal conflict 误报成 network/transport failure

这条分支的输出语义也要收紧：

- terminal conflict 是 turn finalization 问题
- 不是 transport/network failure

因此这轮要补的不是更好看的“掉线文案”，而是更准确的错误归类与事件记录。

#### B4.1 错误分类优先级

本轮预设的分类优先级是：

1. 已有明确 lifecycle invalidation 证据
2. 已有明确 turn terminal conflict 证据
3. transport/network/SSH/bootstrap/path 故障

如果现场是复合故障：

- 允许内部双记账
- 但用户态主因必须按上述优先级稳定输出

不能把所有复合故障都一股脑翻译成 lifecycle 或 turn finalization。

## 分阶段实现裁决

### 第一阶段：Workspace Lifecycle

先做的内容：

- cleanup side-path 合同统一
- delete evidence 闭环
- startup sweep 降级成保守 reap candidate
- local / remote 一致性

先不做的内容：

- terminal settle 机制
- continuation 后移

理由：

- 如果资源层仍会抽走 cwd，turn 层调得再精细也会继续被底层路径错误噪声污染

第一阶段单独落地时必须保持的中间态不变量：

- 不回退现有 `turn/completed -> continuation` 主语义
- 但 stale workspace 必须先被资源有效性 contract 挡住
- 不得因为 cleanup 收紧而额外制造新的乐观 redispatch
- 若 Phase 1 单独存在，只允许更保守，不允许出现新的错误放权

### 第二阶段：Turn Finalization

在资源层稳定后再做：

- `turn/completed` provisional 化
- terminal settle
- finalized success 后移 continuation
- `late cancel after completed` 回收至 `premature_turn_end`

理由：

- 这块逻辑会碰 `AppServer -> AgentRunner -> Orchestrator` 三层协作边界，适合在资源层合同已稳定后单独收口

若实现上无法保证 Phase 1 单独落地时上述中间态不变量成立，则两阶段必须同 PR 同收口，不能半套上线。

## 主要风险

1. cleanup 证据要求过弱，旧 race 继续存在
2. cleanup 证据要求过强，workspace 长期堆积无法回收
3. stale invalidation / binding 污染新 run 接管
4. startup sweep 在无 live owner 上下文时仍做出过度自信判断
5. terminal settle window 太短，吸不住晚到 cancel
6. terminal settle window 太长，健康 turn 续跑延迟明显增加
7. 过度翻译路径错误，把普通 SSH / path / bootstrap 故障误报成 lifecycle invalidation
8. ambiguous workspace 只跳过不治理，最终把 race 变成泄漏
9. local / remote parity 口头一致，实际仍留 remote-only 分叉

## 设计结论

本轮采用：

- 一次 change
- 两阶段实现
- 保留现有 owner gate
- 先修 workspace lifecycle，再修 turn finalization

不采用：

- 分成两个完全独立 change
- 回退 `C-50/C-52`
- 只修 `interrupted` 表层现象
- 新建第二套 owner ledger
