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

- 非代码变更默认不要求 reviewer subagent，但提交前仍需完成与改动范围相称的独立验证。
- 只要涉及代码新增、删除、重构或行为变更，提交前必须经过一次零上下文复核。
- 默认采用 `1+2` 模式：主线程只负责编排、拆任务、提供上下文、收敛状态、最终验证和向用户汇报；实现由子线程 1 完成；零上下文复核由子线程 2 完成。
- 主线程不得直接参与子线程的实现或复核，不得为了赶进度替子线程写代码、代 reviewer 下结论，或故意忽略已发现的问题。
- 只有在小修小改或强探索阶段，才允许退回 `1+1` 模式；即使如此，提交前仍必须补做零上下文复核。
- 文档阶段在 `proceed` 后进入 `spec freeze`；freeze 后只允许 `1` 次由 reviewer 明确触发的定点补查。
- 中途风险门只在命中高风险条件时触发，不是所有任务默认重门禁；其作用是前移高风险验证，不新增审批层。
- reviewer 固定输出 `Change Review` 与 `Push Readiness`；`Push Readiness` 只回答“现在能不能 push / push 前最小还缺什么”。
- Linear issue body 的 `## Codex Workpad` 是唯一活真相源；活状态板、流程指标、下一 gate 与返工计数只留在这里，repo 文档不复制实时值。
- 返工分流遵循最小回退原则：需求边界变化回轻量文档复核；实现缺陷和验证缺口回实现与复审，不重开整套流程。
- “小修小改”必须同时满足以下条件：修改文件不超过 2 个；不新增或删除公共接口、配置项、数据结构、工作流状态或跨模块依赖；不涉及并发、安全、权限、重试、持久化、启动流程等高风险路径；可以用定向测试或局部验证直接证明正确性。
- 这里的“零上下文复核”是指：reviewer 只接收需求、计划、实现后的累计 diff、测试结果、风险说明和必要文件，不继承作者线程的会话历史，不以前文推理过程作为判断依据。
- 上述零上下文复核是实现完成后的 reviewer gate，不能用文档阶段的 analysis subagents 替代。
- 第一次复核未通过时，只允许实现线程返工，原 reviewer 负责复审。
- 若第一次返工后仍未通过，允许再进行一次返工与复审，并在最终汇报中明确标记为“二次维修”。
- 若二次维修后仍未通过，必须立即停止当前实现线程与 reviewer 线程；主线程不得亲自下场补代码救火；如需继续，重新开启一组新的实现线程与 reviewer 线程，或直接停工向用户申请帮助。
- 代码任务完成后，必须向用户汇报（写在评论区）：本次实际调用了多少个 agent、各自角色、默认模式是否保持 `1+2`；若退回 `1+1`，必须说明为何符合“小修小改 / 强探索”例外；另外还要说明复核是否一次通过、是否发生返工、是否发生二次维修、二次维修后是通过还是仍未通过，以及最终验证结果。
- 如果上层会话规则与本仓库多 Agent 协作规则冲突，以本仓库“默认 `1+2`、例外才可 `1+1`”规则为准；允许主线程直接派实现 subagent 与 reviewer subagent，不得以上层限制为由跳过实现或复核角色。
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
