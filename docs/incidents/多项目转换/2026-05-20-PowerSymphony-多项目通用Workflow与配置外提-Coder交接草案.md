# PowerSymphony 多项目通用 Workflow 与配置外提 Coder 交接草案

更新日期：`2026-05-20`

## 1. 当前目标

这一轮只做多项目控制面方向，不处理单项目入口统一。

当前目标是：

- 保留一份**人维护的通用 workflow 源文件**
- 在项目启动前，按项目配置生成各自的 `WORKFLOW.generated.md`
- 让多项目控制面按项目配置启动不同 worker
- 把当前写死在 `WORKFLOW.md` 里的项目绑定信息外提到 YAML

本轮先支持两个项目：

- `powersymphony`
- `linear-agents`

## 2. 为什么这轮必须交给 Coder

这不是简单补一个 `symphony.projects.yaml` 就结束的事。

当前仓库真实绑定点如下：

1. 单项目 worker 读取的是某个具体 workflow 文件，而不是 `symphony.projects.yaml`
2. `tracker.project_slug` 当前从 workflow 读取
3. `workspace.root` 当前从 workflow 读取
4. `after_create` hook 里的仓库克隆地址当前也写死在 workflow 里

因此如果只在控制面配置里加第二个项目，而不改 workflow 绑定方式：

- 第二个项目会沿用第一个项目的 `project_slug`
- 第二个项目会沿用第一个项目的 `git clone` 地址
- 多项目只是“项目表多了两行”，不是真正可运行

## 3. 已确认的代码事实

### 3.1 当前 `WORKFLOW.md` 里已经写死的项目绑定信息

当前文件：

- [elixir/WORKFLOW.md](/home/ss/projects/powersymphony/elixir/WORKFLOW.md:1)

已确认写死内容：

- `tracker.project_slug: "03b2b4a16461"`  
  证据：[WORKFLOW.md](/home/ss/projects/powersymphony/elixir/WORKFLOW.md:4)

- `workspace.root: ~/projects/symphony-workspaces`  
  证据：[WORKFLOW.md](/home/ss/projects/powersymphony/elixir/WORKFLOW.md:20)

- `after_create` 中写死 `PowerSymphony.git`  
  证据：[WORKFLOW.md](/home/ss/projects/powersymphony/elixir/WORKFLOW.md:26)

### 3.2 控制面当前真正使用的项目配置字段

当前 `ProjectConfigStore` 只要求：

- `id`
- `name`
- `workflow_generated`
- `workspace_root`
- `logs_root`
- 可选 `enabled`
- 可选 `worker_port`

证据：

- [project_config_store.ex](/home/ss/projects/powersymphony/elixir/lib/symphony_elixir/project_config_store.ex:19)

并且当前根级 schema 只允许：

- `projects`

不接受：

- `defaults`
- 模板字段
- `project_slug`
- `repo_url`
- `workflow_source`

也就是说，本轮不只是“补配置值”，而是要扩展静态项目配置合同本身。

证据：

- [project_config_store.ex](/home/ss/projects/powersymphony/elixir/lib/symphony_elixir/project_config_store.ex:18)
- [project_config_store.ex](/home/ss/projects/powersymphony/elixir/lib/symphony_elixir/project_config_store.ex:124)
- [project_config_store.ex](/home/ss/projects/powersymphony/elixir/lib/symphony_elixir/project_config_store.ex:253)

### 3.3 控制面启动 worker 的真实命令

控制面最终仍然是把项目的 generated workflow 路径塞给单项目入口：

```bash
./bin/symphony --logs-root <logs_root> --port <worker_port> <workflow_generated>
```

证据：

- [project_process_manager.ex](/home/ss/projects/powersymphony/elixir/lib/symphony_elixir/project_process_manager.ex:1064)

### 3.4 仓库原始长期设计与本轮方向并不冲突

仓库原始设计本来就是：

- 人维护源文件
- 编译为 `WORKFLOW.generated.md`
- worker 只读取 generated 文件
- 控制面只知道 source / generated 路径

证据：

- [32_Workflow生成方案.md](/home/ss/projects/powersymphony/docs/initiatives/SPEC/32_Workflow生成方案.md:3)
- [32_Workflow生成方案.md](/home/ss/projects/powersymphony/docs/initiatives/SPEC/32_Workflow生成方案.md:240)

## 4. 本轮冻结后的目标形状

### 4.1 人维护层

只保留一份通用源文件：

- `workflow_source = /home/ss/projects/powersymphony/elixir/WORKFLOW.md`

这份源文件今后不能再写死项目绑定项。

### 4.2 运行时层

每个项目启动前，按项目配置生成自己的：

- `WORKFLOW.generated.md`

worker 只读取 generated 文件，不再直接读取通用源文件。

