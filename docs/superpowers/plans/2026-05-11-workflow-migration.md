# Workflow Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `PowerSymphony` fully absorb the newer workflow contract already
checked into `elixir/WORKFLOW.md`, including matching tests, stable local asset
compilation, and updated startup documentation.

**Architecture:** Keep the current workflow loader and prompt renderer intact
unless tests prove a real behavior gap. First remove the local compilation blocker
in `StaticAssets`, then update workflow-facing tests to the new contract, then
sync README instructions and finish with targeted verification plus one bounded
startup check.

**Tech Stack:** Elixir, Phoenix, ExUnit, mise, Hex/Mix

---

### Task 1: Stabilize embedded static asset loading for local targeted tests

**Files:**
- Modify: `elixir/lib/symphony_elixir_web/static_assets.ex`
- Test: `elixir/test/symphony_elixir/extensions_test.exs`

- [ ] **Step 1: Add a failing or reproducible compile/test signal for the current asset-path bug**

Use the already observed failure as the baseline:

```bash
cd elixir && \
HEX_HOME=/home/ss/.local/share/mise/.hex \
MIX_HOME=/home/ss/.local/share/mise/.mix \
REBAR_CACHE_DIR=/home/ss/.cache/rebar3 \
/home/ss/.local/bin/mise exec -- mix test test/symphony_elixir/core_test.exs:130
```

Expected: compile failure from `lib/symphony_elixir_web/static_assets.ex`
trying to read `_build/test/lib/phoenix_html/priv/static/phoenix_html.js`.

- [ ] **Step 2: Implement stable asset path resolution with source-checkout fallback**

Update `StaticAssets` so each vendor asset path is resolved through a helper with
logic like:

```elixir
defp dependency_asset_path(app, relative_path) do
  source_path = Path.expand("../deps/#{app}/#{relative_path}", __DIR__)

  if File.exists?(source_path) do
    source_path
  else
    Application.app_dir(app, relative_path)
  end
end
```

Use this helper for:

```elixir
@phoenix_html_js_path dependency_asset_path(:phoenix_html, "priv/static/phoenix_html.js")
@phoenix_js_path dependency_asset_path(:phoenix, "priv/static/phoenix.js")
@phoenix_live_view_js_path dependency_asset_path(:phoenix_live_view, "priv/static/phoenix_live_view.js")
```

- [ ] **Step 3: Run the narrowest asset-facing test to verify the compile blocker is gone**

Run:

```bash
cd elixir && \
HEX_HOME=/home/ss/.local/share/mise/.hex \
MIX_HOME=/home/ss/.local/share/mise/.mix \
REBAR_CACHE_DIR=/home/ss/.cache/rebar3 \
/home/ss/.local/bin/mise exec -- mix test test/symphony_elixir/extensions_test.exs
```

Expected: compile succeeds; any remaining failures should now be real test
failures, not missing vendor asset files.

### Task 2: Update workflow contract tests to the new `WORKFLOW.md`

**Files:**
- Modify: `elixir/test/symphony_elixir/core_test.exs`

- [ ] **Step 1: Rewrite the current-workflow validation assertions to the new repo defaults**

In `test "current WORKFLOW.md file is valid and complete"`, replace old
OpenAI-specific expectations with assertions that match the current workflow:

```elixir
assert Map.get(hooks, "after_create") =~ "https://github.com/youdaowudao/PowerSymphony.git"
refute Map.get(hooks, "after_create") =~ "https://github.com/openai/symphony"
assert Map.get(hooks, "before_remove") =~ "true"
```

Keep checks that still prove real configuration shape:

```elixir
assert is_binary(Map.get(tracker, "project_slug"))
assert String.trim(prompt) != ""
assert Config.workflow_prompt() == prompt
```

- [ ] **Step 2: Rewrite the in-repo workflow prompt test around the new contract**

In `test "in-repo WORKFLOW.md renders correctly"`, keep interpolation and retry
assertions, but replace stale prose checks with assertions like:

```elixir
assert prompt =~ "## Stable issue-body model"
assert prompt =~ "## Preflight body gate"
assert prompt =~ "## Execution Brief"
assert prompt =~ "## Codex Workpad"
assert prompt =~ "This is retry attempt #2 because the ticket is still in an active state."
assert prompt =~ "Do not end the turn while the issue remains in an active state"
assert prompt =~ "open and follow `.codex/skills/land/SKILL.md`"
assert prompt =~ "Do not call `gh pr merge` directly"
```

Remove assertions for:

```elixir
"This is an unattended orchestration session."
"Only stop early for a true blocker"
"Do not include \"next steps for user\""
```

