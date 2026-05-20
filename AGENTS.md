## 身份
你是专门的编程coder,你的文件操作权限仅限于项目内的所有文件，禁止修改项目外任何文件。


## Linear
- Linear属于生产环境，任何改动，写入，删除等操作都需要非常谨慎认真复核。
- 更新 Linear 前，必须先确认 PR review 与 required checks 全绿；未通过时禁止推进 Linear 状态。

## 联网规则
- 每次联网前必须调用Web Search Routing技能进行对联网工具的路由选择，禁止跳过。

--- project-doc ---



## git规则
 - 所有提交信息、PR 信息都必须使用中文，专有名词除外
 - 禁止直接在主线上操作，禁止直接向远端推送主线
 - 在 Symphony 工作流中，默认起手先开启开发分支；如果已经在开发分支上，则直接继续，不需要额外说明。

## Linear

- 更新 Linear 前，必须确认 required checks 全绿；如 PR 已存在 review/comment，则需确认无未处理的 review delta。未通过时禁止推进 Linear 状态。

## PR收口规则

- 对 open PR 的任何新提交，`git push` 成功后，agent 的第一优先级 GitHub 动作必须是为该 PR 立即尝试开启 auto-merge；不得先读取 checks、review delta 或 mergeability 再决定是否发起。
- 对首次 create PR 的场景，允许先执行 create PR；但 create PR 一旦成功，第一优先级 GitHub 动作就必须立刻切到该 PR 的 auto-merge 尝试，不得先做其他 GitHub 写操作。
- 在本仓库工作流里，普通开发分支默认视为 PR-bound；只要当前分支后续会用于 create PR 或 update PR，门禁就必须按该分支 / PR latest head 相对 PR base 的累计 diff 选择，而不是按“此刻 PR 是否已经存在”降级。
- 如果某次分支 push 曾按非 PR push 执行，后来才决定用同一 head 开 PR，则在 create PR 前必须先补跑当前应有的 `Next Push Gate`；未补跑前不得开 PR。
- PR create/update、review reply、PR/issue comment 审计、merge 这些关键 GitHub 写操作，默认唯一允许路径是 `.codex/skills/github_api.py`；禁止 GitHub UI、`gh`、ad-hoc CLI、其他 helper 作为常规路径。只有在用户显式授权，或 `.codex/skills/github_api.py` 不可用且已记录 blocker 时，才允许例外。
- 若发现上述关键 GitHub 写操作已通过 GitHub UI、`gh`、ad-hoc CLI、其他 helper 完成，且不满足“用户显式授权”或“已记录 `github_api.py unavailable` blocker”任一条件，则视为流程违规；必须先停止后续 closeout / merge，用 `.codex/skills/github_api.py` 在 PR / issue comment stream 记录这次 out-of-band write 的事实与原因，再重新确认 PR 状态、review delta、latest head required checks，并在需要时重新执行对应 gate 后才能继续。
- 若 auto-merge 返回 `already enabled`，视为成功。
- 若 auto-merge 返回 `clean status`，说明 PR 已经来到可直接合并阶段；这不是权限故障，也不是 blocker。此时只要 latest head required checks 全绿，就允许进入手动 merge fallback。
- 只有 auto-merge 因其他原因未开启成功时，才允许保留手动 merge fallback；且必须先在评论区明确汇报失败原因。
- 绝大多数情况下都应走 auto-merge；手动 merge 仅是异常兜底路径，不是常规路径。

## 多 Agent 协作与复核

- 非代码变更默认不要求 `final zero-context reviewer` subagent，但提交前仍需完成与改动范围相称的独立验证。
- 只要涉及代码新增、删除、重构或行为变更，提交前必须经过一次 `final zero-context reviewer` 零上下文复核。
- 本仓库的多 Agent 主轴是“阶段角色制 + 角色独立性”，不是固定人数模板。标准角色集合为：
  - `blue analyst`
  - `red analyst`
  - `implementer`
  - `contract checker`
  - `final zero-context reviewer`
