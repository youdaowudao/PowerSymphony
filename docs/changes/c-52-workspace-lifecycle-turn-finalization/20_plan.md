# C-52 Workspace Lifecycle 与 Turn Finalization 实施计划

## 实施原则

- 同一条 change，一次收口
- 代码按两阶段推进：
  1. `workspace lifecycle`
  2. `turn finalization`
- 每阶段都先补定向失败测试，再做最小实现，再跑局部验证
- 不把 `make all` 当开发过程命令；closeout 前按仓库规则跑格式、lint 和定向测试

## 预期改动面

### 预计核心实现文件

- `elixir/lib/symphony_elixir/workspace.ex`
  - resource binding
  - cleanup fencing
  - local / remote 路径一致性
- `elixir/lib/symphony_elixir/orchestrator.ex`
  - running cleanup
  - startup sweep
  - retry cleanup
  - blocked-claim cleanup
  - `premature_turn_end` 收口复用
- `elixir/lib/symphony_elixir/agent_runner.ex`
  - per-turn validity gate
  - continuation 判断时机后移
- `elixir/lib/symphony_elixir/codex/app_server.ex`
  - terminal settle
  - finalized success 与冲突终态归并
- 如有需要：
  - `elixir/lib/symphony_elixir/event_normalizer.ex`
  - `elixir/lib/symphony_elixir/run_state_store.ex`
  - `elixir/lib/symphony_elixir/state_reducer.ex`

### 预计核心测试文件

- `elixir/test/symphony_elixir/workspace_and_config_test.exs`
- `elixir/test/symphony_elixir/app_server_test.exs`
- `elixir/test/symphony_elixir/extensions_test.exs`
- 如有现成更贴近 orchestrator cleanup 的测试文件，也可能补到对应 orchestrator 测试

## 合同覆盖矩阵

| 合同入口 | 主要失败模式 | 必须验证的结果 |
| --- | --- | --- |
| running cleanup | 旧 cleanup 误删新 run workspace | 不误删；保守不删时进入可继续收口状态 |
| startup sweep | 无 live context 下误删或永久跳过 | ambiguous 跳过有闭环；明确 reap evidence 才删 |
| retry cleanup | retry side-path 旁路统一 contract | 与 running cleanup 同判定 |
| blocked-claim cleanup | blocked claim 收口时误删或假死 | 与 running cleanup 同判定；不乐观放权 |
| stale continuation | 旧 run 在失效后继续续跑 | 在正确 gate 点被挡住，不裸报路径错误 |
| `completed -> late cancelled/aborted` | continuation 建立在 provisional completion 上 | 回收到 `premature_turn_end` / hold / blocked-claim |
| local worker | 本地路径安全、远端路径漂移 | 本地合同成立 |
| remote worker | SSH / remote remove / hook 分叉 | 与本地保持同一 contract，允许实现手段不同 |

## Phase 1: Workspace Lifecycle

### 目标

把 cleanup side-path、delete evidence、startup sweep 和 stale workspace 报错收拢成一套统一合同。

### 计划步骤

1. 先锁测试矩阵
   - running cleanup 不得误删新 run 已接管的 workspace
   - startup sweep 遇到 ambiguous binding 时必须保守跳过
   - retry cleanup / blocked-claim cleanup 与 running cleanup 走同一判定
   - stale session 在 turn 前得到 lifecycle invalid，而不是裸路径错误
   - stale invalidation / binding 不会污染新 run 接管

2. 收紧 `Workspace` 合同
   - 明确 binding 的状态迁移
   - 明确 invalidation record 的从属地位
   - 明确 delete evidence 的最小集合
   - 明确 ambiguous reap candidate 的再次判定与治理口径

3. 收紧 orchestrator side-path
   - running terminal cleanup
   - startup terminal sweep
   - retry terminal cleanup
   - blocked-claim terminal cleanup

4. 验证 local / remote 对齐
   - SSH 路径不能出现“本地安全、远端仍盲删”的分叉

### 第一阶段完成判据

