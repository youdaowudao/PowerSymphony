# 0518aa 观察层合同风险流程改版设计

## Goal

定义一套以“观察层合同风险”为前置分流条件、以阶段角色覆盖为主轴、以 `contract checker` 前移合同问题发现时机的顶级流程设计，并为后续规则文件改写提供稳定边界。

本设计不追求与旧 `1+2` / `1+1` 规则并存；本轮目标就是给旧主轴提供替换方案。

## Confirmed Input

本设计以当前已经确认的人类决策为输入：

- 旧顶级规则若与本轮意见冲突，应修改旧规则，以新流程为准。
- 新流程不再以“默认固定 `1+2`”作为主轴，而改为“按阶段要求角色”。
- 命中观察层合同风险时，必须引入 `contract checker`。
- `closeout` 需要从交错链改成顺序链，但必须配失效条件与回退规则。
- `## Codex Workpad` 继续作为唯一活真相源。

## Design Decisions

### 1. 顶级协作模型从人数模板切换为角色模板

新的顶级流程不再问“这轮是不是 `1+2`”，而是问“这轮是否满足所需角色和独立性”。

标准角色集合固定为：

- `blue analyst`
- `red analyst`
- `implementer`
- `contract checker`
- `final zero-context reviewer`

阶段要求如下：

- 前置讨论阶段必须具备 `blue analyst` 与 `red analyst`
- 代码实现阶段必须具备 `implementer`
- 命中观察层合同风险时必须具备 `contract checker`
- 任何代码变更在 push 前必须具备 `final zero-context reviewer`

这意味着新主轴保护的是职责覆盖，而不是人数形式。

### 2. 角色制必须有适用矩阵与降阶边界

角色集合不是默认全开。

最小适用矩阵固定为：

- 命中观察层合同风险的代码或流程合同变更
  - 必需角色：`blue analyst`、`red analyst`、`implementer`、`contract checker`、`final zero-context reviewer`
- 未命中观察层合同风险的普通代码变更
  - 必需角色：`implementer`、`final zero-context reviewer`
  - `blue analyst`、`red analyst` 由讨论级别决定，不默认强制
  - 不引入 `contract checker`
- 不改变流程合同的普通文档变更
  - 不默认扩成全角色流程
  - 是否引入 `blue analyst`、`red analyst` 由讨论级别决定
  - 不引入 `contract checker`
  - 若未触及可执行 workflow 合同，不强制要求最终 zero-context reviewer subagent

这里的“流程合同变更”至少包括：

- `AGENTS.md`
- `elixir/WORKFLOW.md`
- 会改变 agent 行为、验证顺序、角色职责或收口口径的治理条文

### 3. 角色定义必须与独立性一起落地

只定义角色名称不够，必须同时定义最低独立性。

本设计固定以下硬约束：

- `implementer`、`contract checker`、`final zero-context reviewer` 不得由同一 agent 兼任
- 这里的“同一 agent”既包括同一 agent id，也包括在同一执行身份下复用完整前序上下文继续裁决
- 分析角色进入实现、合同检查或最终复核时，必须关旧开新
- 后序角色不得把前序线程的推理过程当成自己的裁决依据
- 允许复用冻结后的需求快照、`contract matrix`、累计 diff、验证摘要和 blocker 收口证据
- 不允许复用同一线程身份把分析、实现、复核串成一条自审链
- 审计时至少要能证明：
  - 角色身份不同
  - 角色线程不同
  - 后序角色输入中不包含前序线程的完整推理历史，只包含允许复用的稳定材料

### 4. 观察层合同风险是显式流程开关

`观察层合同风险` 不是抽象提醒，而是决定是否进入额外合同路径的显式开关。

触发条件仅限以下四类：

- 存在 `anchor` / `traceability`
- 存在聚合摘要，而非原样透传
- 存在 agent / tool / item 的计数、分类或归因口径
- 同一语义被多个消费面读取

命中规则固定为：

- 任一条件命中，即视为命中
- 只有四类条件全部不命中，才允许视为未命中

最小判定边界固定为：

- `anchor / traceability`
  - 命中：新增、删除、改写会被其他页面、日志、审计流或跳转链路依赖的标识或追踪语义
  - 不命中：纯文案、纯样式、不改变任何追踪语义的格式化
- `聚合摘要`
  - 命中：把多个 item、event、状态或记录汇总成 count、badge、summary、rollup、derived status
  - 不命中：单字段原样透传，且没有派生判断
- `计数 / 分类 / 归因口径`
  - 命中：重新计算 agent/tool/item 数量，重分类，重定义归属关系
  - 不命中：只展示已有稳定结果，不重新推导