- 角色适用矩阵按任务性质分流：
  - 命中 `观察层合同风险` 的代码或流程合同变更：必须具备 `blue analyst`、`red analyst`、`implementer`、`contract checker`、`final zero-context reviewer`
  - 未命中 `观察层合同风险` 的普通代码变更：必须具备 `implementer`、`final zero-context reviewer`；`blue analyst`、`red analyst` 由讨论级别决定；不引入 `contract checker`
  - 不改变流程合同的普通文档变更：不默认扩成全角色流程；是否引入分析角色由讨论级别决定；不引入 `contract checker`
- `观察层合同风险` 是显式流程开关，不是提醒语。命中条件仅限以下四类，任一命中即视为命中：
  - 存在 `anchor` / `traceability`
  - 存在聚合摘要，而非原样透传
  - 存在 agent / tool / item 的计数、分类或归因口径
  - 同一语义被多个消费面读取
- `观察层合同风险` 的判定时点必须早于 `frozen artifact` 冻结；默认策略为“疑似即命中”。若存在争议，必须在 `frozen artifact` 中显式写明“已命中”或“未命中”，不得保留口头状态。
- 在记录 `proceed` 前，必须先完成一次 `任务类型识别 + source-of-truth chain`。命中以下任一可识别特征时，视为必须列链路：
  - 跨边界字段 / 状态 / 归因的 `source` 与 `consumer` 位于不同层
  - 存在 `query` / `projection` / `passthrough` / `summary` / `presenter` / `adapter` 等中间投影
  - 同一语义被多个 `consumer surface` 读取
  - 既有状态 / 字段 / 枚举 / 归因被复用到新的 `consumer`
- `source-of-truth chain` 最小字段固定为：
  - `关键字段 / 语义`
  - `实际 source`
  - `中间 projection`
  - `最终 consumer`
- `source-of-truth chain` 默认记录在当前 run 已要求维护的载体中；只有当前 run 本来就需要 `frozen artifact` 时，才在该 artifact 中引用或概述；它本身不得单独触发新的 repo 文档门禁。
- 若在当前边界下列不出可工作的 `source-of-truth chain`，则不得记录 `proceed`，也不得进入实现。
- 这里的“流程合同变更”至少包括：`AGENTS.md`、`elixir/WORKFLOW.md`，以及任何会改变 agent 行为、验证顺序、角色职责或收口口径的治理条文。
- 主线程必须在 `proceed` 前冻结 `frozen artifact`，并把它交付给实现、检查和复核角色；`proceed` 只记录该冻结件已被接受并进入 `spec freeze`。`frozen artifact` 是单一冻结包，至少包含：
  - 目标 / 需求快照
  - 明确不做什么
  - 固定约束
  - 风险判定结论
  - 若命中 `观察层合同风险`，附窄版 `contract matrix`
- 上述 `frozen artifact` 仅在当前 run 本来就需要进入该冻结路径时，才落到 repo 文档集；`source-of-truth chain` 本身不得把原本可留在既有载体里的小修小改升级为 repo change doc。
- `frozen artifact` 的承载位置固定为 `docs/changes/<change-id>/README.md` 及其点名的固定章节；freeze 后不得静默扩写。若 checker 或 reviewer 指出冻结件缺口，必须由主线程显式重冻；若重冻改变用户可见行为、合同边界或风险判定，必须回到文档裁决。
- `contract matrix` 只能作为 `frozen artifact` 的组成部分存在，不能另起平行文档。最小字段固定为：
  - `field / view`
  - `source of truth`
  - `allowed transform`
  - `must not infer`
- `contract matrix` 只覆盖本次会改动、会新增或会重新解释的字段 / 视图，以及与其直接联动的摘要、计数、归因和展示语义；不回填无关历史字段，不扩成系统级全量表。
- 角色独立性是硬约束，不允许只换线程名不换执行身份：
  - `implementer`、`contract checker`、`final zero-context reviewer` 不得由同一 agent 兼任
  - 分析角色若进入实现、合同检查或最终复核，必须关旧开新
  - 后序角色不得继承前序线程的完整推理历史，只能复用 `frozen artifact`、`contract matrix`、累计 diff、验证摘要和 blocker 收口证据
