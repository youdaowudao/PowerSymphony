# C-57 Review 前移与 Push Readiness 拆分

## 目标

把当前 PowerSymphony 里“`final zero-context reviewer` 太晚介入、`make all` 常常先跑在尚未完成最终实现审查的累计 diff 上”这一条 closeout 因果链拆开处理，在不降低独立验证强度的前提下，把 `Change Review` 前移到第一次 `heavy validation` 之前，并把 `Push Readiness` 收窄成一次后置的 validation / baseline / next-push 对齐确认。

## 需求快照

### 要解决什么问题

- 当前命中 `观察层合同风险` 的默认 closeout 顺序是：
  - `implementer`
  - `contract checker`
  - `baseline lock`
  - `heavy validation`
  - `final zero-context reviewer`
  - `push / PR / merge`
- 这个顺序会让实现语义、consumer surface、fallback / error attribution 之类问题，经常在第一次 `heavy validation` 之后才第一次被 `final zero-context reviewer` 发现。
- 结果是昂贵 gate 会先跑在一个还没经过最终实现复核的累计 diff 上，导致 `make all` 返工成本被放大。
- 当前 `Change Review` 与 `Push Readiness` 虽然已经是两个输出字段，但在 `WORKFLOW.md` 的实际执行顺序里仍然被同一后置 final review 一起消费，没能形成“前移发现语义问题、后置只做放行确认”的收口结构。

### 成功标准

- 不新增 durable reviewer 角色名，标准角色集合仍保持：
  - `blue analyst`
  - `red analyst`
  - `implementer`
  - `contract checker`
  - `final zero-context reviewer`
- 普通代码变更的默认 closeout 顺序改成：
  - `implementer`
  - `final zero-context reviewer` 执行 `pre-validation Change Review`
  - `baseline lock`
  - `heavy validation`
  - `final zero-context reviewer` 执行 `post-validation Push Readiness confirm`
  - `push / PR / merge`
- 命中 `观察层合同风险` 的代码或流程合同变更的默认 closeout 顺序改成：
  - `implementer`
  - `contract checker`
  - `final zero-context reviewer` 执行 `pre-validation Change Review`
  - `baseline lock`
  - `heavy validation`
  - `final zero-context reviewer` 执行 `post-validation Push Readiness confirm`
  - `push / PR / merge`
- `Change Review` 明确前移到 `baseline lock` 之前，判断对象是 `frozen artifact + 当前 cumulative diff`，并绑定一个明确的 `cumulative diff fingerprint`。
- `baseline lock` 最小字段扩成：
  - `base ref`
  - `head sha`
  - `diff fingerprint`
  - `change review fingerprint`
  - `validation scope`
  - `locked by`
  - `locked at`
- `baseline lock` 必须显式引用上一次 `Change Review = pass` 审过的同一个 `change review fingerprint`，不能只靠 `diff fingerprint` 口头等价。
- `Push Readiness` 被收窄成一次后置确认，只允许检查：
  - 当前 `base/head/diff` 与 `baseline lock` 是否一致
  - 当前 `baseline lock` 是否仍引用同一个 `Change Review fingerprint`
  - validation evidence 是否对应当前 next push 对象
  - `Contract Review / Change Review / closure check` 是否无未清阻塞
  - 是否存在任何未经过独立语义复审的新代码变化
- `post-validation Push Readiness confirm` 只能做三类有界动作：
  - 给出 `Push Readiness: ready`
  - 给出 `Push Readiness: not ready`，并按既定矩阵回退到 `baseline lock`、`contract checker` 或 `pre-validation Change Review`
  - 在 bounded evidence 发现当前对象不再安全时，显式 reopen 同一累计 diff 的 `pre-validation Change Review`
- `post-validation Push Readiness confirm` 不得新增独立语义审查结论；若它发现新的语义疑点，只能把该疑点转化为一次明确的 reopen 或既定回退，而不能自己膨胀成第二次全量 reviewer。
- `post-validation Push Readiness confirm` 必须在一个新的、bounded 的 `final zero-context reviewer` invocation 中执行：
  - 不能直接沿用产出上次 `pre-validation Change Review` 结论的同一 reviewer thread
  - 必须只接收后置确认所需的最小输入，不继承前一次 reviewer thread 的完整推理历史
  - 其执行目标固定为“确认当前对象仍对应上次已通过的前置审查”，不是重新自由扫一次累计 diff
