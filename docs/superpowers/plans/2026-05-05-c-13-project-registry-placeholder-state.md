# C-13 ProjectRegistry Placeholder State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为控制面补上 `ProjectRegistry` 与项目占位状态模型，让 Web/API 在不启动真实 worker 的前提下，也能表达多项目的配置校验结果与 `not_started` 占位态。

**Architecture:** 在 `ProjectConfigStore` 之上新增 `ProjectRegistry` 聚合层，保留每个原始项目行并把校验结果折叠为统一 registry entry。控制面通过新的 presenter 投影读取 registry summary，而不是直接从单项目 orchestrator snapshot 推断项目状态。M1 仅暴露 `valid` / `invalid` / `not_started` 与校验错误，不引入真实 worker 字段。

**Tech Stack:** Elixir, Phoenix Controller/LiveView, ExUnit

---

### Task 1: 定义 ProjectRegistry 数据模型与核心行为

**Files:**
- Create: `elixir/lib/symphony_elixir/project_registry.ex`
- Create: `elixir/test/symphony_elixir/project_registry_test.exs`
- Modify: `elixir/lib/symphony_elixir/project_config_store.ex`

- [ ] **Step 1: 写失败测试，定义 registry entry 的最小 contract**

```elixir
test "builds entries for valid and invalid projects while preserving not_started runtime state" do
  yaml = """
  projects:
    - id: alpha
      name: Alpha
      workflow_generated: /tmp/alpha/WORKFLOW.generated.md
      workspace_root: /tmp/workspaces/alpha
      logs_root: /tmp/logs/alpha
    - id: Beta
      name: Beta
      workflow_generated: /tmp/beta/WORKFLOW.generated.md
      workspace_root: /tmp/workspaces/beta
      logs_root: /tmp/logs/beta
  """

  assert {:ok, registry} = ProjectRegistry.build(yaml)

  assert [
           %{
             project_id: "alpha",
             project_name: "Alpha",
             validation_result: :valid,
             validation_errors: [],
             runtime_state: %{status: :not_started},
             normalized_config: %ProjectConfig{id: "alpha"}
           },
           %{
             project_id: "Beta",
             project_name: "Beta",
             validation_result: :invalid,
             validation_errors: [%ProjectConfigError{field: "id"}],
             runtime_state: %{status: :not_started},
             normalized_config: nil
           }
         ] = ProjectRegistry.entries(registry)
end
```

- [ ] **Step 2: 运行测试，确认当前缺少 `ProjectRegistry` 而失败**

Run: `cd elixir && mix test test/symphony_elixir/project_registry_test.exs`
Expected: FAIL，提示 `SymphonyElixir.ProjectRegistry` 未定义或 `build/1` 不存在。

- [ ] **Step 3: 先补最小数据面实现**

```elixir
defmodule SymphonyElixir.ProjectRegistry do
  @moduledoc """
  M1 control-plane registry that preserves per-project config validation state
  and a placeholder runtime state without starting real workers.
  """

  alias SymphonyElixir.{ProjectConfig, ProjectConfigError, ProjectConfigStore}

  defmodule Entry do
    @enforce_keys [
      :project_id,
      :project_name,
      :normalized_config,
      :validation_result,
      :validation_errors,
      :runtime_state
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            project_id: String.t() | nil,
            project_name: String.t() | nil,
            normalized_config: ProjectConfig.t() | nil,
            validation_result: :valid | :invalid,
            validation_errors: [ProjectConfigError.t()],
            runtime_state: %{status: :not_started}
          }
  end

  @type t :: %__MODULE__{entries: [Entry.t()]}
  defstruct entries: []

  @spec build(String.t()) :: {:ok, t()}
  def build(yaml) when is_binary(yaml) do
    with {:ok, decoded} <- ProjectConfigStore.decode_projects(yaml) do
      {:ok, %__MODULE__{entries: build_entries(decoded)}}
    end
  end

  @spec entries(t()) :: [Entry.t()]
  def entries(%__MODULE__{entries: entries}), do: entries
end
```

- [ ] **Step 4: 运行定向测试，确认绿灯**

Run: `cd elixir && mix test test/symphony_elixir/project_registry_test.exs`
Expected: PASS

- [ ] **Step 5: 小幅整理并补充边界测试**