- 主线程只负责编排、拆任务、冻结上下文、维护 Workpad、收敛状态和最终汇报；不得直接替子线程写代码、代 checker / reviewer 下结论，或故意忽略已发现的问题。
- `contract checker` 是合同 gate，不是第二个全量 reviewer。它只负责：
  - 字段是否来自约定的 `source of truth`
  - `allowed transform` 是否被违反
  - 是否发生 `must not infer`
  - 多消费面的语义是否保持一致
- `contract checker` 明确不负责：大面 code review、`Push Readiness`、`heavy validation`、最终放行判定。`final zero-context reviewer` 仍固定输出 `Change Review` 与 `Push Readiness`；其中 `Change Review` 必须前移到 `baseline lock` 之前，`Push Readiness` 只允许作为后置 bounded confirm 回答“现在能不能 push / push 前最小还缺什么”。
- 命中 `观察层合同风险` 的任务，`closeout` 默认主路径固定为：
  - `implementer`
  - `contract checker`
  - `final zero-context reviewer` 执行 `pre-validation Change Review`
  - `baseline lock`
  - `heavy validation`
  - `final zero-context reviewer` 执行新的独立 `post-validation Push Readiness confirm`
  - `push / PR / merge`
- 仅当任务同时命中多层 `consumer` / contract 风险，且已触发 `任务类型识别 + source-of-truth chain` 时，`closeout` 内必须补一次有界 `closure check`。
- `closure check` 只检查四项是否对齐：`source`、`projection`、`consumer`、`verification`。
- `closure check` 只允许输出 `matched`、`mismatch`、`escalate`。
- `closure check` 不是新 reviewer 角色，不是新的 `Next Push Gate`，不是新的 review state，也不替代 `contract checker`、`final zero-context reviewer` 或 full gate。
- `closure check` 不得扩展成开放式审查层；除上述三种输出外，不得自由新增 findings、审查结论或新的放行标准。
- 命中 bounded `closure check` 路径时，固定顺序为：`pre-validation Change Review -> baseline lock -> heavy validation -> closure check -> post-validation Push Readiness confirm`。
- `post-validation Push Readiness confirm` 必须是新的独立 bounded reviewer invocation，不能沿用产出前一次 `pre-validation Change Review` 结论的同一 reviewer thread；它只能复核 baseline、validation evidence、未清 review 结论与“是否出现未复审新代码变化”，无权膨胀成第二次全量 review。
- `baseline lock` 锁定的对象固定为：当前 `PR base`、当前 `HEAD`、当前 `exact cumulative diff`、当前 `change review fingerprint`、当前 `validation summary` 对应的 diff 口径。记录位置固定在 Linear issue body 的 `## Codex Workpad > Baseline Lock`，最小字段固定为：
  - `base ref`
  - `head sha`
  - `diff fingerprint`
  - `change review fingerprint`
  - `validation scope`
  - `locked by`
  - `locked at`
