# Workflow Contract Migration Audit TASK

## Objective

当外部工作树、旧仓库或其他分支里出现一份更新过的 `elixir/WORKFLOW.md` 时，用这张 TASK 卡判断：当前仓库是否真的还需要补迁配套代码、测试或文档。

## Scope

只处理围绕 `elixir/WORKFLOW.md` 合同本体的最小配套迁移：

- workflow loader
- config / prompt builder
- workflow 回归测试
- CLI / README 启动文档
- 会直接挡住验证的辅助项

不处理：

- control-plane 新功能
- workflow 模块化生成
- 与当前 workflow 合同无关的旧仓库改动

## Source Of Truth

优先按下面顺序核查：

1. [elixir/WORKFLOW.md](/home/ss/data/projects/powersymphony/elixir/WORKFLOW.md)
2. [elixir/lib/symphony_elixir/workflow.ex](/home/ss/data/projects/powersymphony/elixir/lib/symphony_elixir/workflow.ex)
3. [elixir/lib/symphony_elixir/config.ex](/home/ss/data/projects/powersymphony/elixir/lib/symphony_elixir/config.ex)
4. [elixir/lib/symphony_elixir/prompt_builder.ex](/home/ss/data/projects/powersymphony/elixir/lib/symphony_elixir/prompt_builder.ex)
5. [elixir/test/symphony_elixir/core_test.exs](/home/ss/data/projects/powersymphony/elixir/test/symphony_elixir/core_test.exs)
6. [elixir/test/symphony_elixir/cli_test.exs](/home/ss/data/projects/powersymphony/elixir/test/symphony_elixir/cli_test.exs)
7. [elixir/test/symphony_elixir/extensions_test.exs](/home/ss/data/projects/powersymphony/elixir/test/symphony_elixir/extensions_test.exs)
8. [elixir/README.md](/home/ss/data/projects/powersymphony/elixir/README.md)
9. [elixir/lib/symphony_elixir_web/static_assets.ex](/home/ss/data/projects/powersymphony/elixir/lib/symphony_elixir_web/static_assets.ex)

## Historical Commits To Check

如果对照源也是本仓库历史，先看这些提交：

- `8d5c63f`：只更新 `elixir/WORKFLOW.md`
- `7346e79`：补齐测试、README、静态资源装载与迁移文档
- `5b3e02a`：修正 turn/run 边界语义
- `58cf97d`：让 `WORKFLOW.md` front matter 驱动 codex runtime 配置
- `bde23aa`：恢复仓库根单项目兼容入口

## Execution Checklist

- [ ] 记录当前仓库与对照源的 `HEAD`、分支、`git status`
- [ ] 比较两边 `elixir/WORKFLOW.md`
- [ ] 核查合同承接面是否存在真实差异
- [ ] 把差异归类为：合同源 / 运行时 / 测试 / README / 辅助支持
- [ ] 只迁最小必需改动，禁止顺带吸收无关差异
- [ ] 运行最小验证集
- [ ] 若没有真实差异，停止写代码，改为输出审计结论

## Minimum Commands

### 1. 基线记录

```bash
git branch --show-current
git status --short
git --git-dir=/path/to/old/.git --work-tree=/path/to/old branch --show-current
git --git-dir=/path/to/old/.git --work-tree=/path/to/old status --short
```

### 2. 合同与历史核查

```bash
diff -u /path/to/old/elixir/WORKFLOW.md /path/to/current/elixir/WORKFLOW.md
diff -u /path/to/old/elixir/lib/symphony_elixir/workflow.ex /path/to/current/elixir/lib/symphony_elixir/workflow.ex
diff -u /path/to/old/elixir/lib/symphony_elixir/config.ex /path/to/current/elixir/lib/symphony_elixir/config.ex
diff -u /path/to/old/elixir/lib/symphony_elixir/prompt_builder.ex /path/to/current/elixir/lib/symphony_elixir/prompt_builder.ex
diff -u /path/to/old/elixir/test/symphony_elixir/core_test.exs /path/to/current/elixir/test/symphony_elixir/core_test.exs
diff -u /path/to/old/elixir/test/symphony_elixir/cli_test.exs /path/to/current/elixir/test/symphony_elixir/cli_test.exs
diff -u /path/to/old/elixir/test/symphony_elixir/extensions_test.exs /path/to/current/elixir/test/symphony_elixir/extensions_test.exs
diff -u /path/to/old/elixir/README.md /path/to/current/elixir/README.md
diff -u /path/to/old/elixir/lib/symphony_elixir_web/static_assets.ex /path/to/current/elixir/lib/symphony_elixir_web/static_assets.ex
git --git-dir=/path/to/old/.git --work-tree=/path/to/old log --oneline --grep=workflow -n 20
```

### 3. 最小验证集

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test \
  test/symphony_elixir/core_test.exs:130 \
  test/symphony_elixir/core_test.exs:1342 \
  test/symphony_elixir/cli_test.exs
```

### 4. 按需补充

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test \
  test/symphony_elixir/extensions_test.exs:1056 \
  test/symphony_elixir/extensions_test.exs:1384
```

## Upgrade Trigger

只有出现下面任一条件时，才把审计范围升级到 `agent_runner`、`orchestrator`、`app_server`：

- `WORKFLOW.md` 的文本变更直接改动了 turn/run/ticket 边界
- `WORKFLOW.md` 的文本变更直接改动了 retry / continuation / merge / human-review 语义
- 新合同引入了现有 `workflow/config/prompt_builder` 无法承接的 runtime 配置键
- 第一轮合同面 diff 为空，但行为验证仍显示 workflow 合同与运行时语义脱节

## Stop Conditions

遇到以下任一情况应停止继续“迁移实现”：

1. 当前仓库与对照源已经在同一 `HEAD`，且没有额外 workflow 相关工作树差异。
2. 所谓“差异”只剩审计/汇报文档口径差异，而没有合同源、代码、测试、README 的实际差异。
3. 拟迁移内容已经扩散到 control-plane、trace、模块化生成等本任务之外。
4. 无法证明某处代码改动与 `WORKFLOW.md` 合同存在直接因果关系。

## Deliverable

每次执行完这张 TASK 卡，必须产出：

1. 一段审计结论：还有没有真实待迁差异。
2. 一组精确文件：真的需要改哪些文件。
3. 一组验证证据：跑了哪些命令，结果如何。
4. 一段风险说明：哪些内容被明确排除在本次迁移之外。
