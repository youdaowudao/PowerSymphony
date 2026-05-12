# Workflow Contract Migration Audit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把原先基于“新 `WORKFLOW.md` 已复制进来、但配套代码还没补齐”的旧迁移计划，改写成一份与当前仓库状态一致的 workflow 合同迁移审计与验收方案。

**Architecture:** 先用旧仓库历史和当前仓库现状确认是否存在真实待迁差异；若没有，就停止虚构代码迁移任务，只保留合同面、验证矩阵、审计结论和可复用的 TASK 卡。整个过程只动文档，不重新打开 control-plane 或其他阶段性范围。

**Tech Stack:** Markdown, Git, ExUnit, mise

---

### Task 1: 固定审计证据，证明当前不是“待实施迁移”

**Files:**
- Modify: `docs/superpowers/specs/2026-05-11-workflow-migration-design.md`
- Modify: `docs/superpowers/plans/2026-05-11-workflow-migration.md`

- [ ] **Step 1: 记录旧仓库与当前仓库是否仍有 workflow 相关差异**

Run:

```bash
git status --short
git rev-parse HEAD
git --git-dir=/home/ss/projects/powersymphony/.git --work-tree=/home/ss/projects/powersymphony status --short
git --git-dir=/home/ss/projects/powersymphony/.git --work-tree=/home/ss/projects/powersymphony rev-parse HEAD
diff -ru --exclude .git --exclude _build --exclude deps \
  /home/ss/projects/powersymphony/elixir \
  /home/ss/data/projects/powersymphony/elixir
```

Expected:

- 两边 `HEAD` 一致
- 旧仓库 `git status` 不暴露额外 workflow 隐藏改动
- `elixir/` 目录无 workflow 相关文件级差异

- [ ] **Step 2: 把审计前提写入设计文档，而不是继续沿用旧迁移假设**

在设计文档中明确写入以下结论：

```md
- 当前任务不是继续补迁 workflow 配套代码，而是确认迁移是否已完成。
- 旧仓库与当前仓库当前在同一提交点，不存在额外待迁的 workflow 工作树差异。
- 原旧计划中的“core_test 仍断言旧文案”“README 仍指向 openai/symphony”“StaticAssets 仍是 blocker”等前提已经失效。
```

- [ ] **Step 3: 用历史提交解释这次迁移真正发生在哪里**

Run:

```bash
git --git-dir=/home/ss/projects/powersymphony/.git --work-tree=/home/ss/projects/powersymphony \
  log --oneline --grep=workflow -n 20
```

Expected: 至少能看到：

```text
8d5c63f docs(workflow): update elixir workflow file
7346e79 fix(workflow): 对齐新工作流契约并修复本地资源编译
```

- [ ] **Step 4: 在设计文档里把证据链收敛成“背景解读 + 判断”**

写入类似下面的结构：

```md
## Background Interpretation
## Confirmed Current State
## Judgement
```

要求：

- 背景解读解释为什么旧文档会写成“待迁移”。
- 当前状态只写已验证事实。
- 判断明确给出“迁移已落地 / 当前应转为审计验收”的结论。

### Task 2: 定义正式 workflow 合同面与最小验证矩阵

**Files:**
- Modify: `docs/superpowers/specs/2026-05-11-workflow-migration-design.md`

- [ ] **Step 1: 把 workflow 合同面列成固定清单**

在设计文档中列出并解释这几个面：

```md
- elixir/WORKFLOW.md
- elixir/lib/symphony_elixir/workflow.ex
- elixir/lib/symphony_elixir/config.ex
- elixir/lib/symphony_elixir/prompt_builder.ex
- elixir/test/symphony_elixir/core_test.exs
- elixir/test/symphony_elixir/cli_test.exs
- elixir/test/symphony_elixir/extensions_test.exs
- elixir/README.md
```

- [ ] **Step 2: 定义默认最小验证集**

把下面命令写进设计文档：

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test \
  test/symphony_elixir/core_test.exs:130 \
  test/symphony_elixir/core_test.exs:1342 \
  test/symphony_elixir/cli_test.exs