- `baseline 争议` 的统一口径为：任一角色主张当前 review / validation 证据不再对应当前 `base/head/diff/change review fingerprint/validation scope` 五元组中的任一项，或两个角色引用了不同的 `change review fingerprint`。
- 失效条件与回退规则必须和主路径一起执行，不得只写主顺序：
  - `contract checker` 之后，只要返工触及合同字段、视图语义、摘要口径、计数口径或归因口径，必须重过 `contract checker`
  - `pre-validation Change Review` 通过后，只要当前 cumulative diff 的实现内容变化，必须重过 `pre-validation Change Review`
  - `baseline lock` 之后，只要 `PR base`、`HEAD`、`exact cumulative diff`、`change review fingerprint`、`validation scope` 任一变化，必须重做 `baseline lock`
  - 若最新 `Change Review = pass` 被 reopen、替换或失效，即使 `base/head/diff/validation scope` 暂时未变，也必须重做 `baseline lock`
  - `heavy validation` 失败后，若修复未触及合同字段且未引入未复审新代码变化，回 `baseline lock -> heavy validation`
  - `heavy validation` 失败后，若修复引入新的实现变化，回 `implementer -> pre-validation Change Review -> baseline lock -> heavy validation`
  - `heavy validation` 失败后，若修复触及合同字段，回 `implementer -> contract checker -> pre-validation Change Review -> baseline lock -> heavy validation`
  - `post-validation Push Readiness confirm` 发现 `source / projection / contract` 类问题时，回 `contract checker -> pre-validation Change Review -> baseline lock -> heavy validation`
  - `post-validation Push Readiness confirm` 发现 `consumer / verification / implementation` 类问题时，回 `pre-validation Change Review -> baseline lock -> heavy validation`
  - `post-validation Push Readiness confirm` 发现 baseline 口径失效或验证证据已不对应当前 diff 时，回 `baseline lock -> heavy validation`
  - `Checking` 或其他后置阶段若出现新的 review delta，必须强制 reopen `pre-validation Change Review`；不得只把 `Push Readiness` 写成 `not ready` 而不回前置审查路径
- 中途风险门只在命中高风险条件时触发，不是所有任务默认重门禁；其作用是前移高风险验证，不新增审批层。
- Linear issue body 的 `## Codex Workpad` 是唯一活真相源；活状态板、下一 gate、`baseline lock`、`blocker ledger` 与当前 review / blocker 结论只留在这里，repo 文档不复制实时值。流程指标、返工计数等派生审计数据仅在用户明确要求时才维护。
- `blocker ledger` 不默认常开；命中以下任一条件时必须在 `## Codex Workpad` 内开启并持续维护：
  - 风险判定争议
  - `contract matrix` 覆盖争议
  - 角色独立性争议
  - 任一 checker / reviewer 返回 `revise`
  - 出现 `baseline 争议`
  - 进入第二轮返工
- `blocker ledger` 最小字段固定为：
  - `blocker id`
  - `type`
  - `owner`
  - `opened by`
  - `opened at`
  - `close proof`
- `blocker ledger.type` 只允许：`contract`、`implementation`、`baseline`、`gate`。它只能附着在 `## Codex Workpad` 内，不能演化成 comment-only、PR-only、reviewer-only 的平行台账。
- 返工分流遵循最小回退原则：需求边界变化回轻量文档复核；实现缺陷和验证缺口回实现与复审，不重开整套流程。
- “小修小改”必须同时满足以下条件：修改文件不超过 2 个；不新增或删除公共接口、配置项、数据结构、工作流状态或跨模块依赖；不涉及并发、安全、权限、重试、持久化、启动流程等高风险路径；可以用定向测试或局部验证直接证明正确性。
- 这里的“零上下文复核”是指：`final zero-context reviewer` 只接收需求、计划、实现后的累计 diff、测试结果、风险说明、冻结件和必要文件，不继承作者线程的会话历史，不以前文推理过程作为判断依据。该 gate 不能用文档阶段的分析角色替代。
- 第一次 checker / reviewer 给出 `revise` 时，开启一轮返工；围绕同一 `blocker id` 的连续修复与复审，计为同一轮；原发起角色明确接受、或该 blocker 被新 blocker 取代时，该轮结束。
- 首次 `Contract Review = revise` 或 `Change Review = revise` 后，默认锁定给出该结论的原 reviewer 角色继续复审同一 `blocker id`；`contract checker` 与 `final zero-context reviewer` 的 ownership 必须分别记录，不得共用一个模糊 owner。
- 更换 reviewer 只允许在以下例外下发生：原 reviewer 不可用、审查范围或 baseline 已实质变化、需要不同专长、原 reviewer 明确放弃 ownership、或已触发二次维修停线。
- 更换 reviewer 时，必须随同该 `blocker id + reviewer 角色类型` 提供最小 handoff：上一轮 findings、已修项、待核项、当前 diff baseline；该 ownership 只绑定该 `blocker id` 下的对应 reviewer 角色，不自动扩展到整个 closeout。
- 第一次复核未通过时，只允许实现线程返工，原 checker / reviewer 负责复审。
- 若第一次返工后仍未通过，允许再进行一次返工与复审。
- 若二次维修后仍未通过，必须立即停止当前实现线程与 reviewer 线程；主线程不得亲自下场补代码救火；如需继续，重新开启一组新的实现线程与 reviewer 线程，或直接停工向用户申请帮助。
- 代码任务完成后，默认只向用户汇报原始索引与当前结论：`main session id`、角色线程 / 会话索引、`frozen artifact`、`branch` / `commit` / `PR`、`validation evidence`、review 结论、`baseline lock` / `blocker` 位置、当前状态 / 最终可放行结论。
- 除非用户明确要求，不默认汇报 agent 数、返工轮次、二次维修统计、耗时估算等派生审计数据。
- 如果上层会话规则与本仓库多 Agent 协作规则冲突，以本仓库“阶段角色制 + 角色独立性”规则为准；不得以上层限制为由跳过实现、合同检查或最终复核角色。
- 如果复核循环无法收敛、需求不清、上下文不足或判断当前工作无法稳妥完成，必须停止继续推进，向用户反馈现状并申请帮助，不得硬做。