```elixir
test "keeps validation state isolated between two valid projects" do
  assert {:ok, registry} = ProjectRegistry.load(@sample_config_path)
  [first, second] = ProjectRegistry.entries(registry)

  assert first.project_id == "chatgpt-extension"
  assert second.project_id == "docs-site"
  assert first.runtime_state == %{status: :not_started}
  assert second.runtime_state == %{status: :not_started}
end
```

### Task 2: 为 ProjectConfigStore 暴露 registry 所需的原始项目读取能力

**Files:**
- Modify: `elixir/lib/symphony_elixir/project_config_store.ex`
- Modify: `elixir/test/symphony_elixir/project_config_store_test.exs`
- Test: `elixir/test/symphony_elixir/project_registry_test.exs`

- [ ] **Step 1: 写失败测试，固定 decode/raw project 行为**

```elixir
test "decodes normalized raw projects for registry consumers" do
  yaml = """
  projects:
    - id: alpha
      name: Alpha
      workflow_generated: /tmp/alpha/WORKFLOW.generated.md
      workspace_root: /tmp/workspaces/alpha
      logs_root: /tmp/logs/alpha
  """

  assert {:ok, [%{"id" => "alpha", "name" => "Alpha"}]} =
           ProjectConfigStore.decode_projects(yaml)
end
```

- [ ] **Step 2: 运行相关测试，确认 `decode_projects/1` 缺失而失败**

Run: `cd elixir && mix test test/symphony_elixir/project_config_store_test.exs`
Expected: FAIL，提示 `decode_projects/1` 未定义。

- [ ] **Step 3: 实现最小公开函数，复用现有 decode/normalize 逻辑**

```elixir
@spec decode_projects(String.t()) :: {:ok, [map()]} | {:error, [ProjectConfigError.t()]}
def decode_projects(yaml) when is_binary(yaml) do
  with {:ok, decoded} <- decode_yaml(yaml),
       {:ok, projects} <- fetch_projects(decoded),
       :ok <- validate_root_fields(decoded) do
    {:ok, projects}
  end
end
```

- [ ] **Step 4: 运行 `ProjectConfigStore` 与 `ProjectRegistry` 测试**

Run: `cd elixir && mix test test/symphony_elixir/project_config_store_test.exs test/symphony_elixir/project_registry_test.exs`
Expected: PASS

- [ ] **Step 5: 确认没有改变现有 `load/1` / `parse_string/1` 行为**

Run: `cd elixir && mix test test/symphony_elixir/project_config_store_test.exs`
Expected: PASS，且既有断言无需改语义。

### Task 3: 接入控制面 presenter 与 JSON API

**Files:**
- Modify: `elixir/lib/symphony_elixir_web/presenter.ex`
- Modify: `elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex`
- Modify: `elixir/lib/symphony_elixir_web/router.ex`
- Modify: `elixir/test/symphony_elixir/extensions_test.exs`

- [ ] **Step 1: 先写失败测试，固定 `/api/v1/projects` 与 `/api/v1/projects/:project_id/summary` 响应**

```elixir
test "phoenix control-plane api exposes project registry summaries" do
  start_test_endpoint(
    project_registry: %{
      entries: [
        %{
          project_id: "alpha",
          project_name: "Alpha",
          validation_result: :valid,
          validation_errors: [],
          runtime_state: %{status: :not_started}
        },
        %{
          project_id: "Beta",
          project_name: "Beta",
          validation_result: :invalid,
          validation_errors: [%{field: "id", message: "id must match ..."}],
          runtime_state: %{status: :not_started}
        }
      ]
    }
  )

  payload = json_response(get(build_conn(), "/api/v1/projects"), 200)
  assert Enum.map(payload["projects"], & &1["project_id"]) == ["alpha", "Beta"]

  detail = json_response(get(build_conn(), "/api/v1/projects/alpha/summary"), 200)
  assert detail["project"]["runtime_state"]["status"] == "not_started"
end
```

- [ ] **Step 2: 运行测试，确认路由/动作未实现而失败**

Run: `cd elixir && mix test test/symphony_elixir/extensions_test.exs`
Expected: FAIL，提示路由 404 或 controller action 缺失。

- [ ] **Step 3: 让 presenter 读 registry 投影，而不是扩展 orchestrator snapshot**

