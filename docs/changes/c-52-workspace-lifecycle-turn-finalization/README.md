# C-52 Workspace Lifecycle 与 Turn Finalization

## 目标

把 `docs/incidents/c-52-workspace-invalidation-race/` 已经坐实的两条缺口，收敛成一次有边界、可验证、可 review 的实现 change：

1. `workspace lifecycle contract`
2. `turn finalization contract`

本 change 不是继续追“是否真的存在第二个顶层线程”，也不是去回退 `C-50/C-52` 已经建立的 owner gate，而是在保留现有保守 gate 的前提下，把资源生命周期和 continuation 边界补强到能稳定收口。

## 需求快照

### 要解决什么问题

- 当前主线已经有 `claimed / running / blocked_claims / run_instance_id` 这套 owner 控制面保护。
- 但 workspace 资源生命周期与 turn terminal 语义还没有收紧到同一等级：
  - workspace cleanup side-path 仍可能在旧 run 未完成收口时碰同一个物理路径
  - `turn/completed` 当前会被过早当成“可以 continuation”的充分条件
  - `01:38 interrupted` 这类场景会把同一 turn 留成“先 normal continuation、后 interrupted”的冲突现场
- 用户面最终看到的是 `cwd missing` / `No such file or directory` 之类低层错误，或把 turn terminal 冲突误读成 transport/network failure。

### 成功标准

- workspace cleanup、startup sweep、retry cleanup、blocked-claim cleanup 统一服从同一条 generation-aware lifecycle contract。
- 新 run 不会被旧 cleanup 按 `identifier` 误删 workspace；旧 run 在资源失效后也不会继续撞到底层路径错误才知道自己失效。
- continuation 只建立在“turn terminal 已稳定”的前提上，不再把第一次 `turn/completed` 直接当成 finalized。
- `late cancel/aborted after completed` 会收敛成 `premature_turn_end` / hold / blocked-claim 这类保守路径，而不是误推进健康 continuation。
- 全程不回退 `C-50/C-52` 已建立的 owner gate，不新增第二套 owner 真相源。

### 明确不做什么

- 不把本轮扩大成跨 orchestrator 进程或跨 host 的全局分布式锁设计。
- 不把 incident 中“duplicate thread 是否被最终坐实”当成本轮修复前置门槛。
- 不把 dashboard、snapshot 或 invalidation record 升格成新的 owner registry。
- 不把 `interrupted` 文案修饰当成主修复本体。

### 固定约束

- `claimed / running / blocked_claims / run_instance_id` 仍是 owner 控制面的真相源。
- 新修复只能收紧 cleanup / continuation / turn terminal 边界，不能重新允许旧 owner 未确认结束前乐观 redispatch。
- local 与 remote worker 路径必须保持语义一致，不能只修本地路径。
- 回归验证必须覆盖 `workspace lifecycle` 与 `turn finalization` 两块，而不是只挑其中一块证明“看起来好了”。

## Incident 结论到 Change 交付映射

| Incident 已确认结论 | 本 change 必须交付什么 | 最低验证口径 |
| --- | --- | --- |
| `workspace lifecycle contract` 不完整 | cleanup side-path 统一走 generation-aware contract，删除前有唯一授权模型 | running/startup/retry/blocked-claim/local/remote 全覆盖 |
| `turn finalization contract` 不完整 | `turn/completed` 不再直接等价 finalized；`late cancel/aborted` 回收至保守路径 | `completed -> late cancelled/aborted` 回归成立 |
| `01:38 interrupted` 不应解释成 API 断线 | turn terminal conflict 与 transport/network failure 有稳定区分 | 状态/事件口径与错误分类回归成立 |
| `C-50/C-52` gate 不能回退 | 不新增第二套 owner 真相源，不重开乐观 redispatch | zero-context review 明确确认此项 |

## 实施策略

本 change 按“一次收口、两阶段实现”推进：

1. 第一阶段先落 `workspace lifecycle`
2. 第二阶段再落 `turn finalization`
3. 两阶段共用一份 change 文档、同一套目标和同一轮最终收口验证

这样做的原因是：

- `workspace lifecycle` 是更底层的合同，先稳定它，才能避免后续 turn 边界讨论被 `cwd missing` 这种低层资源失效噪声污染。
- `turn finalization` 依赖现有 owner gate 和 workspace validity gate 的保守语义；如果两块完全拆成两个独立 change，验收口径会裂开。

两阶段边界固定为：

- Phase 1 只解决“资源是否仍有效、cleanup 是否有权删、失效如何暴露”
- Phase 2 才解决“turn terminal 是否已 finalized、continuation 是否可继续”

如果实现中需要提前碰另一阶段内容，只能作为最小配套，不得提前吞掉另一阶段的主问题。

## 文档索引

- [10_design.md](./10_design.md)
- [20_plan.md](./20_plan.md)
- [30_red_blue_review.md](./30_red_blue_review.md)

## 关联材料

- Incident 入口：
  [docs/incidents/c-52-workspace-invalidation-race/README.md](../../incidents/c-52-workspace-invalidation-race/README.md)
- 既有 change：
  - [docs/changes/c-50-ownership-gate/README.md](../c-50-ownership-gate/README.md)
  - [docs/changes/c-52-workspace-invalidation/README.md](../c-52-workspace-invalidation/README.md)