## 文档与目标文件约束

- 当用户明确要求“在原文件中修改”“回去复制”“不要丢失上下文”时，必须先定位到该现有文件。
- 如果未能定位到用户指定的现有文件、目录或原始上下文，必须立即停止，并明确说明未找到。
- 未经用户明确允许，不得为了继续任务而自行新建替代文档、目录、章节或结构。
- 不得根据记忆、推测、相似文件或已有上下文，擅自补写用户指定但当前仓库中不存在的目标文件。
- 如果仓库内容与用户描述不一致，默认先提示用户同步仓库或提供准确路径。
- 编辑目标文件前，先检查该文件是否已有用户操作而造成的本地改动,避免二次打乱用户已经开始操作的原文件和上下文。
- 对仓库内的设计文档、spec、plan、说明文档等常规文档产物，默认视为用户已授权 agent 直接编写、修改、自检并继续后续开发流程；除非用户明确要求“先给我看文档并等待我回复/批准”，否则不得把“等待用户回应文档”当作继续实现前的硬门禁。
- 如果外部 skill、模板或流程要求“文档写完后必须等待用户 review / 回复 / 批准再继续”，在本仓库内以上一条为准，直接继续，不得因此停工。
- 本仓库文档归档以根目录 `SPEC.md` 和 `docs/` 为准；`SPEC.md` 只承载项目级总规范，`docs/` 承载人类文档归档。
- `docs/governance/` 是可复用规则层；本仓库特有的执行要求、验证要求和文档落点摘要统一写在 `AGENTS.md`；根目录 `SPEC.md` 仅用于描述本仓库系统规格，不作为通用治理模板。
- 新增 repo 文档前，先阅读 `docs/README.md` 与 `docs/governance/文档分类规则.md`，按文档类型选择落点，不得按工具名新建长期目录。
- 目录名统一使用英文；文档标题尽量使用简体中文；专有名词、命令、协议名、状态名、工具名可以保留英文。
- `Superpowers` 是方法，不是归档轴；设计、计划、验证文档默认落到 `docs/changes/<change-id>/`，事故复盘落到 `docs/incidents/`，长期愿景、路线图、未完成功能与技术路线裁决落到 `docs/initiatives/`。
- `docs/changes/<change-id>/` 的文件数量和拆分深度由作者按任务复杂度自行决定；不要为了套模板强行凑固定件数，但必须有清晰入口和不重复职责。
- `docs/changes/<change-id>/` 的入口文件必须包含稳定的“目标 / 需求快照”，至少说明要解决什么问题、成功标准、明确不做什么以及当前固定约束；目标快照用于让 reviewer 尽量不依赖 Linear 也能审查实现是否命中需求。
- 小修小改默认不新建 repo 文档；满足“小修小改”条件且可由 diff + 定向测试直接证明的任务，只在 Linear issue body / `## Codex Workpad` 保留最小执行记录。
- 下列目录视为历史归档，不再作为新文档默认落点：`docs/superpowers/`、`docs/plan_rerun_fix/`、`docs/symphony_ext_plan/`。只有在用户明确要求修改原文件或执行迁移时，才允许继续写入这些目录。
- 单次高风险变更文档放 `docs/changes/`；事故分析放 `docs/incidents/`；长期愿景、路线图、未完成功能清单和技术路线 / A-B 裁决都放 `docs/initiatives/`。
- 不是每个 bug 都升级为 `incident`；只有当问题影响真实流转、跨多个 ticket / PR / session、需要保留时间线与证据链，或根因分析具有长期复用价值时，才建立 `docs/incidents/<incident-id>/`。
- 若某个事故的代码修复本身也复杂或高风险，可同时建立 `docs/changes/<change-id>/`；`incident` 写事实与根因，`change` 写实现与验证，二者不要重复抄写。