- `多消费面`
  - 命中：同一语义被两个及以上消费面读取，且本次改动可能改变它们的一致性
  - 不命中：仅单一消费面局部展示，且不向外输出

执行约束：

- 判定时点必须在 frozen artifact 完成前
- 默认策略为 `疑似即命中`，不能因为想绕过额外流程而按乐观口径忽略
- 主线程负责提出初判
- 红蓝讨论阶段负责挑战初判
- 若仍有争议，必须在 frozen artifact 中显式记录为已命中或未命中，不允许留成口头状态

### 5. `frozen artifact` 是单一冻结包，不是自由散落的文档集合

`frozen artifact` 固定指：

- 主线程在 `proceed` 前冻结并交付给实现、checker、reviewer 的稳定需求包
- 至少包含：
  - 目标 / 需求快照
  - 明确不做什么
  - 固定约束
  - 风险判定结论
  - 若命中观察层合同风险，则附窄版 `contract matrix`

承载位置固定为：

- `docs/changes/<change-id>/README.md`
- 以及该入口明确点名的设计文档固定章节

冻结时点固定为：

- 红蓝讨论收敛后
- `implementer` 开工前

变更规则固定为：

- freeze 后不得静默扩写
- 若 reviewer / checker 指出 frozen artifact 缺口，必须由主线程显式重冻
- 若重冻改变用户可见行为、合同边界或风险判定，必须回到文档裁决，而不是直接继续 closeout

### 6. `contract matrix` 只允许作为 frozen artifact 的窄版附录

命中观察层合同风险时，frozen artifact 内必须附一个窄版 `contract matrix`。

它的字段固定为：

- `field / view`
- `source of truth`
- `allowed transform`
- `must not infer`

这里的“窄版”含义固定为：

- 只覆盖当前任务会改动、会新增或会重新解释的合同字段/视图
- 不回填无关历史字段
- 不扩成系统级全量表

完整性约束固定为：

- 不仅覆盖直接改动字段，还必须覆盖与这些字段直接联动的摘要、计数、归因与展示语义
- 若某个消费面依赖某字段的派生语义，即使该消费面代码未改动，也必须纳入 matrix
- `contract checker` 与 `final reviewer` 都有权指出 matrix 覆盖不完整
- 一旦认定 matrix 不完整，必须回主线程重冻 artifact，而不是由 checker 或 reviewer 私自补表继续推进

这里的“不得另起平行文档”含义固定为：

- 不新增独立的 `contract-matrix.md`
- 不在 Workpad 中镜像同一份静态 matrix
- 不在 review comment 里维护第二份稳定表述

### 7. `contract checker` 是合同 gate，不是第二个 reviewer

`contract checker` 只负责四类检查：

- 字段是否来自约定的 `source of truth`
- `allowed transform` 是否被违反
- 是否发生 `must not infer`
- 多消费面的语义是否保持一致

它明确不负责：

- 大面 code review
- `Push Readiness`
- `heavy validation`
- 最终放行判定

最终的 `Change Review` 与 `Push Readiness` 仍由 `final zero-context reviewer` 输出。

仲裁顺序固定为：

- `contract checker` 负责判定实现是否符合当前 frozen artifact 与 `contract matrix`
- `final reviewer` 负责判定最终累计 diff 是否可放行
- 若 `final reviewer` 认为合同判断依赖的 matrix 或 frozen artifact 不完整，必须打回主线程重冻
- 主线程负责组织重冻与回退，不由 checker 或 reviewer 单方面重写冻结件

### 8. `closeout` 使用固定主路径，但必须定义失效与回退

命中观察层合同风险的任务，`closeout` 默认主路径固定为：

1. `implementer` 完成代码
2. `contract checker`
3. `baseline lock`
4. `heavy validation`
5. `final zero-context reviewer`
6. `push / PR / merge`

但这个顺序不是无条件单行道。必须补充以下失效与回退规则：

- `contract checker` 后，凡是触及合同字段、视图语义、摘要口径、计数口径、归因口径的改动，必须重过 `contract checker`
- `baseline lock` 后，若 `PR base`、`HEAD` 或 `exact cumulative diff` 变化，必须重做 `baseline lock`
- `heavy validation` 失败后，若修复未触及合同字段，可回 `implementer -> baseline lock -> heavy validation`
- `heavy validation` 失败后，若修复触及合同字段，必须回 `implementer -> contract checker -> baseline lock -> heavy validation`
- `final reviewer` 发现的是合同问题时，回 `contract checker`
- `final reviewer` 发现的是非合同实现问题时，按最小回退原则回 `implementer`
- `final reviewer` 发现的是 baseline 口径失效或验证证据不再对应当前 diff 时，回 `baseline lock`

### 9. `baseline lock` 必须是可核验事实，不是口头状态

