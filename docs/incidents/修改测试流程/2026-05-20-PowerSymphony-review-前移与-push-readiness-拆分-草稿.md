# PowerSymphony review 前移与 push readiness 拆分草稿

最后更新：2026-05-20
状态：草稿

## 1. 这次要解决的问题

当前 PowerSymphony 的命中 `观察层合同风险` 收口路径是：

- `implementer`
- `contract checker`
- `baseline lock`
- `heavy validation`
- `final zero-context reviewer`
- `push / PR / merge`

这个顺序的问题，核心不是 gate 数量，而是一条因果链：

1. 实现语义、consumer surface、fallback / error semantics 没有在第一次 `heavy validation` 之前审干净
2. 所以昂贵 full gate 会先跑在一个还没经过最终实现审查的累计 diff 上
3. 所以 `make all` 跑完之后，`final zero-context reviewer` 仍可能首次打出关键 finding
4. 所以 expensive gate 的返工概率被放大

这份草稿只解决上面这一类 `late semantic discovery before expensive gate` 问题。

## 2. 本次改法的核心判断

不建议简单把当前 `final zero-context reviewer` 整体前移。

建议把现有 `final zero-context reviewer` 的职责拆成两个动作语义：

1. 更早的 `pre-validation Change Review`
2. 更晚的 `post-validation Push Readiness confirm`

其中：

- `pre-validation Change Review` 负责在 `heavy validation` 之前审实现是否过关
- `post-validation Push Readiness confirm` 负责在 `heavy validation` 之后确认当前 diff、baseline 与 validation evidence 仍然匹配，且允许 push

这样做的目标是：

- 不降低独立验证强度
- 不删除 `contract checker`
- 不删除最终放行确认
- 把实现语义问题尽量暴露在第一次 `heavy validation` 之前
- 让 `make all` 更接近真正最后一次 expensive gate

但这里有一条重点边界必须写清：

- 主修复不是“多一层 gate”
- 主修复是 `pre-validation Change Review` 前移
- `post-validation Push Readiness confirm` 只是配套兜底动作，用来防止 `make all` 之后又有新代码、baseline 漂移、evidence 不再对应当前 diff

## 3. 修改后的建议主路径

前提：

- 已经进入代码实现 / closeout 路径

### 3.1 普通代码变更

- `implementer`
- `final zero-context reviewer` 执行 `pre-validation Change Review`
- `baseline lock`
- `heavy validation`
- `final zero-context reviewer` 执行 `post-validation Push Readiness confirm`
- `push / PR / merge`

### 3.2 命中 `观察层合同风险` 的代码变更

- `implementer`
- `contract checker`
- `final zero-context reviewer` 执行 `pre-validation Change Review`
- `baseline lock`
- `heavy validation`
- `final zero-context reviewer` 执行 `post-validation Push Readiness confirm`
- `push / PR / merge`

## 4. 每个角色的职责边界

### 4.1 `contract checker`

保持不变，只负责：

- `source of truth`
- `allowed transform`
- `must not infer`
- 多消费面语义一致性

明确不负责：

- 大面实现审查
- `heavy validation`
- 最终 `Push Readiness`

### 4.2 `final zero-context reviewer` 的前半动作：`pre-validation Change Review`

这里不新增标准角色名，仍沿用现有 `final zero-context reviewer`。

只是把它的第一段动作前移到 `heavy validation` 之前。

它负责：

- 当前累计 diff 是否实现了冻结目标
- 是否存在明显实现缺口
- 是否遗漏必要 consumer surface
- 是否存在错误 fallback、错误归因、错误语义压平
- 是否需要退回 `implementer` 或 `contract checker`

它不负责：

- 用最新 validation evidence 决定现在是否可 push
- 替代 `contract checker`
- 替代 `heavy validation`
- 重判合同语义本身；若发现疑似合同问题，只能打回 `contract checker`

时点口径：

- `pre-validation Change Review` 依据的是 `frozen artifact + 当前 cumulative diff`
- 它判断的是“这份实现是否值得进入 `baseline lock` 与 `heavy validation`”
- `baseline lock` 仍只锁通过该 review 后的 `base/head/diff/validation scope`
- `baseline lock` 记录必须显式引用当次 `Change Review` 审过的 `cumulative diff fingerprint`
- `pre-validation Change Review = pass` 必须绑定到一个明确的 `cumulative diff fingerprint`
- 下列变化默认视为“未复审新代码变化”，会使原 `Change Review` 自动失效：任何会改变运行行为、生成结果、consumer-visible 结构或文案、fallback / error attribution、合同字段语义、模板输出、测试 fixture / source-of-truth 断言、validation 入口或高风险路径覆盖面的代码或配置变化
- 若执行层不能在低成本下证明某次变化只属于纯记录纠偏、纯注释 / 排版修改或无文件变更的证据重跑，则默认按“未复审新代码变化”处理

### 4.3 `final zero-context reviewer` 的后半动作：`post-validation Push Readiness confirm`

这里同样不新增标准角色名。