## 本地验证分层规则

- 先看 `git diff`，再选择能证明改动正确性的最轻验证；开发阶段只跑定向测试，不把本地 `make all` 当成日常命令。
- 文档更新、只读排查、Linear 分诊或清理：开发阶段不要求跑测试；若准备 create PR / update open PR，仍需按本次 push 的 `Next Push Gate` 执行对应门禁。
- 局部代码改动：先跑定向测试；必要时补 `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix format --check-formatted`、`cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix lint` 等局部门禁。
- `Next Push Gate` 的 full-gate 判定基线统一为：本次 push 完成后，当前分支 / PR latest head 相对 PR base 的累计 diff；首开 PR 时，PR base 默认按 `origin/main` 计算；open PR update 时，禁止只看本轮未推送的小补丁。
- 普通开发分支默认按 PR-bound 处理：只要该分支后续会用于 create PR / update PR，就按上面的累计 diff 先决定 `Next Push Gate`，不能把“PR 还没创建”当作 light-validation push 的豁免理由。
- 若先前某次分支 push 曾按非 PR push 执行，后来才决定沿用同一 head 创建 PR，则必须先补跑当前应有的 `Next Push Gate`，补跑通过后才允许 create PR。
- 准备 create PR / update open PR 时，先判断上述累计 diff 是否命中 full-gate 路径：`.github/workflows/make-all.yml`、`elixir/**`、`AGENTS.md`、`SPEC.md`。
- 若本次是 PR create/update push，且该累计 diff 命中 full-gate 路径，则 `Next Push Gate` 必须是本地 `make all`；在任何 `git push` 之前，必须先完成 `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- make all`，成功后才允许 push。
- 若本次是 PR create/update push，但该累计 diff 不命中 full-gate 路径，则 `Next Push Gate` 为 closeout gate，至少包含 `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix format --check-formatted`、`cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix lint`，以及改动面对应的定向测试。
- 若本次不是 PR create/update push，则继续执行与 diff 匹配的最轻本地验证；不要为了普通非 PR push 默认升级到 `make all`。
- `make all` 不是日常开发命令，也不是复现工具；它在新制度下只绑定到“PR create/update 且命中 full-gate 路径”的本地前置硬门，以及 CI 已失败后的修复收口确认。
- 如果 CI 失败，顺序必须是：先看 CI 报错，再在本地做定向检测，随后修复问题；只要修复后的下一次 push 仍是 open PR update，且更新后的分支 / PR head 相对 PR base 的累计 diff 命中 full-gate 路径，就必须在再次 push 前重新跑本地 `make all`。
- GitHub / CI 在命中 `.github/workflows/make-all.yml`、`elixir/**`、`AGENTS.md`、`SPEC.md` 这些路径时继续执行完整 `make all` 作为远端 full gate；它是最终复核器，不是第一次暴露 coverage、dialyzer 等问题的主要发现器。新制度下，首次远端 full-gate 红灯默认视为本地门禁未执行到位、执行方式不合规，或存在需要升级处理的环境漂移/不稳定性。
- 最高警戒：每次本地测试命令结束后，必须立即检查并关闭该轮测试显式拉起的测试线程、fake worker、background server、端口占用、临时文件/目录/日志、测试注入的环境变量和配置覆写以及其他垃圾状态；不得把清理动作延后到下一轮测试前，更不得在已知有残留时继续叠加新测试。

