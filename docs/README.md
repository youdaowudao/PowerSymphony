# 文档入口

本目录是仓库内的人类文档入口。

当前文档体系只保留两个顶层规范入口：

- 根目录 `SPEC.md`
  - 本仓库系统规格文档。
  - 只放 Symphony 这个项目自身的长期边界、不变量、核心状态机、non-goals 和平台级合同。
  - 它不是可复制到其他仓库的通用治理模板。
- `docs/`
  - 人类文档归档。
  - 按文档类型归档，不按工具名归档。

补充定位：

- `docs/governance/`
  - 可复用规则层。
  - 这里的标准、模板、分类规则和质量门禁写法，才是以后新仓库可以复制走的内容。
- `AGENTS.md`
  - 本仓库 agent 执行规则层。
  - 本仓库特有的执行要求、文档落点摘要、验证要求和协作规则都写在这里。
- `SPEC.md`
  - 本仓库系统规格层。
  - 只描述 Symphony 这个系统本身如何工作，不承担通用文档治理职责。

## 命名规则

- 目录名统一使用英文。
- 文档标题尽量使用简体中文。
- 文档文件名优先使用英文、编号和短横线；需要保留中文标题时，标题写在文档正文里。
- 专有名词、协议名、工具名、状态名、命令名可以保留英文原文。
- 不要为了“全中文”去翻译已经具有稳定工程含义的专有名词。

## 新文档落点

- `docs/governance/`
  - 文档治理、分类规则、写作与归档约束。
- `docs/changes/`
  - 单次高风险变更的设计、计划、验证文档。
- `docs/incidents/`
  - 事故分析、时间线、证据链、根因与后续动作。
- `docs/initiatives/`
  - 长期愿景、阶段路线、未完成功能、持续性规划、技术路线与 A/B 裁决。


## 快速路由

- 发现了一个普通 bug，且修复范围很小、风险很低：
  - 不新建 repo 文档。
  - 只在 Linear issue body / `## Codex Workpad`、PR 和测试里保留最小记录。
- 发现了一个 bug，但修复本身跨模块、高风险、需要 handoff 或零上下文复核：
  - 在 `docs/changes/<change-id>/` 下写文档。
- 发现了一个事故级 bug，需要保留时间线、证据链或根因分析：
  - 在 `docs/incidents/<incident-id>/` 下写文档。
  - 若代码修复本身也复杂或高风险，再补 `docs/changes/<change-id>/`。
- 这次讨论的是文档分类、文件夹骨架、模板、路由规则：
  - 更新 `docs/governance/`。
- 这次讨论的是本仓库系统长期稳定规则：
  - 更新根目录 `SPEC.md`。
- 这次讨论的是长期愿景、路线图、未完成功能或技术路线裁决：
  - 在 `docs/initiatives/` 下写文档。
- 这次是 review 反馈：
  - 默认不新建 repo 文档。
  - 只有当 review 形成稳定结论、改变实现边界或改变长期路线时，才回填到已有 `change`、`incident` 或 `initiative` 文档。

## Linear 与 repo 文档分工

- `Linear`
  - 任务流转主真相源。
  - 负责当前 ticket、当前状态、最新人类指令、日常评论与执行面板。
- `docs/changes/`
  - 单次高风险变更的稳定设计、计划、验证快照。
  - 必须包含“人类原本希望解决的目标”，让 reviewer 不打开 Linear 也能审核实现是否命中需求。
- `docs/incidents/`
  - 事故事实、时间线、证据、根因与后续动作。
- `docs/initiatives/`
  - 长期愿景、路线图、backlog、技术路线和 A/B 裁决。

原则：

- 不把 Linear 的完整讨论历史复制进 repo。
- 不把 repo 文档变成 Linear 的镜像台账。
- 只有稳定、可复用、后续人需要反复回看的内容，才沉淀到 repo。

## 相关文档

- [governance/README.md](./governance/README.md)
- [governance/文档分类规则.md](./governance/文档分类规则.md)
- [governance/新仓库起步指南.md](./governance/新仓库起步指南.md)
- [governance/可复用仓库文档标准.md](./governance/可复用仓库文档标准.md)