这是同一标准角色在 `heavy validation` 之后执行的收口确认动作。

它不是主修复，不是第二次大面 code review，而是配套兜底动作。

它负责：

- 当前 `base/head/diff` 是否仍与 `baseline lock` 一致
- 当前 `baseline lock` 是否仍引用上次 `Change Review` 审过的同一 `cumulative diff fingerprint`
- 当前 validation evidence 是否仍对应这次 next push
- 当前 `Next Push Gate` 是否已经满足
- 是否存在新的 baseline mismatch
- 自上次 `Change Review = pass` 之后，是否存在任何未经过独立语义复审的新代码变化
- 当前是否允许 push

它不负责：

- 重新全量扫实现语义
- 在没有 diff / baseline 变化时重开大面 change review
- 重新承担 `contract checker` 的职责
- 把 bounded `closure check` 扩成新的语义审查层

但它必须具备一项强制升级权：

- 若它发现 `heavy validation` 之后的修补已经让当前累计 diff 偏离上次 `Change Review` 审过的对象，则必须打回 `pre-validation Change Review`
- `post-validation Push Readiness confirm` 不能在存在“未复审新代码”的情况下直接给 `ready`

## 5. 记录字段建议

当前 `Review Summary` 建议从两段变成三段：

- `Contract Review`
- `Change Review`
- `Push Readiness`

这里拆的是语义，不是 durable 标准角色集合。

默认仍由仓库现有的 `final zero-context reviewer` 角色承载这两段动作，但这里新增一条最小独立性硬约束：

- `pre-validation Change Review` 与 `post-validation Push Readiness confirm` 都不能由当前累计 diff 的最后代码作者自审
- `post-validation Push Readiness confirm` 必须在一个新的 `zero-context` reviewer thread 中执行，不能直接沿用产出上次 `Change Review` 结论的同一执行线程继续自证
- 是否复用同一 owner 不是这里的主约束；真正的主约束是“不能由最后一个改代码的人，在同一执行线程里完成最终放行”

最小建议字段：

- `Contract Review: <pass | revise | not required>`
- `Contract Review Notes: <...>`
- `Change Review: <pass | revise | not required>`
- `Change Review Notes: <...>`
- `Push Readiness: <ready | not ready>`
- `Push Readiness Notes: <...>`

存放规则：

- `Contract Review / Change Review / Push Readiness` 统一记录在 Linear issue body 的 `## Codex Workpad / Review Summary`
- 不另起 PR-only、comment-only、reviewer-only 的平行台账
- `baseline lock` 仍只记录在 `## Codex Workpad > Baseline Lock`，并至少写明：`base/head/diff/validation scope` 以及对应的 `Change Review fingerprint`
- 若命中多 consumer / contract 风险，现有 bounded `closure check` 保留，但它只允许核对已经枚举过的 consumer / contract 对齐项，不允许扩展成新的全量语义审查
- `closure check` 一旦发现新的语义问题，只能升级回 `pre-validation Change Review` 或 `contract checker`，不能在自身阶段吸收处理
- `closure check` 的输出形态只允许是：`matched`、`mismatch`、`escalate` 三类；不允许在这个阶段自由新增“我认为还应该再看一下”的开放式审查项

## 6. 回退规则建议

### 6.1 `contract checker` 未通过

- 回 `implementer`
- 若是冻结件缺口，回主线程做同一冻结件的显式重冻

### 6.2 `zero-context change review` 未通过

- 合同语义问题：回 `contract checker`
- 非合同实现问题：回 `implementer`

### 6.3 `heavy validation` 未通过

- 不触及合同字段：
  - 若修复不引入新的代码变化，只是纯记录纠偏或同一 diff 上的证据重跑，则回 `baseline lock -> heavy validation`
  - 若修复引入新的代码变化，且该变化会影响行为、consumer surface、fallback、错误归因或高风险路径，则回 `implementer -> pre-validation Change Review -> baseline lock -> heavy validation`
- 触及合同字段：回 `implementer -> contract checker -> pre-validation Change Review -> baseline lock -> heavy validation`

这里的“纯记录纠偏 / 同一 diff 上证据重跑”只允许落入下列白名单：

- 无文件变更，只是对同一个 `base/head/diff/validation scope` 重新执行命令并刷新 evidence
- 只更新 Linear / PR / Workpad / incident 记录文本，用来如实抄录已存在 evidence，且没有改动任何 repo 内的代码、模板、fixture、测试、断言、source-of-truth 或 validation 入口
- 只发生纯注释、纯排版、纯空白字符修改，且触达文件不参与运行行为、模板输出、consumer-visible 结果、测试断言、fixture、validation 或合同语义

下列变化一律不得落入上述白名单：

- 模板、fixture、snapshot、断言、摘要 / 口径、生成输出、workflow 文案、consumer-visible 文案、validation 入口、合同字段相关代码或配置变化
- 任何需要靠“解释一下其实没影响”才能成立的变化

### 6.4 `post-validation Push Readiness confirm` 未通过

