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
  - resource binding 的职责收紧
  - cleanup 生命周期入口与低层删除原语的边界澄清
- `elixir/lib/symphony_elixir/state_reducer.ex`
  - raw codex `turn_completed` 观察层 provisional phase
  - 不影响 `agent_runner run_result(status=completed)` 已收敛成功语义
- 如有必要：
  - `elixir/lib/symphony_elixir/event_normalizer.ex`
  - `elixir/lib/symphony_elixir/run_state_store.ex`

### 预计核心测试文件

- `elixir/test/symphony_elixir/workspace_and_config_test.exs`
- `elixir/test/symphony_elixir/run_trace_test.exs`
- 如有必要：
  - `elixir/test/symphony_elixir/extensions_test.exs`

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

## 当前最小实现范围

### 目标

先完成一个最小但完整的收口，确保 coder 不会把当前代码边界误读成“raw codex completed 已 finalized”或“Workspace.remove/2 是生命周期入口”。

### 计划步骤

1. 先锁测试矩阵
   - raw codex `turn_completed` event 映射到 provisional finalization pending phase
   - raw codex `notification(method=turn/completed)` 映射到同一 provisional phase
   - `agent_runner run_result(status=completed)` 仍保持既有成功 phase
   - `cleanup_issue_workspace/2` 仍是生命周期收口入口；`remove/2` 只做物理删除

2. 最小改 `StateReducer`
   - 只改观察层 phase 名称
   - 不扩散到 `run_result(status=completed)` 路径
   - 若 timeline/status marker 仍把 raw codex `turn_completed` 表述成 finalized success，则同步收紧为 provisional marker；不改事件类型

3. 最小改 `Workspace`
   - 收紧模块文档、函数文档与命名口径
   - 不私有化 `remove/2`
   - 不大改调用图

4. 更新 change 文档
   - 明确当前是 `resume-barrier based finalization gate`
   - 明确 binding、ambiguous workspace、`remove/2`、观察层口径的真实边界

### 当前完成判据

- raw codex `turn_completed` 不再在观察层伪装成 finalized success
- `agent_runner run_result(status=completed)` 不受影响
- `Workspace.remove/2` 的低层原语定位被明确写死
- c-52 文档与代码真实边界一致，不再宣称完整 settle 状态机已交付

## 最小测试矩阵

- raw codex `turn_completed` phase rename
- raw codex `turn/completed` notification phase rename
- `agent_runner run_result(status=completed)` 保持 `turn_completed`
- `cleanup_issue_workspace/2` 先进入 closing，`remove/2` 再做物理删除
- 观察层文案承认 `turn_completed` 仍有语义风险，不能作为 finalized 证据

## closeout gate

准备 create PR / update open PR 前，必须先按当前分支或 PR latest head 相对 PR base 的累计 diff 选择 `Next Push Gate`。

- 若累计 diff 命中 `.github/workflows/make-all.yml`、`elixir/**`、`AGENTS.md`、`SPEC.md`，则本地前置硬门就是：
  `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- make all`
  成功后才允许 push。
- 若累计 diff 未命中上述 full-gate 路径，则 closeout gate 至少包含：
  - `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix format --check-formatted`
  - `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix lint`
  - 改动面对应的定向测试

如果 CI 失败，顺序仍是：

1. 先看 CI 报错
2. 本地做定向修复
3. 只要修复后的下一次 PR update 仍命中 full-gate 路径，就必须在再次 push 前重新跑本地 `make all`

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