```elixir
@spec projects_payload(map() | ProjectRegistry.t()) :: map()
def projects_payload(registry) do
  %{
    generated_at: generated_at(),
    projects: Enum.map(ProjectRegistry.entries(registry), &project_summary_payload/1)
  }
end

@spec project_summary_payload(String.t(), map() | ProjectRegistry.t()) ::
        {:ok, map()} | {:error, :project_not_found}
def project_summary_payload(project_id, registry) do
  case Enum.find(ProjectRegistry.entries(registry), &(&1.project_id == project_id)) do
    nil -> {:error, :project_not_found}
    entry -> {:ok, %{generated_at: generated_at(), project: project_summary_payload(entry)}}
  end
end
```

- [ ] **Step 4: 跑 API 测试并修正 JSON 细节**

Run: `cd elixir && mix test test/symphony_elixir/extensions_test.exs`
Expected: PASS

- [ ] **Step 5: 补 method_not_allowed / not_found 不回归检查**

Run: `cd elixir && mix test test/symphony_elixir/extensions_test.exs`
Expected: PASS，已有 `/api/v1/state` 行为不受影响。

### Task 4: 接入 LiveView 总览与最小控制面启动注入

**Files:**
- Modify: `elixir/lib/symphony_elixir/http_server.ex`
- Modify: `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`
- Modify: `elixir/lib/symphony_elixir_web/presenter.ex`
- Modify: `elixir/test/symphony_elixir/extensions_test.exs`

- [ ] **Step 1: 写失败测试，要求首页展示项目列表与占位状态**

```elixir
test "dashboard liveview renders project registry placeholder states" do
  start_test_endpoint(project_registry: sample_registry())

  {:ok, _view, html} = live(build_conn(), "/")
  assert html =~ "Projects"
  assert html =~ "Alpha"
  assert html =~ "not_started"
  assert html =~ "invalid"
end
```

- [ ] **Step 2: 运行定向测试，确认当前首页没有项目区块而失败**

Run: `cd elixir && mix test test/symphony_elixir/extensions_test.exs`
Expected: FAIL，首页不含 `Projects` 区块。

- [ ] **Step 3: 只追加 M1 需要的项目摘要区块，不改现有运行 issue 面板语义**

```elixir
socket =
  socket
  |> assign(:payload, load_payload())
  |> assign(:projects_payload, load_projects_payload())
  |> assign(:now, DateTime.utc_now())
```

```heex
<section class="section-card">
  <div class="section-header">
    <div>
      <h2 class="section-title">Projects</h2>
      <p class="section-copy">Static config validation and placeholder runtime state.</p>
    </div>
  </div>
  <div class="table-wrap">
    <table class="data-table">
      ...
    </table>
  </div>
</section>
```

- [ ] **Step 4: 跑 LiveView/API 测试**

Run: `cd elixir && mix test test/symphony_elixir/extensions_test.exs`
Expected: PASS

- [ ] **Step 5: 确认 M1 仍未引入真实 worker 字段**

Run: `cd elixir && rg -n 'worker_pid|health poll|stdout|stderr|restart|start|stop' lib/symphony_elixir lib/symphony_elixir_web`
Expected: 仅命中既有无关代码或文档，不出现新的 `ProjectRegistry` 真实 worker 状态字段。

### Task 5: 全量定向验证与收尾准备

**Files:**
- Modify: `docs/superpowers/plans/2026-05-05-c-13-project-registry-placeholder-state.md`
- Test: `elixir/test/symphony_elixir/project_registry_test.exs`
- Test: `elixir/test/symphony_elixir/project_config_store_test.exs`
- Test: `elixir/test/symphony_elixir/extensions_test.exs`

- [ ] **Step 1: 运行 registry 定向验证**

Run: `cd elixir && mix test test/symphony_elixir/project_registry_test.exs`
Expected: PASS

- [ ] **Step 2: 运行 config store 回归验证**

Run: `cd elixir && mix test test/symphony_elixir/project_config_store_test.exs`
Expected: PASS

- [ ] **Step 3: 运行控制面扩展验证**

Run: `cd elixir && mix test test/symphony_elixir/extensions_test.exs`
Expected: PASS

- [ ] **Step 4: 运行接口规范检查**

Run: `cd elixir && mix specs.check`
Expected: PASS

- [ ] **Step 5: 更新计划复选框、整理验证结论并准备交给 reviewer**

```bash
git status --short
git diff --stat
```