### 4.3 配置真相源

项目级绑定信息迁到 `symphony.projects.yaml`。

本轮至少外提：

- `project_slug`
- `repo_url`
- `workspace_root`
- `workflow_generated`
- `worker_port`
- `logs_root`

## 5. 运行产物路径策略

### 5.1 推荐策略

`WORKFLOW.generated.md` 作为运行时产物，不放在 `powersymphony` 仓库根目录，也不混在源文件旁边。

推荐放入独立运行产物目录：

```text
/home/ss/projects/symphony-runtime/<project_id>/WORKFLOW.generated.md
```

对应日志目录：

```text
/home/ss/projects/symphony-runtime/<project_id>/logs
```

这样做的原因：

- 它是运行时产物，不是人维护源文件
- 不污染项目源码仓库
- 每个项目路径清晰隔离
- 重启时可直接覆盖

### 5.2 覆盖规则

- 启动前重新生成
- 如已存在则覆盖
- 停止时不强制删除
- 下次启动时继续覆盖更新

## 6. 推荐的 YAML 目标形状

本轮建议的目标形状如下：

```yaml
defaults:
  workflow_source: /home/ss/projects/powersymphony/elixir/WORKFLOW.md
  workspace_root_template: /home/ss/projects/symphony-workspaces/{{ project_id }}
  workflow_generated_template: /home/ss/projects/symphony-runtime/{{ project_id }}/WORKFLOW.generated.md
  logs_root_template: /home/ss/projects/symphony-runtime/{{ project_id }}/logs

projects:
  - id: powersymphony
    name: PowerSymphony
    enabled: true
    project_slug: "03b2b4a16461"
    repo_url: "https://github.com/youdaowudao/PowerSymphony.git"
    worker_port: 4101

  - id: linear-agents
    name: Linear Agents
    enabled: true
    project_slug: "327e2b00c1cd"
    repo_url: "git@github.com:youdaowudao/linear-agents.git"
    worker_port: 4102
```

## 7. 本轮对 Coder 的明确要求

### 7.1 必须实现

1. 支持从 `symphony.projects.yaml` 读取项目级 `project_slug`
2. 支持从 `symphony.projects.yaml` 读取项目级 `repo_url`
3. 支持根据模板生成：
   - `workspace_root`
   - `workflow_generated`
   - `logs_root`
4. 扩展 `ProjectConfigStore`，让它接受新的根级 `defaults` 和新的项目字段
5. 支持用通用 `workflow_source` 生成按项目隔离的 `WORKFLOW.generated.md`
6. 生成时把项目级绑定项注入 generated 文件，使 worker 最终读到的 frontmatter 正确
7. `after_create` 里不能再写死 `PowerSymphony.git`，必须改成按项目 `repo_url` 生成
8. worker 启动前如果 generated 文件缺失，控制面需要明确走“先生成再启动”路径，而不是直接落到现有 `config_invalid`
9. 多项目控制面可用这两项配置启动：
   - `powersymphony`
   - `linear-agents`

### 7.2 推荐的最小实现思路

本轮不要求立刻做复杂模块化 compiler。

允许采用最小桥接方案：

- 读取单一 `workflow_source`
- 对其中的项目级绑定字段做受控替换 / 注入
- 输出每项目自己的 `WORKFLOW.generated.md`
- 控制面继续按 `workflow_generated` 启动 worker

换句话说：

- 本轮先解决“多项目真的能跑”
- 不要求一步到位把 workflow 拆成完整 `manifest/frontmatter/body` 多文件系统

### 7.3 当前容易漏掉、但必须显式处理的点

1. **配置合同升级不是纯加字段**
   - 当前 `ProjectConfigStore` 明确只接受 `projects` 根字段，且项目字段白名单很窄。
   - 所以本轮必须同步修改配置解析、校验和归一化逻辑，不能只改 `symphony.projects.yaml` 示例。

2. **`config_invalid` 判定链会被新流程撞到**
   - 当前 `ProjectProcessManager` 只要发现 `workflow_generated` 文件不存在，就会把项目视作 `config_invalid`。
   - 如果改成“启动前生成 generated 文件”，就要明确：
     - 是在 start 之前先生成
     - 还是在 `config_invalid` 之前插入自动生成分支

3. **模板字段要明确是渲染后再落绝对路径**
   - 当前路径校验要求绝对路径。
   - 所以 `workspace_root_template` / `workflow_generated_template` / `logs_root_template` 不能直接复用现有路径校验，必须先渲染再校验。

4. **通用 workflow 里不止一个硬编码**
   - 当前至少要外提：
     - `tracker.project_slug`
     - `after_create` 的 `repo_url`
     - `workspace.root`
   - 如果只抽 `project_slug`，第二个项目仍会拉错仓库或工作区串线。

