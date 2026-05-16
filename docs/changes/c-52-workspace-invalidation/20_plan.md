# C-52 Workspace Lifecycle Fencing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 把 `C-52` 的 workspace lifecycle fencing 事故修成一条可验证的资源生命周期合同，并避免引入第二套 owner 真相源。

**Architecture:** 复用现有 `claimed / running / blocked_claims / run_instance_id / cooperative interrupt` 控制面，先补 workspace resource binding、cleanup fencing 与 stop 终态确认，再把 invalidation record、per-turn gate、语义化错误翻译接到这条主合同上。所有 terminal cleanup side-path 与 local/remote worker 路径统一遵守同一 contract。

**Tech Stack:** Elixir, ExUnit, SSH-backed workspace hooks, Codex app-server, mise

---

## 实施阶段

本计划按 5 个阶段推进。每个阶段都要求先锁失败测试，再实现最小修复，再跑定向验证。

### Phase 1: 锁定资源生命周期回归合同

**目标：** 先把“资源 fencing 缺失”而不是“文案不好看”锁成失败测试。

**Files:**
- Modify: `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- Modify: `elixir/test/symphony_elixir/workspace_and_config_test.exs`
- Modify: `elixir/test/symphony_elixir/app_server_test.exs`
- Modify: `elixir/test/mix/tasks/workspace_before_remove_test.exs`

- [ ] 写 `running issue -> terminal` 时不得先删 workspace 再停 worker 的失败测试。
- [ ] 写 startup terminal sweep 遇到已被新 run 接管的 workspace 时不得盲删的失败测试。
- [ ] 写 retry / blocked-claim terminal cleanup 也必须经过同一 resource fencing 判定的失败测试。
- [ ] 写 cleanup 无法确认旧 run 已停干净时，必须保守不删的失败测试。
- [ ] 写 stale session 在 turn 前收到 lifecycle 错误，而不是裸 `cwd missing` 的失败测试。
- [ ] 写 stale resource metadata 或 stale invalidation record 不会污染新 dispatch 的失败测试。
- [ ] 跑定向测试，确认失败来自合同尚未实现，而不是夹具问题。

### Phase 2: 引入 workspace resource binding

**目标：** 先让 workspace 资源自己能回答“我属于哪个 run generation”。

**Files:**
- Modify: `elixir/lib/symphony_elixir/workspace.ex`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Possibly modify: `elixir/lib/symphony_elixir/agent_runner.ex`
- Test: `elixir/test/symphony_elixir/workspace_and_config_test.exs`
- Test: `elixir/test/symphony_elixir/orchestrator_status_test.exs`

- [ ] 明确 resource binding 的存储模型、字段和生命周期。
- [ ] 让 binding 至少绑定：
  - `issue_id`
  - `issue_identifier`
  - `run_instance_id`
  - `worker_host`
  - `workspace_path`
  - `state`（如 `active/closing/removed`）
- [ ] 在 `Workspace.create_for_issue/2` 与新 dispatch 接管路径里创建或刷新 binding。
- [ ] 在复用已有 workspace 时，先判断现有 binding 是否允许接管；禁止无条件静默复用。
- [ ] retry 沿用 workspace 时，也必须沿用或刷新同一 binding，而不是旁路。
- [ ] local 与 remote worker 路径都能读写同一语义的 binding。

### Phase 3: 重构 cleanup fencing 与 stop 终态确认

**目标：** 不再让任何 terminal cleanup side-path 直接按 identifier 盲删目录。

**Files:**
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/lib/symphony_elixir/workspace.ex`
- Possibly modify: `elixir/lib/symphony_elixir/codex/app_server.ex`
- Test: `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- Test: `elixir/test/symphony_elixir/workspace_and_config_test.exs`

- [ ] 重构 `terminate_running_issue/3`，改为“先声明 closing，再收集 stop 证据，最后 generation-aware delete”。
- [ ] 把 `run_terminal_workspace_cleanup/0` 从盲删器改成保守 reap candidate 处理器。
- [ ] 把 `handle_terminal_retry_issue/4`、`release_terminal_blocked_claim_issue/2` 统一接入同一 cleanup fencing 协议。
- [ ] 明确 cleanup 删除前需要满足的 stop 证据集合。
- [ ] stop 证据不足时，复用现有 `blocked_claim` 或等价保守状态，不乐观放权。
- [ ] 物理删除前增加 binding 二次确认，防止旧 cleanup 误删新 run workspace。
- [ ] `before_remove` hook 在 closing 阶段的时机、超时与 side effect 边界要一并收紧。

### Phase 4: 在 runner 边界补 validity gate，在 app-server 边界补辅助错误翻译

**目标：** 让旧会话在真正碰 workspace 之前被挡住；一旦仍落到底层错误，也能在有证据时翻译成 lifecycle error。

**Files:**
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
- Modify: `elixir/lib/symphony_elixir/codex/app_server.ex`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/lib/symphony_elixir/event_normalizer.ex`
- Modify: `elixir/lib/symphony_elixir/run_state_store.ex`
- Test: `elixir/test/symphony_elixir/app_server_test.exs`
- Test: `elixir/test/symphony_elixir/orchestrator_status_test.exs`

