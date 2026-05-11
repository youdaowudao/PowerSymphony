# 02. Superpower 前置头脑风暴

## 1. 要解决的真实问题

这次二开不是为了“更多功能”，而是为了让 Symphony 成为一个能长期干活的本地执行控制台。

当前原型机的主要不足：

1. **单项目限制。** 官方原型机一次读一个 workflow，真实使用需要同时管理多个项目。
2. **Web 信息太粗。** 当前 dashboard/API 只显示少量运行信息，难以判断 Codex 线程到底在干什么。
3. **Codex 事件不可读。** 原始事件太细，当前展示又太粗，缺少中间层状态摘要。
4. **Workflow 过重。** `WORKFLOW.md` 既是配置又是长 prompt，又承载项目规则，人工维护压力大。
5. **后台信息不能乱推前端。** 如果总览页默认拉取所有 raw event / payload / logs，会造成资源浪费和卡顿。

---

## 2. 最终产品形态

目标产品不是复杂云平台，而是一个本地控制台：

```text
Symphony Control Plane
  ├─ 读取 symphony.projects.yaml
  ├─ 管理多个 Project Worker OS 进程
  ├─ 聚合轻量 summary
  ├─ 展示项目总览 / 项目详情 / Run 详情
  ├─ 按需代理 timeline / event / raw payload
  └─ 编译每项目 workflow 源文件
```

每个 Project Worker 仍然是单项目 Symphony：

```text
Project Worker
  ├─ WORKFLOW.generated.md
  ├─ Linear project_slug
  ├─ workspace_root
  ├─ logs_root
  ├─ Codex app-server
  └─ RunTrace / Summary API
```

---

## 3. 用户视角的核心体验

### 3.1 项目总览页

一打开 Web 页面就能看到：

```text
项目 | worker 状态 | running | quiet | stalled | retrying | needs_attention | 最近活动 | token | 最后错误
```

这个页面不能加载 raw event。

### 3.2 项目详情页

进入某个项目后，看到该项目所有活跃 issue/run：

```text
Issue | Linear 状态 | 当前阶段 | 当前动作 | 健康状态 | Codex thread | turn | 最近活动 | 持续时间
```

### 3.3 Run 详情页

进入某个 run 后，看压缩时间线：

```text
12:01:03 领取 Linear 事项
12:01:05 准备 workspace
12:01:08 启动 Codex session
12:01:14 Codex 正在分析需求
12:01:46 Codex 正在修改文件
12:02:10 正在运行测试命令
12:04:30 最近 2 分钟无新事件，标记 quiet
```

### 3.4 Event 详情页

点某条事件才看 payload 摘要和必要的原始字段。

### 3.5 Raw 调试页

只有调试时打开完整 JSON / shell output / prompt / Linear response。

---

## 4. 成功标准

### 4.1 可用性成功标准

- 能配置 2 个以上项目。
- 能从一个 Web 控制台启动/停止/重启项目 worker。
- 任意一个项目 worker 出错，不影响控制面和其他项目 worker。
- 总览页能一眼看出谁在工作、谁变慢、谁卡住、谁需要人工处理。

### 4.2 可观测性成功标准

每个 run 至少有：

- `current_phase`
- `current_action`
- `health`
- `last_event_at`
- `run_duration_seconds`
- `session_id`
- `thread_id`
- `turn_id`
- `turn_count`
- `last_meaningful_event`
- `last_error`
- `next_retry_at`

### 4.3 性能成功标准

- 项目总览页不加载 raw event。
- 项目详情页不加载完整 timeline。
- Run 详情页默认只加载最近 N 条压缩事件。
- Event payload 点击后懒加载。
- LiveView 推送只推 summary diff。
- 1-5 个项目同时运行时，Web 不明显卡顿。

### 4.4 工程成功标准

- 改动不破坏单项目原有启动方式。
- 原有 `./bin/symphony ./WORKFLOW.md` 仍可用。
- 新增 `./bin/symphony_control --config symphony.projects.yaml --port 4000`。
- 增加 fake worker / fake Codex / fake Linear 测试。
- 每个阶段可回滚。

---

## 5. 非目标

第一版明确不做：

- 企业多用户权限系统。
- 云端部署控制台。
- 拖拽式工作流编辑器。
- 复杂 DAG 工作流引擎。
- 跨项目精确全局调度器。
- 数据库型日志平台。
- 对核心 Codex app-server 协议做大改。
- 将所有项目揉入一个 `WORKFLOW.md`。

---

## 6. Superpower 头脑风暴结论

### 6.1 最有价值的能力

最有价值的不是“显示更多日志”，而是：

> **用少量状态字段表达 Codex 当前到底在干什么，以及它是否还在推进。**

因此 Web 设计要围绕三元组：

```text
current_phase + current_action + health
```

### 6.2 最危险的错误方向

最危险的是把后台事件当成前端状态：

```text
错误方向：Codex raw event -> LiveView -> 页面直接显示
```

正确方向：

```text
Codex raw event
  -> EventNormalizer
  -> StateReducer
  -> RunSummary
  -> LiveView summary diff
```

### 6.3 最稳的多项目边界

多项目不是把 core orchestrator 改成多项目，而是让每个项目继续拥有自己的单项目 worker。控制面只聚合、管理和代理。

### 6.4 Workflow 的正确边界

`WORKFLOW.md` 不能消失，因为它是项目策略契约。正确做法是让它成为生成物，而不是人工维护的巨文档。

---

## 7. 关键设计原则

1. **外层包裹，内核稳定。** 多项目能力放在控制面，不塞进核心 orchestrator。
2. **后台厚，前端薄。** 后台记录足够多，前端默认展示足够少。
3. **摘要优先，raw 懒加载。** 所有 raw payload 都要有明确点击动作才加载。
4. **状态可判断。** 不只显示 running，要显示正在做什么、多久没动、是否异常。
5. **项目独立。** workflow、workspace、logs、worker port 都按项目隔离。
6. **生成而非手写巨文档。** Workflow 人维护小文件，运行时吃 generated。
7. **质量门禁保护方向。** 每阶段必须证明没有把核心链路改坏，没有把前端做重。
