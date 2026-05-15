# C-50 Ownership Gate

## 目标

修复 `C-50 / M3 紧急修复：错误多开线程` 的 ownership split-brain 路径，严格保证单个健康 orchestrator 实例内，同一 `issue_id` 在 ownership 未明确释放前不会并发多跑 worker，并修正跨代 `session/thread/turn` 混拼。

## 需求快照

### 要解决什么问题

- stall / stop 路径会在旧 owner 未确认安全结束前释放 claim，导致同一 issue 被重新 dispatch，多开 worker。
- `RunTrace` / `RunStateStore` / snapshot 可能混入不同 attempt 的 `session_id`、`thread_id`、`turn_id`，产生跨代假现场。

### 成功标准

- 单个健康 orchestrator 实例内，同一 `issue_id` 任意时刻最多只有一个被当前进程承认的 active owner。
- owner 释放必须建立在明确的 release condition 上，不能在远端 stop 未确认前乐观重派发。
- 单个 worker 生命周期内连续 turn 继续复用同一个 app-server thread。
- summary 与 snapshot 只消费当前 generation 的运行态字段，不再跨代混拼。

### 明确不做什么

- 不承诺跨 worker、跨进程或重启后的 thread continuity。
- 不新增全局远端线程注册中心、持久化 lease 或 fencing token。
- 不把 snapshot / dashboard 升格为 ownership 真相源。

### 固定约束

- 本轮优先走保守修复：协作式 interrupt、generation 隔离、gate 延迟释放。
- 外层 continuation 仍需保住合法续跑路径，不能简单通过删逻辑规避问题。
- 验证以定向 ExUnit、局部格式检查和零上下文复核为主。

## 文档索引

- [10_design.md](./10_design.md)
- [20_plan.md](./20_plan.md)