- cleanup side-path 都已走 generation-aware contract
- 新 run 不会被旧 cleanup 误删 workspace
- stale run 不会继续撞到底层路径错误才发现失效
- ambiguous workspace 不会无限悬空，至少有稳定的再次判定与人工介入口径

## Phase 2: Turn Finalization

### 目标

把 continuation 从“第一次 `turn/completed`”后移到“terminal 已稳定 finalized”之后。

### 计划步骤

1. 先锁测试矩阵
   - `late cancel after completed`
   - `late aborted after completed`
   - 正常健康 turn 仍能 continuation
   - 正常 `turn/failed` / `turn/cancelled` 仍回到 `premature_turn_end`

2. 改 `AppServer`
   - `turn/completed` 进入 settle，而不是立即成功返回
   - settle 内若晚到 cancel / fail，返回 conflict terminal
   - settle 成功后才返回 finalized success
   - 明确 settle 的结束条件、冲突条件、超时去向与健康路径延迟上界

3. 改 `AgentRunner`
   - continuation 判断后移到 finalized success 之后
   - `late cancel after completed` 回收至现有 `handle_turn_error -> premature_turn_end`
   - 明确 validity gate 检查点，而不是只在“每轮 turn 前”模糊处理

4. 复用 orchestrator 现有保守路径
   - hold
   - blocked-claim
   - 不新增新的 continuation side-channel

### 第二阶段完成判据

- `turn/completed` 不再直接等于 continuation 通行证
- `late cancel/aborted after completed` 不再误推进下一轮 continuation
- 健康路径续跑没有被不必要地打断

## 最小测试矩阵

### Workspace Lifecycle

- running issue terminal cleanup
- startup terminal workspace sweep
- retry issue terminal cleanup
- blocked claim terminal cleanup
- local worker
- remote worker
- stale invalidation / binding takeover
- cleanup `declare closing -> delete` 之间崩溃/重入
- `before_remove` 部分失败或 remote partial delete
- 旧 worker 在 `closing` 后迟到写回 binding/terminal

### Turn Finalization

- normal completed -> finalized -> continuation
- completed -> late cancelled
- completed -> late aborted/failed
- ordinary cancelled / failed
- `premature_turn_end` 进入 hold，必要时 converged 到 blocked-claim
- settle 超时后的统一去向
- transport EOF / network 抖动与 terminal conflict 的分类优先级

### Validity Gate 检查点矩阵

- turn start 前
- tool call 执行前（若当前结构允许拦截）
- turn completed 到 continuation 判断之间
- cleanup delete 前
- startup sweep reap 前

### 口径回归

- `01:38 interrupted` 这类场景在状态/事件口径上能区分：
  - turn terminal conflict
  - transport/network failure

## closeout gate

准备进入 PR 更新前，至少执行：

- `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix format --check-formatted`
- `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix lint`
- 改动面对应的定向测试

如果这轮实现后 CI 失败，再按仓库规则：

1. 先看 CI 报错
2. 本地做定向修复
3. 修完后再考虑 `make all` 最终确认

## 零上下文 review 要点

### 代码 review 关注

- 是否引入了第二套 owner 真相源
- cleanup side-path 是否真的统一了合同，而不是留下旁路
- binding / invalidation / delete evidence 是否有状态互相打架的问题
- `AppServer` 是否越权承担 owner 裁决
- Phase 1 / Phase 2 的中间态不变量是否被破坏

### 业务 / spec review 关注

- 是否真的解决了 incident 指向的两条主轴
- 是否把 `interrupted` 错误归因成了 transport/network
- 是否为了修 `interrupted` 反向放松了 `C-50/C-52` gate
- 是否新增了“资源回收不了”或“健康 turn 续跑显著变慢”的新问题

### closeout 专项检查

zero-context reviewer 必须单独回答：

1. 还有没有旁路统一合同的 cleanup path
2. local / remote 是否真的同构，只是实现手段不同

这两项任一回答不通过，本 change 不得收口。
