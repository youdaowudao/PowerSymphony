# C-52 Workspace Lifecycle 与 Turn Finalization 红蓝评估

## 目的

本文件用于在实现前，对本 change 文档做一轮深度红蓝讨论，重点回答两类问题：

1. 这份方案是否真的命中 incident 需求
2. 它是否会引入新的高风险问题或新的错误激励

## 评估维度

- 是否覆盖 incident 已确认的两条主轴
- 是否保住 `C-50/C-52` 既有 owner gate
- 是否把 workspace lifecycle 与 turn finalization 的边界拆清楚
- 是否存在明显的新风险、遗漏路径或实现诱导错误

## 评估结论

结论：**部分同意，文档方向成立，但当前实现范围必须再收紧到代码真实边界。**

## 蓝队结论

蓝队认为当前 change 文档已经准确对齐 incident 的两条主轴：

- `workspace lifecycle contract`
- `turn finalization contract`

并且明确保留了 `C-50/C-52` 的既有 owner gate，不再把 `duplicate thread` 当主修复目标。

蓝队同时指出 5 个需要前移补强的点：

1. 需要把 incident 结论到 change 交付的覆盖关系写得更可审计
2. 需要把 Phase 1 / Phase 2 的交界再收紧
3. 需要把 resource binding 的职责写窄，避免被误实现成第二套 owner 真相源
4. 需要给 `turn finalized` 补稳定验收语义，而不是只写“加 settle”
5. 需要明确“保守不删 / 保守不续跑”在什么条件下成立、如何继续收口

这些意见已回填到 `README.md`、`10_design.md` 与 `20_plan.md`。

在进入当前最小实现前，蓝队再补 4 条收紧：

1. `turn finalization` 当前只能宣称 `resume-barrier based finalization gate`
2. raw codex `turn_completed` 的观察层口径必须显式标成 provisional / pending
3. `Workspace.remove/2` 必须被写死为低层物理删除原语，不能继续留给 coder 自行脑补
4. `ambiguous workspace` 当前只做到保守停住并留痕，不能写成自动治理闭环已完成

## 红队 Findings

### 1. 删除授权模型此前不够可执行

红队指出，旧版文档虽然反复强调“先证明旧 run 已停干净”，但没有先裁决：

- 谁能做删除授权判断
- 最低 delete evidence 是什么
- 证据冲突时谁赢
- startup sweep 在无 live context 时如何续判

已采纳动作：

- 在设计文档中补了唯一的删除授权模型
- 区分 `live evidence` 与 `reap evidence`
- 明确 `startup sweep` 只能消费 `reap evidence`

### 2. `turn finalized` 之前缺少最小状态机

红队指出，若不先固定：

- `completed`
- `cancelled`
- `failed`
- `aborted`
- transport EOF

之间的归并规则，后续很容易各层各写一套语义。

已采纳动作：

- 在设计文档中补了最小 `turn finalized` 状态机
- 增加 settle 裁决规则，要求实现前先落稳定验收语义

补充裁决：

- 文档可以保留完整目标语义
- 但当前代码收口不得再宣称完整 settle 状态机已经实现
- 本轮代码只要求先把 raw codex `turn_completed` 从观察层 finalized 口径中摘出去

### 3. local / remote parity 的保证级别需要写清

红队指出，“必须同构”如果不解释保证级别，容易把 scope 推向新的跨 host 锁设计，或退化成 remote-only 分叉。

本轮裁决：

- 保证的是“同一 contract、允许不同实现手段”
- 不要求本轮引入跨 host 全局原子锁
- remote 失败时也必须回到相同的保守语义

### 4. ambiguous workspace 不能只跳过不治理

红队指出，若 startup sweep 只负责“保守跳过”，最终会把误删问题转成长期泄漏。

已采纳动作：

- 在设计与计划文档里增加 ambiguous reap candidate 的治理闭环
- 要求至少有再次判定与人工介入口径

补充裁决：