- 若 `heavy validation` 后出现新的未复审代码变化，后置 reviewer 必须强制 reopen `pre-validation Change Review`，不能直接给 `Push Readiness = ready`。
- `post-validation Push Readiness confirm` 仍由 `final zero-context reviewer` 角色承载，但不得由当前累计 diff 的最后代码作者在同一执行线程里完成最终放行自证。
- 若当前任务命中 bounded `closure check` 路径，则固定顺序为：
  - `pre-validation Change Review`
  - `baseline lock`
  - `heavy validation`
  - `closure check`
  - `post-validation Push Readiness confirm`
- `closure check` 只允许输出 `matched`、`mismatch`、`escalate`，并且：
  - `matched` 才允许进入 `post-validation Push Readiness confirm`
  - `mismatch` 或 `escalate` 必须阻断 `Push Readiness = ready`
  - `source / projection / contract` 类不一致回 `contract checker`
  - `consumer / verification / implementation` 类不一致回 `pre-validation Change Review`
- `AGENTS.md`、`elixir/WORKFLOW.md`、与其直接冲突的最小同步文档，以及 prompt 相关测试，对上述新顺序、边界、字段和回退矩阵给出一致表述。
- 旧的 closeout 顺序表述必须在所有直接 consumer 上被移除或改写，至少覆盖：
  - reviewer gate 段落
  - post-implementation gate 步骤
  - pre-push question set / `Next Push Gate` 问答
  - `## Review Summary` / `Baseline Lock` schema
  - rework routing / checking closeout 路径
  - `elixir/README.md` 的概述说明
- 验收证据必须至少包含：
  - `core_test.exs` 对 prompt 相关消费者同时给出正反两类断言：
    - 正向断言渲染后的 prompt 明确体现 `pre-validation Change Review -> baseline lock -> heavy validation -> post-validation Push Readiness confirm`
    - 反向断言旧的 `contract checker -> baseline lock -> heavy validation -> final zero-context reviewer` 总兜底顺序、以及“后置 reviewer 可继续自由全量扫 diff”之类旧口径不再出现
  - `core_test.exs` 断言 `Push Readiness` 只做 bounded confirm / reopen，不做第二次全量 review
  - `core_test.exs` 断言 `baseline lock` 绑定 `change review fingerprint`
  - `core_test.exs` 断言 `closure check` 的固定顺序与回退语义（若 prompt 中已有该路径）
  - 非 prompt consumer 必须有直接证据证明已同步，而不只是被 prompt 侧间接覆盖；至少包括：
    - `AGENTS.md`
    - `docs/governance/验证分层规则.md`
    - `elixir/README.md`
    - `elixir/WORKFLOW.md` 中的 `Completion bar before Human Review` 与 issue-body template
  - 这类非 prompt consumer 的验收证据允许采用定向文本核对或 `rg`/diff 级验证，但必须能证明旧顺序、旧 `baseline lock` schema、旧 `baseline dispute` 口径与旧 `Push Readiness` 宽口径已经被移除或改写，而不是“其他地方大致看起来没问题”

### 明确不做什么

- 不新增 `zero-context change reviewer`、`push readiness confirmer` 之类新的 durable 标准角色名。
- 不把这次优化写成“新增审批层”。
- 不删除 `contract checker`。
- 不删除最终 `Push Readiness` 放行确认。
- 不降低 `make all` 或其他 `heavy validation` 的强度。
- 不把 `Push Readiness` 重新膨胀成第二次全量实现审查。
- 不在这次变更里扩展 `Review Summary` 为更多实时字段，除非实现时发现现有字段无法承载本次边界。

### 固定约束