- [ ] 在 `AgentRunner.do_run_codex_turns/5` 每轮 `run_turn` 之前读取 resource binding，判断该 workspace 是否仍属于当前 run。
- [ ] gate 命中时返回结构化 lifecycle 错误，并记录带 `run_instance_id` 的事件。
- [ ] `AppServer` 不做 owner 裁决，只在已有 resource-closing / invalidation 证据时，把底层路径错误翻译成 lifecycle 错误。
- [ ] 保留普通 bootstrap / SSH / path 错误的原始语义，避免过度匹配。
- [ ] 让 invalidation record 只承担：
  - 用户可读语义
  - 错误翻译依据
  - 事故排查证据
- [ ] 不让 invalidation record 取代 resource binding。

### Phase 5: closeout gate、零上下文复核与回归矩阵

**目标：** 在进入实现 closeout 前，把关键失败路径和 side-path 全部覆盖。

**Files:**
- Verify only

- [ ] 跑以下定向测试，显式带 `SYMPHONY_TEST_MAX_CASES=4`：
  - `orchestrator_status_test.exs`
  - `workspace_and_config_test.exs`
  - `app_server_test.exs`
  - `workspace_before_remove_test.exs`
- [ ] 跑 `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix format --check-formatted`。
- [ ] 跑 `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix lint`。
- [ ] 完成一次零上下文 code review。
- [ ] 完成一次边界/业务 review，重点检查：
  - startup sweep 是否仍可能盲删
  - old cleanup 是否仍可能误删新 workspace
  - stale metadata 是否会导致自杀式失败
  - remote worker 行为是否与本地一致

## 模块级任务拆分

### `workspace.ex`

- [ ] 引入 resource binding 读写 API。
- [ ] 在 `create_for_issue/2` / `ensure_workspace/2` 接 resource binding。
- [ ] 在 `remove/2` / `remove_issue_workspaces/2` 接 cleanup fencing，而不是直接删目录。
- [ ] 本地与 remote 路径统一 binding / invalidation 语义。

### `orchestrator.ex`

- [ ] 把 running terminal cleanup、startup sweep、retry terminal cleanup、blocked-claim terminal cleanup 统一改走同一 cleanup protocol。
- [ ] 把“删除前确认资源仍属于旧 run”做成公共 helper，而不是散落在每条 side-path。
- [ ] 明确 stop 证据不足时的保守状态迁移。

### `agent_runner.ex`

- [ ] 在 turn loop 前接 resource-validity gate。
- [ ] 只消费 orchestrator/resource binding 提供的有效性结论，不自己发明 owner 真相。

### `codex/app_server.ex`

- [ ] 保持最小职责：session 生命周期、底层错误收集、辅助语义翻译。
- [ ] 不在这里实现新的 owner arbitration。
- [ ] 若补 stop 证据，需要明确与 `Port.close` 的关系和边界。

### `event_normalizer.ex` / `run_state_store.ex`

- [ ] 为新增 lifecycle / invalidation 事件补 `run_instance_id` 透传与归并。
- [ ] 避免这些事件被现有 generation 过滤误吞。

## 测试矩阵

### 资源绑定

- [ ] 首次创建 workspace 时生成 binding
- [ ] 复用已有 workspace 时，如果 binding 属于当前 run，可以继续
- [ ] 复用已有 workspace 时，如果 binding 属于旧 run 且状态不安全，禁止静默接管
- [ ] stale binding 不会污染新 dispatch

### cleanup fencing

- [ ] running terminal cleanup 在 stop 证据不足时保守不删
- [ ] startup sweep 在 binding 不明确时跳过
- [ ] retry terminal cleanup 与 blocked-claim terminal cleanup 走相同判断
- [ ] 旧 cleanup 不会误删新 run 接管的 workspace

### runner / app-server

- [ ] stale session 在 turn 前被 gate 挡住
- [ ] 有 lifecycle 证据时，底层 `cwd missing` 被翻译成 lifecycle 错误
- [ ] 没有 lifecycle 证据时，普通 path/SSH/bootstrap 错误保持原语义

### local / remote 一致性

- [ ] 本地 workspace 与 remote workspace 对 binding / cleanup / invalidation 的判定一致
- [ ] `before_remove` 在两条路径上的时机与失败语义一致

## 必须先回答再实现的问题

1. workspace resource binding 的稳定落点在哪里，才能既可跨 cleanup 使用，又不引入 repo 外新依赖
2. “旧 run 已经停干净”的最小可接受证据集合是什么
3. startup sweep 在没有 live in-memory 上下文时，如何安全判断可回收性
4. 新 run 接管同名 workspace 时，如何原子地刷新 binding 并隔离 stale invalidation 语义
5. `before_remove` hook 在 closing 态下是否要降级、限时、改时机，还是必须保留原行为

Plan 到这里为止。下一步若执行，应先把上面 5 个问题落实成最终实现裁决，再进入代码改动。
