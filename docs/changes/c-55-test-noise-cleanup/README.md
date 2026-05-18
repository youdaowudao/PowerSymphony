# C-55 Test Noise Cleanup

## 目标

清理本地 `make all` 中已确认的 3 类测试 / shell 噪音，在不改变现有测试语义和流程行为的前提下，让日志输出更干净、更可判读。

## 需求快照

### 要解决什么问题

- `mix test --cover` 会对 `test/support/project_process_manager_fake_worker.exs` 打出 `test_ignore_filters` 相关 warning。
- `ProjectProcessManager` 的启动包装命令在测试故意传入坏 shell 语法时，会把解析期 stderr 直接漏到控制台，而不是收进 `worker.stderr.log`。
- 若无额外依赖 login shell，测试 helper 中的 `bash -lc` 会顺带执行系统 profile，导致 `flatpak.sh ... Broken pipe` 这类环境噪音进入测试输出。

### 成功标准

- 与 `project_process_manager_fake_worker.exs` 相关的 `test_pattern` / `test_ignore_filters` warning 消失。
- `startup shell parse errors surface as start_failed` 之类故意触发坏 shell 命令的测试，仍保持原有断言，但不再把 shell parse error 直接打到测试控制台。
- 若 helper 无需 login shell，则改成更窄的 shell 执行方式，消除 `flatpak.sh ... Broken pipe` 这类环境噪音。
- 变更保持小范围，可由定向测试和必要的局部门禁直接证明。

### 明确不做什么

- 不改变 `ProjectProcessManager` 的状态机、错误分类或 `start_failed` 行为。
- 不修改生产流程合同、review 规则或 workflow 收口规则。
- 不为了清理日志而删除现有覆盖坏命令 / 启动失败路径的测试。

### 固定约束

- 优先做最小修复，先补会失败的断言或可观测验证，再改实现。
- 若某个 helper 仍依赖 login shell 语义，不得为了压噪音盲目改成 `-c`。
- 仅在仓库内相关文件改动，不扩展到无关测试。
