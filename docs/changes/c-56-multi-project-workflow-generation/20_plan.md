# C-56 多项目 Workflow 生成实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让控制面从 `symphony.projects.yaml` 读取每项目绑定信息，并在启动 worker 前生成隔离的 `WORKFLOW.generated.md`，避免多项目串用同一个 `project_slug`、workspace 根路径和 clone 地址。

**Architecture:** 保留根 `elixir/WORKFLOW.md` 作为唯一人工维护的通用 workflow 源。新增一个最小 workflow generator，读取通用源 frontmatter，只对本轮冻结的项目级字段做受控替换，然后在 `ProjectProcessManager.start_project/2` 启动前按需生成每项目文件。`ProjectConfigStore` 扩展为支持 `defaults`、模板渲染与新增项目字段，并继续输出绝对路径归一化后的 `ProjectConfig`。

**Tech Stack:** Elixir, ExUnit, `YamlElixir`, 现有 `Workflow`/`Config` frontmatter 读取逻辑, `PathSafety`

---

## 文件边界

**Create:**
- `elixir/lib/symphony_elixir/project_workflow_generator.ex`
- `elixir/test/symphony_elixir/project_workflow_generator_test.exs`

**Modify:**
- `symphony.projects.example.yaml`
- `elixir/WORKFLOW.md`
- `elixir/lib/symphony_elixir/project_config.ex`
- `elixir/lib/symphony_elixir/project_config_store.ex`
- `elixir/lib/symphony_elixir/project_process_manager.ex`
- `elixir/test/symphony_elixir/project_config_store_test.exs`
- `elixir/test/symphony_elixir/project_registry_test.exs`
- `elixir/test/symphony_elixir/project_process_manager_test.exs`

**Likely no behavior change needed, but re-read while implementing:**
- `elixir/lib/symphony_elixir/project_registry.ex`
- `elixir/lib/symphony_elixir/workflow.ex`
- `elixir/test/support/test_support.exs`

## Task 1: 扩展静态项目配置合同

**Files:**
- Modify: `symphony.projects.example.yaml`
- Modify: `elixir/lib/symphony_elixir/project_config.ex`
- Modify: `elixir/lib/symphony_elixir/project_config_store.ex`
- Test: `elixir/test/symphony_elixir/project_config_store_test.exs`
- Test: `elixir/test/symphony_elixir/project_registry_test.exs`

- [ ] **Step 1: 写失败测试，覆盖新 schema 与模板渲染**

在 `project_config_store_test.exs` 增加三类断言：
- sample config 现在从 `defaults` + 两个项目条目解析出不同的 `project_slug`、`repo_url`、`workflow_source`、`workflow_generated`
- `workspace_root`、`logs_root`、`workflow_generated` 支持 `{{ project_id }}` 模板并在归一化前渲染
- 缺失 `project_slug`、`repo_url`、`workflow_source` 时返回稳定结构化错误

在 `project_registry_test.exs` 增加断言：新字段 round-trip 后仍能在 `normalized_config` 中保留，不被 registry 丢失。

- [ ] **Step 2: 运行配置层定向测试，确认按预期失败**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/project_config_store_test.exs test/symphony_elixir/project_registry_test.exs
```

Expected:
- `ProjectConfig` 结构不含新字段
- `ProjectConfigStore` 仍拒绝 `defaults` / 新字段
- sample config 预期与当前 fixture 不匹配

- [ ] **Step 3: 做最小实现，扩展 `ProjectConfig` 与 `ProjectConfigStore`**

实现要点：
- `ProjectConfig` 增加 `project_slug`、`repo_url`、`workflow_source`
- root schema 从仅 `projects` 扩到 `defaults + projects`
- 新增模板渲染函数，只允许对路径模板做 `{{ project_id }}` 替换
- 新增新字段校验与绝对路径归一化
- 保持运行时字段禁止写入的旧约束不变

- [ ] **Step 4: 回跑配置层测试，确认转绿**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/project_config_store_test.exs test/symphony_elixir/project_registry_test.exs
```

Expected:
- `0 failures`

## Task 2: 引入 per-project workflow generator

**Files:**
- Create: `elixir/lib/symphony_elixir/project_workflow_generator.ex`
- Test: `elixir/test/symphony_elixir/project_workflow_generator_test.exs`
- Modify: `elixir/WORKFLOW.md`