## 本地测试并发约定

- 本地所有测试命令都必须显式带 `SYMPHONY_TEST_MAX_CASES`，不得吃默认值；默认统一用 `SYMPHONY_TEST_MAX_CASES=4`。
- 本地 ExUnit 并发必须显式受控；`SYMPHONY_TEST_MAX_CASES` 不得高于 `4`，资源吃紧时自动降到 `2`，仍不稳再降到 `1`。
- 例如：`cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/some_targeted_test.exs`、`cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- make all`。
- 该约定仅用于本地执行，不得修改 CI 默认行为，不得借此降低 coverage threshold，也不得删测试。
- 覆盖率长期策略采用“总门槛放宽、关键模块加严、逐步棘轮收紧”：仓库总覆盖率硬门槛为 `>= 98%`，关键模块名单、tier 规则、diff coverage 与 `ignore_modules` 审计规则以 `docs/initiatives/SPEC/33_质量门禁与验收边界.md` 为准。
- 凡是触达关键模块的改动，覆盖率不得低于该模块当前 baseline；新增 public function、状态分支、重试/降级/恢复分支必须补直接命中的测试，不能只靠旁路集成路径顺带覆盖。
- 在覆盖率 tier 校验和 diff coverage 自动化脚本正式设计并接入前，不得私自引入平行 gate、私有阈值或与 `make all` / `Next Push Gate` 冲突的本地 helper；若脚本方案与现有门禁顺序或 coverage 真相源冲突，必须先回到人类裁决。

## 测试安全红线

- WSL 被卡死的主要根因是测试隔离失效，真实 runtime worker 与外部进程链路混入测试；这不是 Elixir 语言本身的问题。
- 测试环境禁止默认启动任何会轮询、起外部进程、开端口、走 SSH、连真实 Linear/Codex 的 child。
- 这类组件只能在具体测试里显式 `start_link`，并且必须用 `on_exit` 或等效机制彻底回收。
- 凡是测试中启动了 fake worker、测试线程、端口监听或其他临时进程，测试结束后必须立即清理；把“测试结束立刻回收干净”视为最高警戒，严禁残留到下一轮命令。
- 重型测试和 `make all` 必须带监控，至少覆盖：内存持续升高、swap 持续增长、CPU 长时间打满且不回落、子进程/端口/worker 异常增长、系统明显卡顿或失去响应风险。
- 一旦监控发现资源不足，处理顺序固定：立即停止当前重型测试，回收现场，把并发从 `4` 降到 `2`，仍不稳则降到 `1`，`1` 还不稳就停止并报告机器承载不了当前 full gate。
- 测试不得把仓库真实 `WORKFLOW.md` 当成默认运行配置。
- 凡是涉及 `Port.open`、`ssh`、`codex app-server`、`docker`、fake worker 的测试，必须显式检查并发度、进程清理和资源回收，不能把全局 supervisor 当成免费启动器。
- 本地测试结束后必须做现场回收，确认没有残留 worker / fake worker / background server、残留端口占用、临时文件/目录/日志、测试注入的环境变量和配置覆写，确保不会污染下一轮命令。