- 当前实现与文档都必须写明，这里只是“保守停住并留痕”
- 不得把后续再判、告警或人工处理误表述为已经完整自动化

### 5. validity gate 检查点此前过于模糊

红队指出，如果只写“每轮 turn 前检查”，会漏掉：

- mid-turn invalidation
- `completed` 到 continuation 之间的失效
- cleanup `closing` 之后的继续执行

已采纳动作：

- 在计划文档里补了 validity gate 检查点矩阵
- 把 turn start、continuation 之前、cleanup delete 前、startup sweep reap 前列成必须裁决入口

### 6. 错误分类优先级此前只停留在口径层

红队指出，若不先定义 lifecycle、terminal conflict、transport/network 的分类优先级，后续 incident/dashboard/状态机会被污染。

已采纳动作：

- 在设计文档里补了错误分类优先级
- 允许内部双记账，但用户态主因要稳定输出

补充裁决：

- 观察层 `turn_completed` 本身存在语义风险，不能单独作为“成功已 finalized”的证据
- 验证口径里必须把这点单独写出，避免 dashboard 或 API 消费方误用

### 7. 两阶段实现的中间态风险需要显式写出来

红队指出，Phase 1 先改 cleanup/binding/startup sweep，而旧 continuation 语义还没变，这会产生中间态风险。

本轮裁决：

- 补了 Phase 1 单独落地时必须保持的中间态不变量
- 若做不到，就必须同 PR 同收口，不能半套上线

### 8. 最小测试矩阵此前漏了 crash / 重入 / 部分失败

红队指出，最容易打穿统一合同的不是 happy path，而是：

- `declare closing -> delete` 之间崩溃
- `before_remove` 部分失败
- remote partial delete
- 迟到写回 binding / terminal

已采纳动作：

- 已把这些场景补进计划文档的最小测试矩阵

## Premortem 结论

Premortem 假设“这次实现两个月后失败”，最可能的死法有：

1. 只修主路径，没有真正覆盖所有 cleanup / continuation side-path
2. 单测是绿的，但 `AppServer -> AgentRunner -> Orchestrator -> Workspace` 跨层闭环没被证明
3. cleanup 变得更保守，但没有积压治理，最终把 race 变成资源泄漏
4. settle 机制吸晚到 cancel 的同时误伤健康 continuation
5. local / remote 语义表面一致，实际仍有 remote-only 分叉

已采纳动作：

- 增加合同覆盖矩阵
- 增加 settle 裁决规则
- 增加 closeout 专项检查

## 主线程裁决

### 保留

- 一次 change、两阶段实现
- 先修 `workspace lifecycle`，再修 `turn finalization`
- 保持 `C-50/C-52` owner gate 不动
- `resource binding` 继续作为资源层事实
- `invalidation record` 只作为辅助语义

### 收紧

- 进入实现前必须先把删除授权模型、最小 settle 状态机和中间态不变量写清楚
- 任何 local / remote parity、错误分类、ambiguous workspace 治理都不能只留在口头原则
- closeout 必须把“旁路 cleanup path”与“remote-only 分叉”当专项 gate

### 暂不下结论

- delete evidence 的具体代码落点与数据结构细节
- settle 的具体超时值
- ambiguous reap candidate 的长期自动治理方案

这些属于实现期裁决，但不能越过本文件已固定的边界。

## 最终判断

这份 change 文档现在已经达到了“可以进入实现”的条件，但前提是：

- 实现时必须严格按本轮红蓝裁决推进
- 不得再把上面 8 条高风险点留成临场自由发挥

对当前最小实现，红蓝双方共同确认的收口边界是：

- 改观察层 phase，不改 raw event_type
- 不把 `agent_runner run_result(status=completed)` 降格成 provisional
- 不重写 `Workspace.remove/2` 调用图，只澄清它的原语定位

如果后续实现线程无法在代码层守住这些裁决，应立即停工回到文档层重新收口，而不是边做边补口径。
