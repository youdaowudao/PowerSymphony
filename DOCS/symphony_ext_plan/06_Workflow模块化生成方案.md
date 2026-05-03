# 06. Workflow 模块化与生成方案

## 1. 核心原则

不取消 `WORKFLOW.md`。

改成：

```text
人维护模块化源文件
  -> workflow compiler
  -> WORKFLOW.generated.md
  -> 单项目 Symphony worker 读取 generated 文件
```

这样保留官方 workflow contract，同时降低人工维护压力。

---

## 2. 为什么不能直接取消 WORKFLOW.md

官方 spec 明确把 `WORKFLOW.md` 作为 repo-owned contract，用来承载 prompt、runtime settings、hooks、tracker config。这个设计有价值：项目策略跟代码仓库一起版本化。

如果改成控制面集中保存所有 prompt/rules/hooks，会导致：

- 项目规则脱离项目仓库；
- 多项目配置变成超级大文件；
- review 难度上升；
- AI 修改项目策略时找不到明确边界；
- 回滚困难。

所以：控制面只知道 generated workflow 的路径，不接管项目具体 prompt。

---

## 3. 源文件结构

每个项目仓库内建议：

```text
workflow/
  manifest.yaml
  frontmatter.yaml
  prompt/
    00_identity.md
    10_context.md
    20_execution_rules.md
    30_validation.md
    40_handoff.md
  skills/
    linear.md
    commit.md
    push.md
    land.md
  project/
    architecture.md
    commands.md
    conventions.md
WORKFLOW.generated.md
```

---

## 4. manifest.yaml 示例

```yaml
version: 1
output: ../WORKFLOW.generated.md
frontmatter: frontmatter.yaml
body:
  - prompt/00_identity.md
  - prompt/10_context.md
  - prompt/20_execution_rules.md
  - prompt/30_validation.md
  - prompt/40_handoff.md
include_optional:
  - skills/linear.md
  - skills/commit.md
  - skills/push.md
  - skills/land.md
  - project/architecture.md
  - project/commands.md
  - project/conventions.md
metadata:
  project_id: chatgpt-extension
  owner: local
```

---

## 5. frontmatter.yaml 示例

```yaml
tracker:
  kind: linear
  project_slug: chatgpt-extension-xxxx
  active_states:
    - Todo
    - In Progress
    - Rework
  terminal_states:
    - Done
    - Closed
    - Cancelled
    - Canceled
    - Duplicate

polling:
  interval_ms: 30000

workspace:
  root: /home/user/code/symphony-workspaces/chatgpt-extension

hooks:
  after_create: |
    git clone git@github.com:you/chatgpt-extension.git .
  before_run: |
    git status --short
  timeout_ms: 60000

agent:
  max_concurrent_agents: 2
  max_turns: 20
  max_retry_backoff_ms: 300000

codex:
  command: codex app-server
  thread_sandbox: workspace-write
  turn_timeout_ms: 3600000
  stall_timeout_ms: 300000

server:
  port: 4101
```

注意：worker 的实际端口可由控制面注入或覆盖。不要让多个项目写死同一个端口。

---

## 6. generated 文件格式

`WORKFLOW.generated.md` 必须仍然是官方支持的格式：

```markdown
---
# generated_by: symphony workflow compiler
# generated_at: 2026-05-03T12:00:00Z
# source_manifest_sha256: ...
# source_files_sha256: ...
tracker:
  kind: linear
  project_slug: chatgpt-extension-xxxx
...
---

# Identity
...

# Context
...
```

---

## 7. 编译器职责

WorkflowCompiler 负责：

1. 读取 manifest。
2. 校验 frontmatter 是 map。
3. 校验 required fields。
4. 按顺序拼接 body 文件。
5. 生成 source hash。
6. 写入 generated 文件。
7. 返回编译报告。

不负责：

- 不解释 prompt 内容。
- 不替 Codex 决定任务策略。
- 不连接 Linear。
- 不启动 worker。

---

## 8. 编译命令

可以有两种入口：

### 8.1 mix 命令

```bash
mix workflow.compile --manifest /path/to/workflow/manifest.yaml
```

### 8.2 控制面命令

```bash
./bin/symphony_control workflow compile --project chatgpt-extension
```

第一版优先做控制面内部 compile；mix task 可后补。

---

## 9. stale 检测

控制面必须能判断：

```text
workflow source changed, generated file stale
```

依据：

- manifest hash；
- frontmatter hash；
- body file hash；
- generated 文件头部 hash。

Web 显示：

```text
workflow_status: current | stale | missing | invalid
```

worker 启动前规则：

- `missing`：不启动；
- `invalid`：不启动；
- `stale`：按配置决定自动编译或阻止启动；
- `current`：允许启动。

个人环境建议默认自动编译，但 Web 明确显示。

---

## 10. 与 Control Plane 的关系

`symphony.projects.yaml` 只保存 workflow 源和 generated 路径：

```yaml
projects:
  - id: chatgpt-extension
    workflow_source: /home/user/code/chatgpt-extension/workflow/manifest.yaml
    workflow_generated: /home/user/code/chatgpt-extension/WORKFLOW.generated.md
```

控制面不保存 prompt 内容。它只调用 compiler。

---

## 11. 质量门禁

- generated 文件能被现有 `Workflow.load()` 读取。
- generated 文件能启动现有单项目 worker。
- generated 文件包含 source hash。
- 源文件缺失时错误清晰。
- YAML 错误时错误清晰。
- 拼接顺序稳定。
- 编译器输出可复现。
- 控制面不把所有项目 prompt 加载到总览页。

---

## 12. 推荐执行顺序

Workflow 模块化不是第一阶段。它排在多项目和观测之后。

原因：

- 多项目控制面先决定项目边界。
- Web 观测先决定运行可见性。
- Workflow 编译是维护体验优化，不应阻塞核心运行链。

---

## 13. 不做的事情

第一版不做：

- 运行时动态 include。
- 复杂模板语言。
- Web 可视化 prompt 编辑器。
- 跨项目共享 prompt registry。
- 自动重写项目规则。
- 将所有项目合并成一个总 workflow。
