# Workflow Contract Migration Audit Design

## Goal

把这次“旧仓库里已经换过的 `elixir/WORKFLOW.md` 及其配套代码，是否还需要继续迁到当前仓库”这件事，从待实施迁移，收敛成一次可复核的审计结论。

如果还存在真实缺口，就只迁最小必需改动；如果不存在真实缺口，就明确结案，并定义后续再发生 workflow 合同变更时应该如何检查和落地。

## Background Interpretation

1. 这次迁移的起点不是“从零设计新编排”，而是旧仓库已经把一份新的 `elixir/WORKFLOW.md` 带入仓库，随后又为它补过少量配套代码、测试和文档。
2. 旧仓库历史里，与这次合同迁移直接相关的主证据链是：
   - `8d5c63f` (`docs(workflow): update elixir workflow file`)：只更新 `elixir/WORKFLOW.md`。
   - `7346e79` (`fix(workflow): 对齐新工作流契约并修复本地资源编译`)：补齐 `core_test.exs`、`README.md`、`static_assets.ex` 和迁移说明文档。
3. 更早的运行时语义修正也构成当前 workflow 合同能成立的背景约束，但不属于这次“补迁移”的直接缺口：
   - `5b3e02a`：修正 `turn/completed` / `premature_turn_end` 续跑边界。
   - `58cf97d`：让 `codex.command` 等配置经由 `WORKFLOW.md` 生效。
4. 用户这次要求的“迁移工作”，本质上是：以旧仓库作为对照源，确认围绕这份新 `WORKFLOW.md` 的少量配套代码是否还有未迁入当前仓库的部分。

## Confirmed Current State

### 1. 旧仓库与当前仓库当前在同一提交点

- `/home/ss/projects/powersymphony` 与 `/home/ss/data/projects/powersymphony` 当前 `HEAD` 都是 `dff41d766acbd6904527c697620b2b17ddb603e0`。
- 两边 `elixir/` 目录直接比较没有文件级差异。
- 旧仓库当前工作树也没有额外未提交改动可作为“隐藏迁移源”。

这意味着：当前不存在“旧仓库工作树里还躺着一批这次必须补迁入当前仓库的 workflow 配套改动”。

### 2. 新 workflow 合同本体已经在当前仓库落地

- 当前正式合同文件是 [elixir/WORKFLOW.md](/home/ss/data/projects/powersymphony/elixir/WORKFLOW.md)。
- 它已经包含这次迁移最核心的结构和强语义，例如：
  - `## Stable issue-body model`
  - `## Preflight body gate`
  - `## Execution Brief`
  - `## Codex Workpad`
  - `pull` / `land` skill 约束
  - “active issue 下不得把一次 turn 提前收口成任务完成”这类行为规则

### 3. 当前运行时代码已经以 `WORKFLOW.md` 作为合同输入

这几个文件共同构成当前 workflow 合同的代码承接面：

- [elixir/lib/symphony_elixir/workflow.ex](/home/ss/data/projects/powersymphony/elixir/lib/symphony_elixir/workflow.ex)
  - 负责默认路径、front matter 拆分、YAML 校验、prompt 载入。
- [elixir/lib/symphony_elixir/config.ex](/home/ss/data/projects/powersymphony/elixir/lib/symphony_elixir/config.ex)
  - 负责把 `WORKFLOW.md` front matter 解释成运行时设置和默认 prompt 语义。
- [elixir/lib/symphony_elixir/prompt_builder.ex](/home/ss/data/projects/powersymphony/elixir/lib/symphony_elixir/prompt_builder.ex)
  - 负责把当前 workflow 模板按 `issue` / `attempt` 渲染成实际 prompt。

### 4. 当前测试与 README 已经对齐到新合同

- [elixir/test/symphony_elixir/core_test.exs](/home/ss/data/projects/powersymphony/elixir/test/symphony_elixir/core_test.exs)
  - 已断言当前 `WORKFLOW.md` 是有效完整的。
  - 已断言 in-repo workflow 渲染包含新合同里的关键章节与语义。
- [elixir/README.md](/home/ss/data/projects/powersymphony/elixir/README.md)
  - 已改为 `PowerSymphony` 仓库地址与当前启动路径。
- [elixir/lib/symphony_elixir_web/static_assets.ex](/home/ss/data/projects/powersymphony/elixir/lib/symphony_elixir_web/static_assets.ex)
  - 已具备本地源码 checkout 优先、`Application.app_dir/2` 回退的资源加载策略，不再是迁移 blocker。

### 5. 本次审计的主线程验证结果

2026-05-11 主线程重新运行了最小验证集：

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test \
  test/symphony_elixir/core_test.exs:130 \
  test/symphony_elixir/core_test.exs:1342 \
  test/symphony_elixir/cli_test.exs
```

结果：`14 tests, 0 failures`

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test \
  test/symphony_elixir/extensions_test.exs:1056 \
  test/symphony_elixir/extensions_test.exs:1384
```

结果：`2 tests, 0 failures`

说明：

- 第一条命令同时覆盖了 `core_test` 指定用例和整个 `cli_test.exs` 文件，因此 `14 tests, 0 failures` 不是只包含 `core_test`。

## Judgement

### 1. 当前任务不应再按“待实施迁移”推进

旧的 `workflow migration` 设计与计划文档，写作时的前提是：

- 新的 `WORKFLOW.md` 已复制进仓库；
- 但测试、README、静态资源加载等配套代码还没补齐。

这个前提现在已经失效。当前仓库里的实际状态是：

- 新合同已在代码、测试、README 层落地；
- 旧仓库对照源与当前仓库没有额外待迁差异；
- 继续沿用“先复现再修复”的迁移计划，只会制造伪待办。