- [ ] **Step 3: Run just the workflow-facing tests and verify red/green explicitly**

Run:

```bash
cd elixir && \
HEX_HOME=/home/ss/.local/share/mise/.hex \
MIX_HOME=/home/ss/.local/share/mise/.mix \
REBAR_CACHE_DIR=/home/ss/.cache/rebar3 \
/home/ss/.local/bin/mise exec -- mix test \
  test/symphony_elixir/core_test.exs:130 \
  test/symphony_elixir/core_test.exs:1339
```

Expected: both tests pass after the assertion updates.

### Task 3: Sync README startup instructions with the migrated workflow

**Files:**
- Modify: `elixir/README.md`
- Test: `elixir/test/symphony_elixir/cli_test.exs` (only if startup semantics are touched)

- [ ] **Step 1: Update the documented clone/bootstrap path to match `PowerSymphony`**

Replace the old run section:

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
```

with repository-accurate instructions such as:

```bash
git clone https://github.com/youdaowudao/PowerSymphony.git
cd PowerSymphony/elixir
```

Keep the rest aligned with the actual local tooling:

```bash
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

- [ ] **Step 2: Ensure README wording matches the current workflow defaults**

Adjust any surrounding prose that still implies the old upstream repo or old
workflow ownership assumptions, but keep the change minimal and scoped to startup
accuracy.

- [ ] **Step 3: If README changes imply startup semantics, run the existing CLI tests**

Run:

```bash
cd elixir && \
HEX_HOME=/home/ss/.local/share/mise/.hex \
MIX_HOME=/home/ss/.local/share/mise/.mix \
REBAR_CACHE_DIR=/home/ss/.cache/rebar3 \
/home/ss/.local/bin/mise exec -- mix test test/symphony_elixir/cli_test.exs
```

Expected: PASS

### Task 4: Perform bounded local verification, including one startup check

**Files:**
- Modify: `docs/superpowers/specs/2026-05-11-workflow-migration-design.md`
- Modify: `docs/superpowers/plans/2026-05-11-workflow-migration.md`

- [ ] **Step 1: Run the targeted verification bundle**

Run:

```bash
cd elixir && \
HEX_HOME=/home/ss/.local/share/mise/.hex \
MIX_HOME=/home/ss/.local/share/mise/.mix \
REBAR_CACHE_DIR=/home/ss/.cache/rebar3 \
/home/ss/.local/bin/mise exec -- mix test \
  test/symphony_elixir/core_test.exs:130 \
  test/symphony_elixir/core_test.exs:1339 \
  test/symphony_elixir/cli_test.exs
```

Expected: PASS

- [ ] **Step 2: Run a bounded local startup check without entering a full long-running flow**

Use the CLI evaluation/startup path with the repo workflow:

```bash
cd elixir && \
HEX_HOME=/home/ss/.local/share/mise/.hex \
MIX_HOME=/home/ss/.local/share/mise/.mix \
REBAR_CACHE_DIR=/home/ss/.cache/rebar3 \
/home/ss/.local/bin/mise exec -- mix run --no-start -e \
'IO.inspect(SymphonyElixir.CLI.evaluate(["--i-understand-that-this-will-be-running-without-the-usual-guardrails", "WORKFLOW.md"]))'
```

Expected: `:ok` or a startup-ready result that proves the workflow path and CLI
evaluation are coherent without running a full indefinite session.

- [ ] **Step 3: Audit scope before handoff**

Run:

```bash
git diff -- \
  elixir/lib/symphony_elixir_web/static_assets.ex \
  elixir/test/symphony_elixir/core_test.exs \
  elixir/README.md \
  elixir/test/symphony_elixir/extensions_test.exs \
  elixir/test/symphony_elixir/cli_test.exs \
  docs/superpowers/specs/2026-05-11-workflow-migration-design.md \
  docs/superpowers/plans/2026-05-11-workflow-migration.md
```

Expected: diff stays limited to workflow migration, local asset stability, and
supporting docs/tests.

- [ ] **Step 4: Commit with repo-compliant message once all checks are green**

Stage only the intended files and commit with a Chinese summary in the subject,
for example:

```bash
git add \
  elixir/lib/symphony_elixir_web/static_assets.ex \
  elixir/test/symphony_elixir/core_test.exs \
  elixir/README.md \
  docs/superpowers/specs/2026-05-11-workflow-migration-design.md \
  docs/superpowers/plans/2026-05-11-workflow-migration.md

git commit -F /tmp/workflow-migration-commit.txt
```

The final commit message must include:

- a conventional type/scope subject
- a Simplified Chinese summary
- validation commands actually run
