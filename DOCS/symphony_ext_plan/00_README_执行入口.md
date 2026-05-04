# Symphony 二次开发计划书：执行入口

版本：v1.0  
日期：2026-05-03  
适用对象：个人 WSL 环境，基于 OpenAI Symphony Elixir 原型机进行二次开发。  
主线：只做官方 Elixir 原型机二开，不做换语言重写。

---

## 0. 一句话定盘

把 OpenAI Symphony Elixir 原型机二开成一个**多项目 Codex 执行控制台**：

- 每个项目仍然运行一套单项目 Symphony worker。
- 新增一个控制面统一管理多个项目 worker。
- Web 前端只默认展示轻量摘要；详细事件、原始 payload、长日志必须点击后按需加载。
- `WORKFLOW.md` 不取消，改成人维护模块化源文件，运行时使用生成后的 `WORKFLOW.generated.md`。
- 后续所有 AI 执行都沿这个方向，不再讨论换语言。

---

## 1. 文件阅读顺序

建议按下面顺序交给 AI 阅读：

1. `01_路线决策与二次复核.md`
2. `02_Superpower_前置头脑风暴.md`
3. `03_总体计划_里程碑.md`
4. `04_架构设计_多项目控制面.md`
5. `05_Web与Codex线程观测设计.md`
6. `06_Workflow模块化生成方案.md`
7. `07_质量门禁与验收标准.md`
8. `08_AI执行手册_交付提示词.md`
9. `09_资料来源与复核报告.md`

`10_组合版_总计划.md` 是全部文档合并版，适合一次性喂给上下文较长的 AI。

### M1 必读参考集合

M1 执行时，以下 5 份文档构成唯一的主执行参考集合：

1. `00_README_执行入口.md`：执行入口、硬约束和阶段入口说明。
2. `01_路线决策与二次复核.md`：路线确认，以及为什么不做同进程多 Orchestrator。
3. `03_总体计划_里程碑.md`：阶段划分、M1 范围和 M2 进入点。
4. `04_架构设计_多项目控制面.md`：Control Plane 管理多个单项目 OS worker 的架构边界。
5. `07_质量门禁与验收标准.md`：兼容性、隔离性和阶段门禁。

补充约定：

- `10_组合版_总计划.md` 仅用于长上下文一次性阅读，不高于上述 5 份主参考文档。
- `05_Web与Codex线程观测设计.md`、`06_Workflow模块化生成方案.md` 对 M1 只作为后续阶段预告，不构成当前实现范围授权。
- `08_AI执行手册_交付提示词.md` 和 `09_资料来源与复核报告.md` 用于执行提示和复核，不替代阶段边界定义。

### M1 基线冻结边界

本轮冻结后的 M1 统一边界如下：

- M1 允许范围：仓库初始化与远端同步、文档基线确认、`symphony.projects.yaml` 静态配置模型、`ProjectRegistry` 占位状态、`symphony_control` CLI / 控制面骨架、阶段门禁。
- M1 明确不做：真实 worker 启停、健康检查、stdout / stderr 日志落盘、Codex 线程事件采集、Trace / RawEventStore、Workflow 模块化生成。
- M1 仍然不做：换语言重写、重写官方核心执行链路、同进程多 Orchestrator。
- M2 才进入：Project Worker OS 进程生命周期管理，以及其配套的健康检查、日志落盘和运行态管理。
- 兼容性基线：整个 M1 期间必须持续保持原单项目命令 `./bin/symphony ./WORKFLOW.md` 可用。

---

## 2. 最重要的二次复核调整

我在复核官方源码后，把多项目实现方式从“同一个 BEAM 进程内启动多个 Orchestrator”收紧为：

> **控制面管理多个单项目 Symphony OS worker。**

原因：当前官方源码里 `Workflow`、`Config`、`WorkflowStore` 明显以单全局工作流为中心：CLI 只接收一个 workflow path，`Workflow` 从 `Application.get_env(:symphony_elixir, :workflow_file_path)` 取全局路径，`WorkflowStore` 以模块名注册成单例。直接改成 in-process 多项目，会先撞上全局状态去耦合，风险比预期大。

因此第一版多项目应采用更稳的形态：