### 2. 本次最合理的落点是“审计 + 验收 + 归档”

因此，本次正式方案应改写成：

- 用审计文档说明迁移是否已完成；
- 明确 workflow 合同面和最小验证矩阵；
- 记录这次判断的证据链；
- 为未来再发生 workflow 合同变更时，提供一张可以复用的 TASK 执行卡。

### 3. 不应借本次任务顺带扩 scope

本次任务不授权继续推进下列工作：

- 多项目 control-plane 新功能
- workflow 模块化生成器
- 新一轮 prompt policy 设计
- 吸收旧仓库中任何与当前 `WORKFLOW.md` 合同无关的代码

## Contract Surface

后续任何“workflow 合同迁移”都只允许先核查这几个面：

### 1. 合同源文件

- [elixir/WORKFLOW.md](/home/ss/data/projects/powersymphony/elixir/WORKFLOW.md)

### 2. 运行时承接面

- [elixir/lib/symphony_elixir/workflow.ex](/home/ss/data/projects/powersymphony/elixir/lib/symphony_elixir/workflow.ex)
- [elixir/lib/symphony_elixir/config.ex](/home/ss/data/projects/powersymphony/elixir/lib/symphony_elixir/config.ex)
- [elixir/lib/symphony_elixir/prompt_builder.ex](/home/ss/data/projects/powersymphony/elixir/lib/symphony_elixir/prompt_builder.ex)

### 3. 回归验证面

- [elixir/test/symphony_elixir/core_test.exs](/home/ss/data/projects/powersymphony/elixir/test/symphony_elixir/core_test.exs)
- [elixir/test/symphony_elixir/cli_test.exs](/home/ss/data/projects/powersymphony/elixir/test/symphony_elixir/cli_test.exs)
- [elixir/test/symphony_elixir/extensions_test.exs](/home/ss/data/projects/powersymphony/elixir/test/symphony_elixir/extensions_test.exs)

### 4. 操作文档面

- [elixir/README.md](/home/ss/data/projects/powersymphony/elixir/README.md)

### 5. 辅助支持面

- [elixir/lib/symphony_elixir_web/static_assets.ex](/home/ss/data/projects/powersymphony/elixir/lib/symphony_elixir_web/static_assets.ex)

说明：

- `static_assets.ex` 不是 workflow 合同语义本体，只是在本地测试编译上曾经挡住过合同验证，所以保留在辅助面。
- `agent_runner.ex`、`orchestrator.ex`、`app_server.ex` 与 workflow 语义强相关，但它们在本次“旧仓库对照迁移”里没有发现新的待补差异，因此不列为第一轮核查面，只有发现明确行为缺口时再升级核查。

### 6. 运行时语义升级触发面

只有出现下面任一信号时，才把核查范围从第一轮合同面升级到：

- [elixir/lib/symphony_elixir/agent_runner.ex](/home/ss/data/projects/powersymphony/elixir/lib/symphony_elixir/agent_runner.ex)
- [elixir/lib/symphony_elixir/orchestrator.ex](/home/ss/data/projects/powersymphony/elixir/lib/symphony_elixir/orchestrator.ex)
- [elixir/lib/symphony_elixir/codex/app_server.ex](/home/ss/data/projects/powersymphony/elixir/lib/symphony_elixir/codex/app_server.ex)

升级触发条件：

- `WORKFLOW.md` 的变更直接改动了 turn/run/ticket 完成边界
- `WORKFLOW.md` 的变更直接改动了 retry / continuation / merge / human-review 语义
- 新合同引入了现有 `workflow/config/prompt_builder` 无法承接的 runtime 配置键
- `core_test`、`cli_test`、`extensions_test` 已经通过，但实际行为仍暴露出 workflow 合同与运行时语义脱节

## Verification Matrix

### 默认最小验证集

适用于：

- `WORKFLOW.md` 文本更新
- `workflow.ex` / `config.ex` / `prompt_builder.ex` 小范围合同适配
- `README` 同步

执行：

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test \
  test/symphony_elixir/core_test.exs:130 \
  test/symphony_elixir/core_test.exs:1342 \
  test/symphony_elixir/cli_test.exs
```

### 补充验证集

仅当合同验证被本地编译路径或 Phoenix 资源装载影响时，再加：

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test \
  test/symphony_elixir/extensions_test.exs:1056 \
  test/symphony_elixir/extensions_test.exs:1384
```

### 边界启动检查

仅当 README、CLI 入口或 workflow 默认路径语义被改动时，再加：

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix run --no-start -e \
'IO.inspect(SymphonyElixir.CLI.evaluate(["--i-understand-that-this-will-be-running-without-the-usual-guardrails", "WORKFLOW.md"]))'
```

## Exit Criteria

本次 workflow 合同迁移审计可以收口，当且仅当下面条件同时成立：

1. 旧仓库对照源与当前仓库不存在额外待迁的 workflow 配套工作树差异。
2. 当前 `WORKFLOW.md` 已被确认是唯一正式合同源。
3. 合同承接面、验证面、操作文档面已经被明确记录。
4. 旧的“待实施迁移”文档已改写成与现状一致的审计/验收文档。
5. 最小验证集保持绿色。

## Resulting Recommendation

本轮不应继续虚构新的“workflow 迁移代码任务”。

更稳妥的后续路径是：

1. 把这次工作作为“迁移已完成的审计确认”归档。
2. 后续若再从别的工作树或分支迁入新的 workflow 合同，严格按 TASK 卡重新做对照、归类、最小迁移与验证。
