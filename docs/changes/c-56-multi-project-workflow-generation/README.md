# C-56 多项目 Workflow 生成与配置外提

## 目标

把当前通用 `elixir/WORKFLOW.md` 中仍然写死的项目级绑定信息最小成本外提到
`symphony.projects.yaml`，并在控制面启动 worker 前为每个项目生成各自的
`WORKFLOW.generated.md`，先让 `powersymphony` 和 `linear-agents` 两个项目能按各自
配置启动而不串线。

## 需求快照

### 要解决什么问题

- 当前多项目控制面虽然有 `symphony.projects.yaml`，但项目级合同仍有三处写死在通用
  `elixir/WORKFLOW.md`：
  - `tracker.project_slug`
  - `workspace.root`
  - `hooks.after_create` 里的 clone 仓库地址
- 当前 `ProjectConfigStore` 只接受 M1 窄 schema，不接受 `defaults`、`workflow_source`、
  `project_slug`、`repo_url` 等本轮所需字段。
- 当前 `ProjectProcessManager` 只认磁盘上已存在的 `workflow_generated`，缺失时直接把
  项目标成 `config_invalid`，没有“启动前先生成 generated workflow”的路径。
- 如果不改以上链路，多项目控制面只会“多两行配置”，但第二个项目仍会沿用第一个项目的
  `project_slug`、workspace 根路径和 clone 地址，无法真实运行。

### 成功标准

1. `symphony.projects.yaml` 支持同时声明 `powersymphony` 与 `linear-agents`。
2. 项目级 `project_slug` 不再写死在通用 `elixir/WORKFLOW.md`。
3. 项目级 clone 地址不再写死在通用 `elixir/WORKFLOW.md`。
4. 控制面能基于通用 `workflow_source` 为每个项目生成隔离的
   `WORKFLOW.generated.md`。
5. 两个项目的 generated 路径不同。
6. 两个项目的 `workspace_root` 不同。
7. 两个项目的 `logs_root` 不同。
8. `ProjectProcessManager` 在启动 worker 前能走“先生成 generated workflow 再启动”的
   路径，而不是把 generated 缺失直接投影成 `config_invalid`。
9. `powersymphony` 与 `linear-agents` 能按各自配置启动，不串 `project_slug`、
   `workspace.root`、`repo_url`。

### 明确不做什么

- 不统一单项目入口，不改 `bin/symphony` 默认语义。
- 不重开完整 workflow 模块化 compiler 工程。
- 不做 Web 可视化 prompt 编辑器。
- 不引入复杂模板语言或全量的 stale 检测体系。
- 不把所有项目 prompt/rules 搬进控制面配置。

### 固定约束

- 只保留一份人维护的通用 workflow 源文件：`elixir/WORKFLOW.md`。
- worker 继续只读取 generated 文件，控制面继续按 `workflow_generated` 启动单项目
  worker。
- 根 `elixir/WORKFLOW.md` 仍保留为 `control_plane` 公共配置源，但不再作为项目级绑定
  的 source of truth。
- 本轮允许采用“最小桥接方案”：
  - 读取单一 `workflow_source`
  - 对 frontmatter 中的项目级绑定字段做受控替换 / 注入
  - 输出每项目自己的 `WORKFLOW.generated.md`
- 项目配置模板字段必须先渲染为绝对路径，再做现有 path safety 校验。
- 本轮冻结的项目数据如下：
  - `powersymphony`
    - `project_slug`: `03b2b4a16461`
    - `repo_url`: `https://github.com/youdaowudao/PowerSymphony.git`
    - `worker_port`: `4101`
  - `linear-agents`
    - `project_slug`: `327e2b00c1cd`
    - `repo_url`: `https://github.com/youdaowudao/linear-agents.git`
    - `worker_port`: `4102`

## 任务类型识别

- 类型：代码变更，且已命中 `观察层合同风险`。
- 命中原因：
  - 同一项目语义会被多个消费面读取：`symphony.projects.yaml`、静态 registry、
    generated workflow frontmatter、控制面启动链、单项目 worker 运行时。
  - 存在明确的 projection 链：静态 YAML -> 归一化配置 -> generated workflow ->
    `Config.settings!()` -> `Workspace` / `Tracker` / hooks / `Linear.Client`。
  - 一旦字段来源或允许变换不清晰，就会出现“控制面显示是项目 B，但 worker 实际按项目
    A 配置运行”的跨消费面串线问题。

## Source-of-Truth Chain