## 8. 本轮不做的事

### 8.1 不做

- 不统一单项目入口
- 不改 `bin/symphony` 这条旧入口的默认语义
- 不重开完整 Workflow 模块化工程
- 不做 Web 可视化 prompt 编辑器
- 不做复杂模板语言
- 不把所有项目 prompt/rules 全搬进控制面

### 8.2 当前故意延后

- 单项目也从 YAML 读取配置
- 单项目 / 多项目统一入口
- 更完整的 workflow compiler / stale 检测 / compile 子命令

这些方向已经成立，但不纳入本轮。

## 9. 本轮验收标准

如果本轮算通过，至少满足：

1. `symphony.projects.yaml` 中能同时声明两个项目
2. 两个项目的 `project_slug` 不再写死在通用源文件里
3. 两个项目的 clone 地址不再写死在通用源文件里
4. 控制面为每个项目生成各自的 `WORKFLOW.generated.md`
5. 两个项目的 generated 文件路径不同
6. 两个项目的 `workspace_root` 不同
7. 两个项目的 `logs_root` 不同
8. 控制面能用两个项目配置启动 worker，不串线

## 10. 已冻结的项目信息

### `powersymphony`

- `id`: `powersymphony`
- `name`: `PowerSymphony`
- `project_slug`: `03b2b4a16461`
- `repo_url`: `https://github.com/youdaowudao/PowerSymphony.git`
- `worker_port`: `4101`

### `linear-agents`

- `id`: `linear-agents`
- `name`: `Linear Agents`
- `project_slug`: `327e2b00c1cd`
- `repo_url`: `https://github.com/youdaowudao/linear-agents.git`
- `worker_port`: `4102`

## 11. 给 Coder 的一句话交接

本轮不是“补一个多项目配置文件”这么简单，而是要把当前通用 `WORKFLOW.md` 中仍然写死的项目级绑定信息，最小成本外提到 `symphony.projects.yaml`，并在控制面启动前为每个项目生成各自的 `WORKFLOW.generated.md`，先让 `powersymphony` 和 `linear-agents` 两个项目真正跑成不串线的多项目 worker。

## 12. 2026-05-20 现场追查得到的问题清单

下面这份清单只记录当前已经确认的问题，不包含修复方案。

### 12.1 P0 启动链路直接损坏

1. 多项目控制面启动 worker 时，写死调用的是：
   - `./bin/symphony --logs-root ... --port ... <workflow>`
2. 这条命令定义在：
   - `elixir/lib/symphony_elixir/project_process_manager.ex`
3. 真实启动命令没有带：
   - `--i-understand-that-this-will-be-running-without-the-usual-guardrails`
4. `bin/symphony` 对应的 CLI 已经强制要求这个参数；没有就直接退出。
5. 因此当前多项目控制面的 `Start` 在真实环境下会稳定失败，不是偶发故障。

### 12.2 P0 启动入口分裂，规则不一致

1. 单项目推荐入口是 `bin/symphony_start`。
2. `bin/symphony_start` 的 usage 已明确要求 guardrails 确认参数。
3. 多项目控制面没有复用 `bin/symphony_start`，而是自己另拼了一条启动命令。
4. 结果是：
   - 单项目和多项目不是同一套启动规则；
   - 一边新增了强制确认参数，另一边没有同步更新；
   - 多项目控制面因此落入“永远起不来”的状态。

### 12.3 P0 错误日志存在，但控制面没有把排障入口告诉用户

1. 控制面运行时已经生成了日志与状态文件：
   - `.../logs/control-plane/runtime.json`
   - `.../logs/control-plane/worker.stdout.log`
   - `.../logs/control-plane/worker.stderr.log`
2. 当前实际错误已经明确写入 `worker.stderr.log`：
   - worker 因缺少 guardrails 确认参数而退出。
3. 但首页只显示：
   - `start_failed`
   - `worker command exited during startup`
4. 页面没有告诉用户：
   - 日志在哪；
   - 下一步该去哪里看；
   - 当前失败到底是配置错、命令错，还是业务运行失败。

### 12.4 P1 首页被实现成“轻量项目列表”，不是项目主页面

1. 控制面首页文案明确写的是：
   - `Static config validation with lightweight runtime summary.`
2. 这说明它从设计上就只是：
   - 项目列表；
   - 轻量运行摘要；
   - 基础控制按钮。
3. 它没有承担“多项目运行总控首页”的职责。
4. 因此用户进入页面后看不到：
   - 单项目首页那种运行时长；
   - 倒计时；
   - 现场进展；
   - 对话上下文；
   - 更深层运行态指标。

### 12.5 P1 首页虽然有跳转，但信息架构没有讲清楚