- baseline / evidence mismatch：回 `baseline lock -> heavy validation -> post-validation Push Readiness confirm`
- 因修复导致 diff 改变：按 `6.3` 的对应路径回退，不允许跳过重新 `baseline lock` 与重跑 `heavy validation`

重跑矩阵：

- 只要返工触及合同字段、视图语义、摘要口径、计数口径或归因口径，必须重过 `Contract Review`
- 只要返工改变当前 cumulative diff 的实现内容，必须重过 `pre-validation Change Review`
- 只要 `base/head/diff/validation scope` 任一变化，必须至少重走 `baseline lock -> heavy validation -> post-validation Push Readiness confirm`
- 只有纯记录纠偏、无 `base/head/diff/validation scope` 变化时，才允许只重过 `post-validation Push Readiness confirm`
- 只要对“是否属于未复审新代码变化”存在判断争议，默认按需要重过 `pre-validation Change Review` 处理

`Push Readiness = ready` 的额外前提：

- 当前 validation evidence 对应当前 `base/head/diff/validation scope`
- 自上次 `Change Review = pass` 之后，不存在任何未经过独立语义复审的新代码变化
- 若存在这类新代码变化，`post-validation Push Readiness confirm` 必须把状态打回 `not ready`，并要求先重过 `pre-validation Change Review`
- `Push Readiness Notes` 必须显式说明本次判断依据的是哪一个 `Change Review fingerprint` 与哪一个 `baseline lock`

`Next Push Gate` 在本稿中只允许检查下面五项：

- 当前 `base/head/diff` 与 `baseline lock` 一致
- 当前 `baseline lock` 仍引用同一个 `Change Review fingerprint`
- 必要 validation evidence 已齐全，且对应当前 next push 对象
- `Contract Review / Change Review / closure check` 没有处于 `revise / mismatch / escalate` 的未清状态
- 不存在任何未经过独立语义复审的新代码变化

除上面五项之外，`post-validation Push Readiness confirm` 不允许再自由追加新的语义审查标准；若执行层发现新问题，只能把问题升级回前面的 review / checker 阶段处理

## 7. 这版草稿想保住的质量底线

- `contract checker` 仍保留
- 独立 change review 仍保留
- 最终 push 放行确认仍保留
- `make all` 强度不下降
- `first_risk_detected_stage` 整体前移，而不是后移
- reviewer ownership 不能因为拆 gate 而变得更模糊
- 不新增 durable 标准角色集合

## 8. 当前草稿的主要风险

- 若 `pre-validation Change Review` 与 `post-validation Push Readiness confirm` 的边界没写清，后半动作很容易再次膨胀成第二个全量 reviewer
- 若执行层把两个动作误实现成两个新的 durable reviewer 角色，协作成本可能反而增加
- 若最小独立性约束被弱化成“反正不是同一个角色名就行”，执行层仍可能出现同人同线程自证
- 若字段设计不够克制，`Review Summary` 可能变得更难维护

## 9. 当前建议的默认落地方式

默认不新增复杂审批层，只做下面三点：

1. 保留现有标准角色名 `final zero-context reviewer`
2. 把它的 `Change Review` 动作明确前移到 `baseline lock` 之前
3. 把它的 `Push Readiness` 动作收窄成 validation-evidence / baseline / next-push 对齐确认

## 10. 红蓝对抗后的裁决

保留：

- `Change Review` 前移
- `Push Readiness` 收窄
- `contract checker` 保留
- `make all` 强度不下降
- `closure check` 保留为有界对齐证明
- 后置 reviewer 仍保留“发现最终 diff 已偏离上次 `Change Review` 审查对象时，强制 reopen `Change Review`”的权力

删掉：

- 新增 `zero-context change reviewer` / `push readiness confirmer` 作为 durable 标准角色名
- 默认把 `Change Review` 与 `Push Readiness` 拆成两个固定 owner
- 任何会把这次优化写成“新增审批层”的表述

暂不下结论：

- 是否需要把 `Review Summary` 再扩成更多字段
- 是否需要把“纯记录纠偏白名单”继续压缩得更窄

最终结论：

- 这次优化应定义为“同一标准 reviewer 的两次不同语义动作”，不是“新增两个 reviewer 角色”
- 主修复是把 `Change Review` 前移到第一次 `heavy validation` 之前
- `Push Readiness` 保留，但它只是更窄、更靠后的配套兜底动作
- `closure check` 只能做已枚举对齐项的有界证明，不能演变成新的隐性 reviewer
- 最小独立性要求不是“必须新增一个 reviewer 角色”，而是“不得由最后改代码的人在同一执行线程里完成最终放行”
- 这个改法只有在“`Change Review` 绑定 diff fingerprint、`baseline lock` 显式引用该对象、后续任何未复审新代码都会强制 reopen `Change Review`、`Next Push Gate` 只允许检查封闭清单”这四条写成硬规则时，才不会在全局上削弱检测强度
- 只要严格执行上面的重跑矩阵与记录位置规则，这个改法才有明确优化空间，且不必靠流程扩编来达成
