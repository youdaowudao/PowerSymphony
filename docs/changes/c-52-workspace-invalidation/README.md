# C-52 Workspace Lifecycle Fencing

## 目标

修复 `C-52` 这次 workspace lifecycle fencing 事故，把当前“workspace 按 issue 固定复用、删除前不看代际、cleanup 先删目录、旧会话只看到 `cwd missing`”的失效路径，收敛成一条可验证的资源生命周期合同：

- workspace 资源必须能证明“当前仍属于哪个 run”。
- cleanup 之前必须有足够证据证明旧 run 已经停干净，或明确降级为保守不删。
- terminal cleanup、startup sweep、retry terminal cleanup、blocked-claim terminal cleanup 必须统一遵守同一条 cleanup fencing 合同。
- invalidation record、per-turn gate、语义化错误翻译都只能建立在这条资源合同之上，不能反过来充当主真相源。

## 需求快照

### 要解决什么问题

- 当前 stalled path 已有 `run_instance_id`、cooperative `turn/interrupt`、`blocked_claim(reason: :remote_stop_unconfirmed)` 等保护。
- 但这些保护主要覆盖消息状态，不覆盖 workspace 资源身份。
- workspace 路径按 `safe_identifier(identifier)` 固定复用，目录存在就直接复用，retry 也沿用同一路径。
- terminal cleanup、startup sweep、retry terminal cleanup、blocked-claim terminal cleanup 都按 `identifier` 直接删目录。
- `AppServer.stop_session/1` 只做 `Port.close`，当前没有可靠的 run 终态确认链。

### 成功标准

- 每个 workspace 资源都能被当前运行态证明“属于哪个 run generation”，而不是只属于某个 issue identifier。
- cleanup 在删除前必须完成 generation-aware 的资源确认；无法确认时宁可保留资源并阻塞重派发，也不能盲删。
- startup sweep、running terminal cleanup、retry terminal cleanup、blocked-claim terminal cleanup 统一遵守同一条 contract。
- `AgentRunner` 在每轮 turn 前都能基于同一资源合同判断自己是否仍可继续。
- invalidation record 和错误翻译只做辅助语义，不构成第二套 owner 真相源。

### 明确不做什么

- 不把这次 change 扩大成新的全局 ownership registry 或分布式锁重构。
- 不承诺跨 orchestrator 进程 / 跨 host 的全局强一致 owner 锁。
- 不把 incident 中“是否存在第二顶层线程”的待排分支当成本轮主修复目标。
- 不把单个 invalidation marker / tombstone 当作主修复本体。

### 固定约束

- 不能让旧 cleanup 按 `identifier` 误删新 run 复用的同名 workspace。
- 不能让 stale invalidation record 污染后续新 run。
- 不能把 owner 判定硬塞进 `AppServer`，打乱 orchestrator / runner 的层次。
- 所有新增 lifecycle 事件都必须带 `run_instance_id`，否则会被现有 generation 过滤吞掉。

## 文档索引

- [10_design.md](./10_design.md)
- [20_plan.md](./20_plan.md)