1. 首页给了两个链接：
   - `JSON summary`
   - `View details`
2. 但页面没有告诉用户：
   - 这两个入口各自是干什么的；
   - 哪个是人该看的；
   - 哪个是机器接口；
   - 真正的项目详情、运行页、排障页之间是什么关系。
3. 对正常用户来说，`JSON summary` 甚至是干扰项，不是可理解的主入口。

### 12.6 P1 项目详情页依然只是轻量页，不是完整项目页

1. `ProjectLive` 自己的定义就是：
   - `Lightweight project detail page for control-plane project summaries.`
2. 页内文案也明确写着：
   - `Lightweight run summary view`
3. 它展示的是：
   - 项目基础状态；
   - 轻量 run summary；
   - 再跳到 run 页。
4. 所以用户点进详情页后，依然拿不到“完整项目工作台”的体验。

### 12.7 P1 “运行预检”交互对当前失败场景几乎不可用

1. `运行预检` 按钮只有在 `worker_status == running` 时才可用。
2. 当前 worker 因启动链路缺陷根本起不来，所以这个按钮天然失效。
3. 页面没有解释：
   - 为什么当前不能跑；
   - 需要先满足什么前置条件；
   - 失败时应该先看日志还是先看详情页。

### 12.8 P1 多项目视角与单项目视角没有被统一设计

当前实际存在三层页面：

1. 多项目首页：
   - 只列项目和轻量状态。
2. 项目详情页：
   - 只给轻量 run summary。
3. run 页：
   - 承担更深的运行信息。

问题在于：

1. 三层页面都存在，但用户路径没有被设计清楚。
2. 页面之间缺少“你现在在哪、下一步该去哪”的明确引导。
3. 结果就是用户会自然感觉：
   - 页面不是不能点；
   - 而是根本不知道该怎么用。

### 12.9 P2 测试覆盖明显遗漏真实启动链路

1. `ProjectProcessManager` 相关测试大量使用 fake worker / fake command builder。
2. 这覆盖了状态机和页面交互，但没有可靠覆盖：
   - 控制面真实调用 `./bin/symphony` 是否还能成功启动。
3. 因此“真实启动命令缺少强制确认参数”这种问题，没有在本地测试阶段被拦住。

### 12.10 P2 当前错误文案只描述结果，不描述用户下一步动作

当前首页的失败反馈只告诉用户：

1. 项目启动失败了；
2. worker 在启动阶段退出了。

但没有告诉用户：

1. 这是启动参数层面的错误；
2. 日志文件路径在哪里；
3. 是否应该先修启动链路再谈预检或运行页；
4. 当前 failure 属于“控制面 bug”还是“项目配置 bug”。

### 12.11 本轮追查结论

1. 当前最核心的问题不是 YAML 路径，也不是用户不会点页面。
2. 当前第一阻塞点是：
   - 多项目控制面使用的真实 worker 启动命令已经过期，没有跟上单项目入口新增的 guardrails 确认要求。
3. 当前第二阻塞点是：
   - 控制面首页、项目详情页、run 页虽然都存在，但没有形成对人类用户可理解、可导航、可排障的信息架构。

## 13. 2026-05-20 运行预检追加追查

在修复 guardrails 确认参数之后，多项目 worker 已经能够启动，但 `运行预检` 仍然失败。

### 13.1 现场现象

1. 控制面项目状态已经变为 `running`。
2. 对项目接口直接发起：
   - `POST /api/v1/projects/:project_id/m3_precheck`
3. 接口返回 `503`，错误体里明确包含：
   - `m3_precheck_unavailable`
   - `:missing_linear_api_token`

### 13.2 已确认根因

1. 多项目控制面启动 worker 时，虽然已经补上了 guardrails 确认参数，但仍然是直接调用：
   - `./bin/symphony ...`
2. 单项目入口 `bin/symphony_start` 在真正启动前，还会额外做一层 Linear token 引导：
   - 如果环境里没有显式设置 `LINEAR_API_KEY`；
   - 就尝试从 `~/.config/linear/linear_api_key.token` 读取；
   - 读取后注入为 `LINEAR_API_KEY` 再启动 worker。
3. 多项目控制面的默认启动命令之前没有这段逻辑。
4. 结果就是：
   - worker 本身能起来；
   - 但一旦执行需要 Linear 鉴权的能力，例如 `m3_precheck`；
   - 就会在 worker 内部直接报 `:missing_linear_api_token`。

### 13.3 结论

1. `运行预检` 这次失败，不是页面按钮坏了。
2. 也不是代理接口没打通。
3. 是多项目启动链路只补了“能启动”，但还没有补齐单项目入口已有的 Linear token 引导。
4. 因此这是第二个独立的启动环境缺口，不是同一个 guardrails 问题的尾巴。