- [ ] **Step 1: 写失败测试，钉住生成结果**

新增 `project_workflow_generator_test.exs`，至少覆盖：
- 从通用 `elixir/WORKFLOW.md` 读取 frontmatter 与 prompt body
- 生成后的 frontmatter 中 `tracker.project_slug`、`workspace.root`、`hooks.after_create` 使用项目配置值
- 生成不改 prompt body
- 两个项目生成到不同输出路径时内容隔离

`after_create` 的核心断言不要只比全文，至少验证 clone 命令包含项目 `repo_url`。

- [ ] **Step 2: 运行生成器定向测试，确认先红**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/project_workflow_generator_test.exs
```

Expected:
- 缺少生成器模块或生成内容不匹配

- [ ] **Step 3: 做最小实现并收紧通用源文件**

实现要点：
- 复用 `Workflow.load/1` 的 frontmatter 分割语义，避免重新发明解析格式
- 生成器只对三类项目绑定做受控改写：`tracker.project_slug`、`workspace.root`、`hooks.after_create`
- 允许补齐 `hooks` map，但不重写无关配置
- 根 `elixir/WORKFLOW.md` 改为不再写死项目级 slug / repo 地址，同时保留 `control_plane` 相关公共配置

- [ ] **Step 4: 回跑生成器测试，确认转绿**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/project_workflow_generator_test.exs
```

Expected:
- `0 failures`

## Task 3: 接入启动前生成链路

**Files:**
- Modify: `elixir/lib/symphony_elixir/project_process_manager.ex`
- Test: `elixir/test/symphony_elixir/project_process_manager_test.exs`

- [ ] **Step 1: 写失败测试，覆盖“缺 generated 但可生成”路径**

在 `project_process_manager_test.exs` 增加至少两类场景：
- `workflow_generated` 初始不存在，但 `workflow_source` 存在时，`start_project/2` 会先生成文件再启动成功
- `workflow_source` 缺失或不可读时，`start_project/2` 返回 `:config_invalid` 或等价失败，且不会误启动 worker

把旧测试里“generated 缺失直接投成 `config_invalid`”拆成：
- 静态配置无效仍是 `config_invalid`
- 仅 generated 缺失但 source 完整时，允许通过启动前生成转为 `:running`

- [ ] **Step 2: 运行启动链定向测试，确认先红**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/project_process_manager_test.exs
```

Expected:
- `start_project/2` 仍在 `projected_status/2` 前被缺文件拦住

- [ ] **Step 3: 做最小实现，把生成接到启动前**

实现要点：
- 在 `start_project_runtime/2` 的 `config_invalid` 判定前，先区分“静态配置无效”和“generated 缺失但可补生成”
- 仅在 entry 有完整 `normalized_config` 时调用 generator
- 生成失败时保留不可启动语义，但不要把“未生成”和“静态 schema 无效”混成同一分支实现
- 启动命令仍继续消费 `workflow_generated`

- [ ] **Step 4: 回跑启动链测试，确认转绿**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/project_process_manager_test.exs
```

Expected:
- 新增场景通过
- 旧有 start/stop/restart 相关行为无回归

## Task 4: 样例配置与收口验证

**Files:**
- Modify: `symphony.projects.example.yaml`
- Optional Test Re-run: 上述三个测试文件

- [ ] **Step 1: 更新 sample config 为双项目 + defaults 结构**

样例需要直接体现：
- `defaults.workflow_source`
- `defaults.workflow_generated_template`
- `defaults.workspace_root_template`
- `defaults.logs_root_template`
- 两个项目的 `project_slug`、`repo_url`、`worker_port`

- [ ] **Step 2: 运行本轮最小 closeout 验证**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix format --check-formatted
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/project_config_store_test.exs test/symphony_elixir/project_registry_test.exs test/symphony_elixir/project_workflow_generator_test.exs test/symphony_elixir/project_process_manager_test.exs
```

Expected:
- `mix format --check-formatted` 通过
- 目标测试文件 `0 failures`

- [ ] **Step 3: 记录剩余风险**

本轮收口时必须显式检查并记录：
- `bin/symphony_start` 旁路兼容是否仍依赖根 `elixir/WORKFLOW.md`
- generator 是否只改动冻结件允许的三个项目绑定面
- 没有残留测试 worker、端口、临时目录或环境变量污染