```

并注明：适用于 `WORKFLOW.md`、loader、config、prompt builder、README 的小范围合同适配。

- [ ] **Step 3: 定义按需补充验证**

把下面命令写进设计文档：

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test \
  test/symphony_elixir/extensions_test.exs:1056 \
  test/symphony_elixir/extensions_test.exs:1384
```

并注明：仅当本地编译路径、Phoenix 资源装载或静态资源依赖影响合同验证时才需要补跑。

- [ ] **Step 4: 增加运行时语义升级触发条件**

在设计文档中明确：

```md
只有当 WORKFLOW 变更直接触发 turn/run/ticket 边界、retry/continuation、
merge/human-review 语义变化，或现有 workflow/config/prompt_builder 无法承接
新配置键时，才升级核查 agent_runner / orchestrator / app_server。
```

- [ ] **Step 5: 明确 out-of-scope**

在设计文档中明确排除：

```md
- control-plane 新功能
- workflow 模块化生成
- 与当前 WORKFLOW 合同无关的旧仓库改动
```

### Task 3: 写出可复用的 TASK 执行卡

**Files:**
- Create: `docs/superpowers/tasks/2026-05-11-workflow-migration-audit-task.md`

- [ ] **Step 1: 给 TASK 卡写清使用场景**

TASK 卡开头必须明确：

```md
当外部工作树、旧仓库或其他分支里出现一份更新过的 elixir/WORKFLOW.md 时，
用这张卡判断当前仓库是否真的还需要补迁配套代码、测试或文档。
```

- [ ] **Step 2: 给 TASK 卡列出 source of truth**

把合同源、承接面、验证面写进去，至少包括：

```md
- elixir/WORKFLOW.md
- workflow.ex / config.ex / prompt_builder.ex
- core_test.exs / cli_test.exs / extensions_test.exs
- README.md
- static_assets.ex
```

- [ ] **Step 3: 给 TASK 卡列出最小执行清单**

至少包含：

```md
- 记录两边 HEAD 与 git status
- 比较 elixir/WORKFLOW.md
- 核查合同承接面
- 归类差异
- 只迁最小必需改动
- 运行最小验证集
- 无真实差异时停止写代码，改为输出审计结论
```

- [ ] **Step 4: 给 TASK 卡写 Stop Conditions**

至少包含：

```md
- 两边已经在同一 HEAD 且没有额外 workflow 相关差异
- 只剩审计/汇报文档口径差异，而没有合同源、代码、测试、README 的差异
- 拟迁移内容开始扩散到 control-plane / compiler / trace 等范围外主题
```

### Task 4: 验证文档与结论一致，并提交

**Files:**
- Modify: `docs/superpowers/specs/2026-05-11-workflow-migration-design.md`
- Modify: `docs/superpowers/plans/2026-05-11-workflow-migration.md`
- Create: `docs/superpowers/tasks/2026-05-11-workflow-migration-audit-task.md`

- [ ] **Step 1: 运行本次审计依赖的最小验证集**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test \
  test/symphony_elixir/core_test.exs:130 \
  test/symphony_elixir/core_test.exs:1342 \
  test/symphony_elixir/cli_test.exs
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test \
  test/symphony_elixir/extensions_test.exs:1056 \
  test/symphony_elixir/extensions_test.exs:1384
```

Expected:

```text
14 tests, 0 failures
2 tests, 0 failures
```

- [ ] **Step 2: 检查本次 diff 只包含审计型文档更新**

Run:

```bash
git diff -- \
  docs/superpowers/specs/2026-05-11-workflow-migration-design.md \
  docs/superpowers/plans/2026-05-11-workflow-migration.md \
  docs/superpowers/tasks/2026-05-11-workflow-migration-audit-task.md
```

Expected: diff 只体现审计结论、验证矩阵和 TASK 卡，不引入无关代码改动。

- [ ] **Step 3: 用 repo 规则提交这批文档**

Commit message example:

```bash
git add \
  docs/superpowers/specs/2026-05-11-workflow-migration-design.md \
  docs/superpowers/plans/2026-05-11-workflow-migration.md \
  docs/superpowers/tasks/2026-05-11-workflow-migration-audit-task.md
git commit -F /tmp/workflow-migration-audit-commit.txt
```

其中提交主题应包含中文简介，且准确表达“把旧 workflow 迁移计划改写为审计/验收方案”。