- 本轮是流程合同变更，已命中 `观察层合同风险`。
- `frozen artifact`、`contract matrix`、累计 diff、validation evidence、baseline 证据仍是后续角色唯一允许复用的稳定输入。
- `## Codex Workpad` 仍是唯一活真相源；repo 文档定义字段语义和回退规则，但不镜像实时状态。
- `Push Readiness` 只能回答“现在能不能 push / push 前最小还缺什么”，不能追加封闭清单之外的自由语义审查标准。
- `post-validation Push Readiness confirm` 没有权力自己创建新的开放式 review batch；它只能确认当前对象可放行，或按既定回退矩阵把问题升级回前置 gate。
- 只要返工改变当前 cumulative diff 的实现内容，就必须重过 `pre-validation Change Review`。
- 只要 `base/head/diff/validation scope` 任一变化，就必须至少重走 `baseline lock -> heavy validation -> post-validation Push Readiness confirm`。
- 只要最新 `Change Review = pass` 被 reopen、替换或失效，即使 `base/head/diff/validation scope` 暂时未变，也必须重做 `baseline lock`，不得沿用旧 lock。
- `baseline dispute` / `baseline invalidation` 的统一口径必须同步扩成：
  - `base ref`
  - `head sha`
  - `diff fingerprint`
  - `change review fingerprint`
  - `validation scope`
- 若任一角色主张当前 review / validation 证据不再对应上述五元组中的任一项，或两名角色引用了不同的 `change review fingerprint`，一律视为 `baseline dispute`。
- “纯记录纠偏 / 同一 diff 证据重跑 / 纯注释与排版修改”只有在以下条件同时成立时，才允许不视为“未复审新代码变化”：
  - `base ref`、`head sha`、`diff fingerprint`、`change review fingerprint`、`validation scope` 全部未变
  - 分类理由被显式记录到 `## Codex Workpad > Notes` 或 `Validation`
  - 后置 reviewer 明确认可该分类
- 下列变化一律不得落入上述白名单：
  - `elixir/WORKFLOW.md` prompt 文案、`AGENTS.md` / 治理规则条文、`## Review Summary` 字段语义
  - 测试断言、fixture、snapshot、门禁脚本、validation 入口
  - 任何会改变 consumer-visible 结果、fallback / error attribution、合同字段语义的代码或文案
- 对“是否属于未复审新代码变化”存在争议时，默认按需要重过 `pre-validation Change Review` 处理。
- 根仓 `AGENTS.md` 与 `elixir/WORKFLOW.md` 若冲突，以本轮实现后的同步规则为准；不能保留并行旧口径。

## 任务类型识别

- 类型：代码变更，且属于流程合同变更。
- 讨论级别：`Large change`，使用轻量红蓝对抗。
- 角色要求：
  - 文档阶段：`blue analyst`、`red analyst`
  - 实现 / closeout：`implementer`、`contract checker`、`final zero-context reviewer`

## 风险判定结论

- 已命中 `观察层合同风险`。
- 命中依据：
  - 同一语义会被多个消费面读取：仓库规则文本、运行期 prompt、`## Review Summary` / `## Codex Workpad` 执行面、implementer / reviewer closeout 行为。
  - 存在显式摘要与归因口径：`Change Review`、`Push Readiness`、`baseline lock`、`closure check` 都是聚合后的执行语义，不是原样透传。
  - 存在跨层 projection：incident draft / frozen artifact -> `AGENTS.md` 规则 -> `elixir/WORKFLOW.md` prompt -> agent 执行与测试断言。
  - 同一 reviewer 角色的两段动作如果边界不清，会在多个消费面上被重新解释，直接构成合同漂移风险。

## Source-of-Truth Chain

