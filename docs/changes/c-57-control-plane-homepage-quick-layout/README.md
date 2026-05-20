# C-57 控制面首页快速布局收口

## 目标 / 需求快照

这次不是重做多项目 UI，只做一个快速可用性收口：

1. 首页直接暴露每个项目当前活跃 run 的最小信息和直达入口。
2. 首页把项目基础状态、当前运行摘要和常用入口合在一起，优先作为人类主入口。
3. `/projects/:project_id` 不再维持另一套独立页面，而是复用同一个总控台的聚焦项目模式。
4. `运行预检` 在点击后默认展开，但用户可以随时手动再合上。

## 成功标准

1. 首页每个项目能直接看到：
   - 当前是否有活跃 run
   - 活跃 run 的最小摘要
   - `打开运行` 直达链接
   - `项目现场` 聚焦入口
   - 当前运行信息在独立列里，不再和项目基础信息挤在同一块
   - 更人话的状态词、操作反馈和启动失败提示
2. 当项目有多个活跃 run 时，首页只展示前几个，并明确告诉用户这里只展示前 3 条。
3. `运行预检` 点击后默认展开。
4. `运行预检` 展开后不会被首页 tick 自动收回。
5. 用户手动点击预检标题时，可以再次合上。
6. 打开 `/projects/:project_id` 时，仍然停留在 Dashboard，只是聚焦到该项目。
7. 首页增加项目数、运行中、启动失败、活跃运行四张概览卡片，先满足现场判断。
8. 聚焦项目模式的摘要区直接显示活跃运行数、JSON 摘要和 Worker 页面入口。

## 明确不做什么

1. 不把 run 深度页整体搬回首页。
2. 不删除 run 深度页。
3. 不改 API 结构，不新增首页专用接口。
4. 不顺手重排整张首页表格。

## 固定约束

1. 只围绕多项目控制面和它直接依赖的展示链路收口。
2. `run` 深度页继续存在，只负责深度时间线、上下文和事件查看。
3. `/projects/:project_id` 不再维护第二套项目页，而是复用同一个 Dashboard 的聚焦模式。
4. 允许补充现有项目摘要 payload 的展示字段，但不新增单独的首页 API。
5. 首页保留 `项目现场` 入口，但它只是 Dashboard 的聚焦视图，不再代表另一套页面系统。

## 风险判定结论

已命中 `观察层合同风险`。

命中原因：

1. 首页新增了聚合摘要与计数卡片，而不是原样透传。
2. 同一批项目摘要字段同时被首页总览、聚焦项目模式和 JSON summary 使用。
3. `worker_status`、`run_summaries`、`runtime_state.stderr_path` 被多个消费面读取并重新解释。

## Source-of-Truth Chain

### 项目运行状态

- 关键字段 / 语义：项目当前是否运行、是否失联、是否启动失败
- 实际 source：`ProjectProcessManager.project_registry/1` 生成的 `runtime_state.status`
- 中间 projection：`Presenter.projects_payload/1` 的 `worker_status`
- 最终 consumer：Dashboard 总览表格、聚焦项目摘要、项目数/运行中/启动失败统计卡片

### 当前运行摘要

- 关键字段 / 语义：当前活跃 run 的标题、phase、health、当前动作、运行时长
- 实际 source：`ProjectProcessManager` 注入到项目 runtime 的 `run_summaries`
- 中间 projection：`Presenter.project_run_summary_*` 与 Dashboard 的 `project_run_preview_*`
- 最终 consumer：Dashboard 的“当前运行”列、聚焦项目模式中的同一列

### 启动失败排障提示

- 关键字段 / 语义：启动失败时要去哪里看日志、下一步该做什么
- 实际 source：`runtime_state.stderr_path` / `runtime_state.error_summary`
- 中间 projection：`Presenter.project_runtime_failure_help/1`
- 最终 consumer：Dashboard 的“最近错误”列、聚焦项目摘要

## Contract Matrix

| field / view | source of truth | allowed transform | must not infer |
| --- | --- | --- | --- |
| 首页“运行中 / 启动失败”卡片 | `worker_status` | 允许按状态计数、中文标签化 | 不得根据 `run_summaries` 数量反推 worker 是否运行 |
| 首页“当前运行”列 | `run_summaries` | 允许截断为前 3 条、中文化 phase/health、补直达链接 | 不得补造不存在的 run，不得把隐藏 thread/turn id 当作首页必显信息 |
| 聚焦项目模式摘要 | 与首页同一份 `projects_payload` | 允许按 `project_id` 过滤并补“返回总览”入口 | 不得维护独立于首页之外的第二套项目状态 |
| 启动失败提示 | `stderr_path` / `error_summary` | 允许补中文操作提示 | 不得推断具体根因、不得伪造修复建议 |

## 这次选择

### 为什么把活跃 run 直接放回首页

因为当前多项目场景下，用户最先需要知道的不是配置是否 valid，而是：

1. 这个项目现在有没有在跑。
2. 如果在跑，应该点哪里看现场。

这些信息继续藏在副页面后面，使用成本太高。

本轮进一步把它们放进独立的 `Current run` 列，是为了让首页更接近真正的总控台，而不是继续把运行态塞进项目元信息下面。

配合这件事，本轮也把最刺眼的内部状态词和反馈改成了中文人话，避免用户先做一轮枚举翻译再判断现场。

为了减少“点进去以后又是另一套页面”的割裂感，首页项目概览区保留了 `项目现场` 入口，但它本质上只是同一个 Dashboard 的聚焦模式。

### 为什么首页先成为主入口

因为当前首页的信息已经足够承接第一判断动作，继续把人往 `Project page` 引导只会增加路径噪音。

因此这轮把旧的项目页入口吸收到 Dashboard 内；旧路由只保留为“聚焦项目模式”，不再维持第二套独立页面。

聚焦模式额外补了一块项目摘要和“返回总览”入口，并把活跃运行数、`JSON 摘要`、`Worker 页面` 一起放回摘要区，让单项目查看仍然留在同一套视图里完成。

### 为什么预检不用“永远强制展开”

因为自动展开只适合第一次反馈，不适合持续使用。用户看完后需要能自己收起，不然首页会越来越吵。

### 为什么首页还保留 `项目现场` 入口

用户仍然需要一个“只看这个项目”的低噪音视图，但不需要为此跳到另一套页面系统里。

因此当前方案是：

1. 首页保留 `项目现场` 链接。
2. 链接目标仍然是 `/projects/:project_id`。
3. 但该路由现在只是 Dashboard 的聚焦模式，而不是旧的 `ProjectLive` 页面。

这样既保留了单项目聚焦能力，又不会回到“首页一套、项目页一套”的分裂结构。