| 关键字段 / 语义 | 实际 source | 中间 projection | 最终 consumer |
| --- | --- | --- | --- |
| `tracker.project_slug` | `symphony.projects.yaml` 项目级 `project_slug` | `ProjectConfigStore` 归一化 -> workflow generator 注入 generated frontmatter | worker `Config.settings!().tracker.project_slug`、`Linear.Client`、`Orchestrator` |
| `hooks.after_create` clone 仓库地址 | `symphony.projects.yaml` 项目级 `repo_url` | `ProjectConfigStore` 归一化 -> workflow generator 生成按项目 `after_create` | `Workspace` 创建工作区时执行的 hook |
| `workspace.root` | `defaults.workspace_root_template` 渲染结果或项目显式覆盖 | `ProjectConfigStore` 模板渲染与路径归一化 -> workflow generator 注入 generated frontmatter | worker `Config.settings!().workspace.root`、`Workspace`、`Codex.AppServer` |
| `workflow_source` / `workflow_generated` | `defaults.workflow_source`、`defaults.workflow_generated_template` 与项目显式覆盖 | `ProjectConfigStore` 渲染与归一化 -> `ProjectRegistry` -> `ProjectProcessManager` | 启动前生成器输入 / 输出路径、worker 启动命令 |
| `logs_root` | `defaults.logs_root_template` 渲染结果或项目显式覆盖 | `ProjectConfigStore` 模板渲染与路径归一化 -> `ProjectRegistry` -> `ProjectProcessManager` | worker 启动命令、控制面运行时目录 |
| `worker_port` | `symphony.projects.yaml` 项目级 `worker_port` | `ProjectConfigStore` 归一化 -> `ProjectRegistry` -> `ProjectProcessManager` | worker 启动命令、health poller、控制面展示 |

## contract matrix

| field / view | source of truth | allowed transform | must not infer |
| --- | --- | --- | --- |
| `project_slug` | 项目级 `project_slug` | 仅允许经 `ProjectConfigStore` 归一化后注入 generated frontmatter 的 `tracker.project_slug` | 不得回退到通用源文件里的旧硬编码，不得按项目名、id 或已有 worker 状态推断 |
| `repo_url` / `hooks.after_create` | 项目级 `repo_url` | 允许固定生成标准 clone hook 文本 | 不得复用通用源文件里已有的 clone 地址，不得按 `project_id` 拼接猜测远端 |
| `workspace_root` | 模板渲染结果或项目显式覆盖 | 允许 `{{ project_id }}` 模板替换、`Path.expand`、`PathSafety.canonicalize` | 不得直接把模板字符串当最终路径，不得从通用 workflow 旧值继承 |
| `workflow_generated` | 模板渲染结果或项目显式覆盖 | 允许模板替换、绝对路径归一化、启动前写盘覆盖 | 不得要求用户手工预先生成，不得因“文件尚未生成”直接判定整项配置无效 |
| `logs_root` | 模板渲染结果或项目显式覆盖 | 允许模板替换与绝对路径归一化 | 不得从 workspace 路径、项目名或旧默认值推断 |
| 启动前 generated workflow 可用性 | `workflow_source` + 项目级绑定字段 | 允许在 `start_project` 路径中按需生成 / 覆盖 generated 文件 | 不得把“generated 缺失”与“静态配置不合法”混为同一种 `config_invalid` 语义 |

## 实现边界

- 预期变更文件：
  - `symphony.projects.example.yaml`
  - `elixir/WORKFLOW.md`
  - `elixir/lib/symphony_elixir/project_config.ex`
  - `elixir/lib/symphony_elixir/project_config_store.ex`
  - `elixir/lib/symphony_elixir/project_registry.ex`（若 entry 需携带新增字段）
  - `elixir/lib/symphony_elixir/project_process_manager.ex`
  - 新增 workflow 生成模块（路径待实现线程在冻结边界内确定）
  - 对应 `elixir/test/**`
- 默认回退顺序：
  - 若修复仅触及生成时机或实现细节，不改合同字段，则走
    `implementer -> baseline lock -> heavy validation -> reviewer`
  - 若修复触及 `project_slug` / `repo_url` / `workspace_root` /
    `workflow_generated` / `logs_root` 语义，则必须重过 `contract checker`

## 红蓝补充结论

### control_plane 对根 WORKFLOW 的依赖边界

- 完整 `control_plane` 子树仍会读取根 `elixir/WORKFLOW.md`，但当前确认的硬依赖只剩：
  - `control_plane.health_poll_interval_ms`
  - `control_plane.health_check_timeout_ms`
- 这两项在 schema 中已有默认值，因此根 workflow 只要“文件存在且 frontmatter 可解析为
  map”，就不会因为移除项目级三项硬编码而让 `control_plane` 自身启动失败。
- 这不等于可以删除根 `elixir/WORKFLOW.md`，也不等于可以把整个文件替换成无效模板。

### 单项目旁路兼容风险

- `bin/symphony_start` 仍直接指向 `elixir/WORKFLOW.md`，因此是本轮显式兼容风险面。
- 本轮实现应尽量保住“根 workflow 文件仍可被单项目入口消费”的最低兼容性；若无法完全
  保住旧行为，必须用测试或注释把边界钉清楚，禁止静默破坏。

### 前移验证优先级

1. `start_project` 在 generated 缺失时先生成再启动，而不是直接 `config_invalid`。
2. 新 schema 到 normalized config / registry entry 的 round-trip。
3. 两项目 generated workflow 的 golden / runtime 读取校验，至少覆盖：
   - `tracker.project_slug`
   - `workspace.root`
   - `hooks.after_create`

## 冻结说明

- 本文件是本轮 `frozen artifact`。
- 后续实现、合同检查、最终零上下文复核只复用：
  - 本冻结件
  - 累计 diff
  - 验证摘要
  - blocker / baseline 证据
- 若后续需要改变用户可见行为、合同边界或风险判定，必须显式重冻本文件，不能静默扩写。