| 关键字段 / 语义 | 实际 source | 中间 projection | 最终 consumer |
| --- | --- | --- | --- |
| `Change Review` 的时点与职责边界 | 本冻结件中的成功标准与固定约束 | `AGENTS.md` closeout 规则、`elixir/WORKFLOW.md` prompt 指令、必要的同步治理文档 | implementer 后的 `final zero-context reviewer` 线程、`## Review Summary` 维护逻辑、prompt 渲染测试 |
| `Push Readiness` 的允许检查范围 | 本冻结件中的五项封闭清单与非目标 | `AGENTS.md` / `elixir/WORKFLOW.md` 对 `Push Readiness` 的字段定义、closeout 步骤、回退规则 | 后置 `final zero-context reviewer` 线程、`## Review Summary` / `## Codex Workpad` 执行面 |
| `Change Review fingerprint -> baseline lock` 绑定关系 | 本冻结件中的绑定要求 | `AGENTS.md` / `elixir/WORKFLOW.md` 中的 `baseline lock` 字段说明与失效条件 | `Baseline Lock` 记录维护者、后置 reviewer、closeout gate 使用者 |
| “未复审新代码变化必须 reopen Change Review” | 本冻结件中的回退规则与额外前提 | `AGENTS.md` / `elixir/WORKFLOW.md` 的 rework matrix、`Push Readiness` 前提与 closeout 检查项 | `heavy validation` 后的返工路径判定、最终 push 放行判断 |
| `closure check` 的有界输出语义 | 本冻结件中的保留 / 非目标边界 | `AGENTS.md` / `elixir/WORKFLOW.md` 的 `closure check` 说明 | 命中多 consumer / contract 风险任务的 closeout 线程 |
| `Next Push Gate` / pre-push 问题集里的 `Push Readiness` 消费方式 | 本冻结件中的 bounded confirm 语义、baseline 绑定要求与 reopen 条件 | `elixir/WORKFLOW.md` 的 pre-push question set、`## Review Summary` 判定逻辑 | push 前问答、`Next Push Gate` 选择与 closeout 执行线程 |
| `Checking` 期间新出现的人类 review delta` | 当前 PR latest head 上新增的 human review delta | `elixir/WORKFLOW.md` 的 checking closeout 规则、review summary 维护与回退矩阵 | checking recheck 线程、post-validation reviewer、返工路径判定 |

## Contract Matrix

| field / view | source of truth | allowed transform | must not infer |
| --- | --- | --- | --- |
| `Change Review` | 本冻结件定义的前移语义与回退规则 | 允许由 `final zero-context reviewer` 在 `baseline lock` 前执行，并记录为 `Change Review: pass/revise/not required` | 不得把它继续解释成一次发生在 `heavy validation` 之后的总兜底审查；不得把通过结果外推到后续新 diff |
| `Push Readiness` | 本冻结件定义的五项封闭检查与 ready 前提 | 允许由同一标准 reviewer 角色在 `heavy validation` 后执行一次更窄确认，并记录为 `ready/not ready` | 不得扩成第二次全量语义 review；不得在封闭清单外自由追加新审查标准 |
| `post-validation Push Readiness confirm` 的输出权力 | 当前 `baseline lock`、validation evidence、`Contract Review / Change Review / closure check` 状态 | 允许输出 `ready`、`not ready`、或对同一累计 diff 的显式 reopen / 既定回退 | 不得独立创造新的 reviewer 角色、开放式 findings 批次或新的审批层 |
| `Change Review fingerprint` | `pre-validation Change Review` 审过的明确 cumulative diff fingerprint | 允许被 `baseline lock` 引用，并在 `Push Readiness Notes` 中回指 | 不得把“差不多同一批代码”当成等价对象；不得在 diff 已变时继续沿用旧 fingerprint |
| “未复审新代码变化”判断 | 当前 cumulative diff 与最近一次 `Change Review = pass` 的对比结果 | 只有在 fingerprint 全不变、理由已落盘、且被后置 reviewer 确认时，才允许按白名单把纯记录纠偏、纯注释 / 排版、同一 diff 上证据重跑视为未引入新代码变化 | 不得靠口头解释把行为、consumer-visible 结果、fixture、断言、模板、validation 入口、prompt 文案或 review 字段语义变化降级成“无影响” |
| `closure check` | 既有 `source / projection / consumer / verification` 四项对齐要求 | 允许输出 `matched`、`mismatch`、`escalate` 三类有限结果 | 不得演变成新的 durable reviewer、新的 `Next Push Gate` 或开放式语义审查层 |

## 预期实现边界

- 主落点：
  - `AGENTS.md`
  - `elixir/WORKFLOW.md`
- 直接同步且存在冲突时最小对齐：
  - `docs/governance/验证分层规则.md`
  - `elixir/README.md`
- 证明运行期 prompt 已同步的测试：
  - `elixir/test/symphony_elixir/core_test.exs`
- `elixir/WORKFLOW.md` 至少需要同步的消费段落类别：
  - `Final zero-context reviewer gate`
  - `Baseline lock and heavy validation`
  - `Step 2` 中的 post-implementation gate 顺序
  - push 前问题集与 `Next Push Gate` 判定
  - `Checking closeout and escalation rules`
  - `Completion bar before Human Review`
  - issue-body / `## Review Summary` / `## Codex Workpad > Baseline Lock` 模板
  - `## Review Summary` / `## Codex Workpad > Baseline Lock` 模板
