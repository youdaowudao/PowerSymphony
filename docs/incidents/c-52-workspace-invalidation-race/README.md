# C-52 workspace lifecycle fencing 事故

本目录记录 `C-52` 这次事故的事实、时间线、证据、根因和后续修复约束。

这次事故的主轴不是：

- “已经证实 Symphony 对同一张 issue 并发双开了两个顶层 worker”
- “只是外部会话没收到更好看的 invalidation 提示”

当前代码与日志能坐实的更强结论是：

- 主线里已经给**消息状态**做了 generation 保护：`run_instance_id`、generation 过滤、cooperative `turn/interrupt`、`blocked_claim`。
- 但 workspace 这个**物理资源**没有 generation 身份，仍按 `issue identifier` 固定复用。
- workspace 的创建、复用、retry、startup sweep、terminal cleanup 都不看代际。
- terminal cleanup 还会直接“先删 workspace，再停 worker”。
- `AppServer.stop_session/1` 只做 `Port.close`，当前没有可靠的底层 terminal/app-server 终态确认链。
- 外部会话没有统一的 per-turn validity gate，也读不到明确的 invalidation 语义。
- 所以 old run、active run、cleanup side-path 都可能继续碰同一个物理路径，最终才以 `cwd missing` / `No such file or directory` 的形式暴露出来。

这意味着：

- 事故的最深主因更像“workspace 资源生命周期 fencing 缺失”，而不是单纯“少一个 invalidation marker”。
- `owner` 真相源不可读、per-turn validity gate 缺失、错误语义过低，这些都是真的，但它们更像**配套缺口**，不是最底层主因。

## 与 C-50 的边界

- `C-50` 关注的是 ownership gate 过早释放、stalled run split-brain、跨代消息混拼。
- `C-52` 关注的是：消息 generation 已经有保护，但 workspace 资源生命周期没有 generation fencing，导致 cleanup / 复用 / 续跑在同一个物理路径上互相踩踏。

## 本次 incident 需要回答的核心问题

1. 当前主线已经保护了什么，没保护什么
2. 为什么消息 generation 已经受保护，但 workspace 资源仍会被不同生命周期路径反复碰
3. terminal cleanup 路径为什么仍然能把活跃会话脚下的 workspace 抽走
4. startup sweep / retry / blocked-claim cleanup 为什么同样危险
5. 删除前为什么拿不到可靠 run 终态证据
6. 外部会话在每轮执行前有没有校验自己是否仍然有效
7. 为什么用户最终只能看到底层 `cwd missing`

## 文档索引

- [00_摘要.md](./00_摘要.md)
- [10_时间线.md](./10_时间线.md)
- [15_线程捕捉协议.md](./15_线程捕捉协议.md)
- [20_证据.md](./20_证据.md)
- [30_根因分析.md](./30_根因分析.md)
- [40_后续动作.md](./40_后续动作.md)

## 推荐阅读顺序

1. 先看 `00_摘要.md`
2. 再看 `10_时间线.md`
3. 再看 `20_证据.md`
4. 最后看 `30_根因分析.md`