```text
Control Plane
  ├─ 管理 symphony.projects.yaml
  ├─ 为每个项目生成/校验 WORKFLOW.generated.md
  ├─ 为每个项目分配 logs_root 与内部 API port
  ├─ 启动/停止/重启每个单项目 Symphony worker 进程
  └─ Web 聚合各 worker 的轻量 summary

Project Worker A
  └─ 原单项目 Symphony，读取项目 A 的 WORKFLOW.generated.md

Project Worker B
  └─ 原单项目 Symphony，读取项目 B 的 WORKFLOW.generated.md
```

这个方案更符合“别把多项目能力塞进一个核心 Orchestrator”的原则，也更利于避免项目之间状态串线。

---

## 3. 交给 AI 执行时的总提示词

可以把下面这一段作为每轮 AI 执行的固定前缀：

```text
你正在基于 OpenAI Symphony Elixir 原型机做二次开发。禁止换语言，禁止全量重写，禁止把多个项目塞进一个核心 Orchestrator。主线是：新增多项目 Control Plane，管理多个单项目 Symphony worker；每个 worker 仍读取自己的 WORKFLOW.generated.md、logs_root、workspace_root、内部 API port。Web 总览页只能读取轻量 summary，不允许默认拉取 raw event、完整 timeline、完整 prompt、完整 shell output。Codex 线程观测必须通过后端 state reducer 生成 phase/action/health，再给前端展示。每轮修改必须先按当前阶段要求执行：阶段 1 先完成创建仓库、阅读文档、确认方向和骨架搭建；从阶段 2 起必须先读当前源码和相关测试，再给出设计差异、修改文件、测试命令、回滚方式。不要生成小型任务列表，按本文档的阶段和质量门禁推进。
```

---

## 4. 不允许偏离的硬约束

1. **不换语言。** 只做 Elixir 原型机二开。
2. **不重写核心执行链路。** Orchestrator / AgentRunner / Codex AppServer 的主行为先保留。
3. **多项目先用 OS worker 隔离。** 不在第一版做 in-process 多 Orchestrator。
4. **前端默认只看摘要。** Raw event / payload / prompt / shell output 全部懒加载。
5. **状态由后端推导。** 前端不从原始 Codex 事件自行推理。
6. **每项目独立 workflow。** 控制面只管项目列表，不接管所有 prompt/rules/hooks。
7. **WORKFLOW 是生成物，不是消失。** 人维护模块化源文件，worker 读取 generated 文件。
8. **质量门禁先于功能堆叠。** 没有 summary API、trace 分层、回归测试，不继续扩 Web 细节。

---

## 5. 最小可交付目标

第一版不追求复杂产品化，只交付一个可干活的本地控制台：

- 能从 `symphony.projects.yaml` 读取多个项目。
- 能启动/停止/重启每个项目的单项目 worker。
- 能在 Web 上看到所有项目的轻量状态。
- 能进入某个项目，看运行中的 issues/runs。
- 能进入某个 run，看 Codex 线程当前 phase/action/health。
- 能按需打开 timeline、event detail、raw payload。
- 能用模块化 workflow 源文件生成 `WORKFLOW.generated.md`。
- 能通过质量门禁验证“没有把后台重信息默认推到前端”。
- 第一阶段至少能让控制面管理 2 个项目，并保持各项目 `workflow`、`workspace`、日志和运行状态独立。

---

## 6. 文件如何落地成后续工作

后续让 AI 执行时，不要直接说“帮我改一下”。应该按阶段说：

```text
请按照《03_总体计划_里程碑.md》的第 1 阶段执行。执行前必须阅读《01_路线决策与二次复核.md》《04_架构设计_多项目控制面.md》《07_质量门禁与验收标准.md》。这轮只允许完成创建仓库、阅读项目文档、确认方向和控制面骨架；控制面至少能管理 2 个项目，并保持各项目 workflow、workspace、日志和运行状态独立。不要提前做 Codex trace UI。
```

每轮结束要求 AI 输出：

- 修改了哪些文件；
- 保持了哪些原型机行为不变；
- 增加了哪些测试；
- 跑了哪些命令；
- 哪些质量门禁通过；
- 如何回滚。