- 若实现阶段发现还有其他直接消费旧顺序的规则文本或测试，可在不突破本冻结边界的前提下补入同类最小同步。

## 默认回退顺序

- `contract checker` 未通过：
  - 回 `implementer`
  - 若结论是冻结件或 `contract matrix` 缺口，由主线程显式重冻同一 frozen artifact
- `pre-validation Change Review` 未通过：
  - 合同语义问题：回 `contract checker`
  - 非合同实现问题：回 `implementer`
- `heavy validation` 未通过：
  - 若修复不触及合同字段，且没有引入未复审新代码变化，回 `baseline lock -> heavy validation`
  - 若修复引入新的实现变化，回 `implementer -> pre-validation Change Review -> baseline lock -> heavy validation`
  - 若修复触及合同字段，回 `implementer -> contract checker -> pre-validation Change Review -> baseline lock -> heavy validation`
- `post-validation Push Readiness confirm` 未通过：
  - baseline / evidence mismatch：回 `baseline lock -> heavy validation -> post-validation Push Readiness confirm`
  - `Contract Review` 状态对当前对象失配或已失效：回 `contract checker -> pre-validation Change Review -> baseline lock -> heavy validation`
  - `closure check = mismatch` 或 `escalate`：
    - `source / projection / contract` 类问题：回 `contract checker -> pre-validation Change Review -> baseline lock -> heavy validation`
    - `consumer / verification / implementation` 类问题：回 `pre-validation Change Review -> baseline lock -> heavy validation`
  - 出现未复审新代码变化：回 `implementer -> pre-validation Change Review -> baseline lock -> heavy validation -> post-validation Push Readiness confirm`
- `Checking` 期间若在同一 `base/head/diff/change review fingerprint/validation scope` 对象上出现新的 human review delta：
  - 合同语义 / source-of-truth / attribution 类问题：回 `contract checker -> pre-validation Change Review -> baseline lock -> heavy validation`
  - 普通实现 / consumer / verification 类问题：回 `pre-validation Change Review -> baseline lock -> heavy validation`
  - 不允许只把 `Push Readiness` 暂时写成 `not ready` 而不回到前置审查路径

## 冻结说明

- 本文件是本轮 `frozen artifact`。
- 文档阶段 `proceed` 只在红蓝只读复核接受这份冻结件后记录。
- freeze 后不得静默扩写；若后续需要改变用户可见行为、合同边界、风险判定或上述封闭清单，必须由主线程显式重冻本文件。
- 后续 implementer、contract checker、final zero-context reviewer 只复用：
  - 本冻结件
  - 当前累计 diff
  - validation evidence
  - baseline / blocker 收口证据
- 当前 run 已获得明确人类裁决，并按更严格版本进入 `spec freeze`：
  - `post-validation Push Readiness confirm` 必须是一次新的独立 bounded reviewer invocation
  - `baseline lock` 必须显式绑定到具体 `change review fingerprint`
  - `Checking` 或后置阶段若出现新的 review delta，不允许只写 `not ready`，必须强制回到前置审查路径

## 人类裁决

- 人类已明确裁决：以下三点全部按“要”处理，并作为实现硬约束：
  - 最后一步“现在能不能 push”的检查，必须换成新的独立复核 invocation，不能沿用前一次 `Change Review` 线程
  - `baseline lock` 必须明确记录它绑定的是哪一次前置 `Change Review` 通过结果
  - 最后阶段若冒出新的 review 意见，不能只写成 `Push Readiness: not ready`，必须强制退回前面的审查步骤

## 当前状态

- 第二轮 blue analyst 结论：`proceed`
- 第二轮 red analyst 结论：`revise`
- 经人类裁决后，本轮按更严格解释收敛，允许进入实现。

## 参考输入

- incident draft：
  - `docs/incidents/修改测试流程/2026-05-20-PowerSymphony-review-前移与-push-readiness-拆分-草稿.md`
