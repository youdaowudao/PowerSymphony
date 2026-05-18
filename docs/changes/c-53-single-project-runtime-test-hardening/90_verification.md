# C-53 运行时测试补强验证与门禁说明

## 用途

本文件定义 C-53 首批运行时测试补强的验证方式，并明确“这些测试什么时候跑、是否进入质量门”。

## 运行分层结论

### 结论一句话

这批测试**不是独立增强套件**，而是**进入现有 ExUnit 主套件的运行时硬化回归**。

### 开发阶段怎么跑

开发阶段只跑与改动面直接对应的定向测试：

- `m3_precheck`
  ```bash
  cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/m3_precheck_test.exs
  ```
- `orchestrator / retry / checking`
  ```bash
  cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs
  ```
- `app_server / resume barrier`
  ```bash
  cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/app_server_test.exs
  ```
- `run_state_store / observability generation filtering`
  ```bash
  cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/run_state_store_test.exs
  ```

### PR create/update 前怎么跑

这张卡一旦落测试代码，就会命中 `elixir/**`。

因此按当前仓库规则：

- `Next Push Gate` 必须走 `local make all`
- 也就是 push 前必须执行：

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- make all
```

### 远端 CI 怎么跑

- 这些测试作为 `mix test` 主套件的一部分进入远端 full gate。
- 远端 CI 是最终复核器，不应是第一次发现这批问题的主要入口。

## 首批 10 条验证矩阵

| # | 场景 | 主验证文件 | 开发阶段默认跑法 | PR gate 是否随 `make all` 进入 |
| --- | --- | --- | --- | --- |
| 1 | Precheck 可开工判定 | `m3_precheck_test.exs` | 定向跑该文件 | 是 |
| 2 | Precheck blockedBy 未满足 | `m3_precheck_test.exs` | 定向跑该文件 | 是 |
| 3 | Precheck current_work 不可重复开工 | `m3_precheck_test.exs` | 定向跑该文件 | 是 |
| 4 | Precheck blocked_but_in_progress 异常暴露 | `m3_precheck_test.exs` | 定向跑该文件 | 是 |
| 5 | Dispatch 开工动作正确 | `orchestrator_status_test.exs` | 定向跑该文件 | 是 |
| 6 | Retry 生成新 `run_instance_id` | `orchestrator_status_test.exs` | 定向跑该文件 | 是 |
| 7 | Stale continuation 不污染当前运行 | `orchestrator_status_test.exs` + `run_state_store_test.exs` | 定向跑相关文件 | 是 |
| 8 | `turn/completed` 之后必须过 resume barrier | `app_server_test.exs` | 定向跑该文件 | 是 |
| 9 | completed 后的 late fail/interrupted 不能算成功 | `app_server_test.exs` | 定向跑该文件 | 是 |
| 10 | Checking 是单轮 bounded recheck | `orchestrator_status_test.exs` | 定向跑该文件 | 是 |

## 当前覆盖基线

### 已有测试已经覆盖或高度接近的场景

- `m3_precheck_test.exs`
  - `eligible / dispatch`
  - non-terminal blockers
  - `blocked_but_in_progress`
- `orchestrator_status_test.exs`
  - accepted dispatch trace
  - stale generation codex update / run result 过滤
  - `checking_recheck` cooldown 与 restricted mode
- `app_server_test.exs`
  - `completed then cancelled`
  - `completed then failed`
  - delayed late terminal conflicts
- `run_state_store_test.exs`
  - summary/detail/surface 的代际过滤

### 首批仍需补强的重点

- 同一卡已在 `current_work` 中时不可重复开工
- retry 必须切换到新 `run_instance_id`
- dispatch 成功时 claim / running / trace 三者一致
- `completed` 只是 provisional success，不能跳过 `thread/resume`

## 文档阶段的静态自检

提交本批文档前，至少应确认：

1. 文档明确区分了：
   - 开发期定向测试
   - PR full gate
   - 远端 CI 最终复核
2. 文档没有把这批测试写成独立平台或独立 lane。
3. 首批 10 条都有明确落位文件。
4. `run_live` 没有被误拉成第一批主改动面。
5. `core_test.exs` 与 `run_trace_test.exs` 的角色是支撑而不是默认主落点。

## 后续实现阶段的最小 closeout 验证

如果后续开始落实首批测试，closeout 至少需要：

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix format --check-formatted
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix lint
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/m3_precheck_test.exs
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/app_server_test.exs
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/run_state_store_test.exs
```

如果该次 push 将 create/update PR，则再按仓库 full gate 追加：

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- make all
```

## 收口标准

满足以下条件时，文档层才算完成：

1. 已明确这批测试属于“运行时协议硬化测试”。
2. 已明确它们进入现有 ExUnit 主套件，而不是独立增强通道。
3. 已明确开发阶段和 PR gate 的不同跑法。
4. 已给出首批 10 条的落位与当前覆盖判断。