`baseline lock` 锁定的对象固定为：

- 当前 `PR base`
- 当前 `HEAD`
- 当前 `exact cumulative diff`
- 当前 `validation summary` 对应的 diff 口径

记录协议固定为：

- 执行责任人：主线程
- 记录位置：`## Codex Workpad` 的 `Baseline Lock` 小节
- 最小字段：
  - `base ref`
  - `head sha`
  - `diff fingerprint`
  - `validation scope`
  - `locked by`
  - `locked at`

它的职责是：

- 防止带着错误 diff 口径进入 `heavy validation`
- 为最终 reviewer 提供明确审查对象
- 在任何 GitHub 状态变化后判断原先验证结论是否失效

它不负责：

- 决定合同是否成立
- 决定最终能否放行
- 代替测试或 review

失效事件固定为：

- `PR base` 变化
- `HEAD` 变化
- `exact cumulative diff` 变化
- 锁定后新增或删除验证范围
- 任何角色明确指出当前验证证据与当前 diff tuple 不再对应

下列事件单独发生时不使 baseline 失效：

- 仅 rerun check，且 `base/head/diff` 未变
- 纯评论变化，且 `base/head/diff` 未变

`baseline 争议` 固定定义为：

- 任一角色主张当前 review / validation 证据不再对应当前 `base/head/diff` tuple
- 或两个角色引用了不同的 baseline tuple

### 10. `blocker ledger` 只在条件触发时开启，但一旦开启就必须持续维护

`blocker ledger` 不再默认常开；命中以下任一条件时必须开启：

- 出现风险判定争议
- 出现 matrix 覆盖争议
- 出现角色独立性争议
- 任一 checker / reviewer 返回 `revise`
- 出现 baseline 争议
- 进入第二轮返工

最小字段固定为：

- `blocker id`
- `type`
- `owner`
- `opened by`
- `opened at`
- `close proof`

`type` 只允许：

- `contract`
- `implementation`
- `baseline`
- `gate`

它只能附着在 `## Codex Workpad` 内，不能平行出第二套阻塞记录系统。

返工轮次口径固定为：

- 某个 checker / reviewer 首次给出 `revise` 时，开启一轮返工
- 围绕同一 blocker id 的连续修复与复审，计为同一轮
- 该轮以原发起角色明确接受、或该 blocker 被新 blocker 取代时结束
- 新的 `revise` 针对新的 blocker id，才计入下一轮

### 11. 最终汇报改成角色与放行性导向

最终汇报删除“是否保持 `1+2`”作为主指标，改为固定回答：

- 实际使用了哪些角色
- 必需角色是否到位
- `implementer` / `contract checker` / `final reviewer` 是否保持独立
- 是否命中观察层合同风险
- 是否启用 `contract checker`
- `blocker ledger` 是否开启过
- 共发生几轮返工
- 是否有 baseline 争议
- 最终 validation 结果
- 最终可放行结论

这样汇报保护的是流程真实性，而不是编制叙事。

## Walkthrough

命中观察层合同风险的一张高风险代码卡，标准路径应为：

1. 主线程收敛需求并组织红蓝分析。
2. 文档阶段在 frozen artifact 内冻结目标快照，并附窄版 `contract matrix`。
3. `implementer` 独立实现；其他角色不混入实现线程。
4. `contract checker` 仅对照 `contract matrix` 审合同。
5. 通过后锁定 `PR base`、`HEAD`、`exact cumulative diff`。
6. 按锁定口径执行 `heavy validation`。
7. `final zero-context reviewer` 只看最终累计 diff、验证摘要与 blocker 收口状态，做最终放行判定。
8. 若中途任何条件使合同结论或 baseline 失效，则按预定义回退路径重走对应步骤。

## Primary Risks

1. 执行层把 `观察层合同风险` 当成可选标签，而不是强制前置判定。
2. `contract checker` 被滥用成第二轮 code review，导致 `closeout` 膨胀。
3. `baseline lock` 缺少显式失效判定，导致验证证据与实际 diff 脱钩。
4. 角色独立性未被真正检查，流程退化成“多线程自审”。
5. 最终 reviewer 被 `heavy validation` 绿灯架空，只做形式收口。

## Verification Focus

后续进入规则实现时，至少要验证：

1. 所有规则文本都把角色制写成新的主轴，不再残留旧 `1+2` 主轴的默认表达。
2. `观察层合同风险` 在文档、workflow 与汇报口径中是同一套定义。
3. `contract checker` 的职责边界没有与 final reviewer 重叠。
4. `baseline lock` 的锁定对象、失效条件与回退规则在规则文本中可直接执行。
5. Workpad 仍是唯一活真相源，repo 文档没有长成第二套实时台账。
