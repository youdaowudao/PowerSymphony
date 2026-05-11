# Workflow Migration Design

## Goal

Absorb the newer in-repo workflow contract from the old Symphony working tree into
`PowerSymphony` so the current repository can render, validate, test, and locally
start against the new `elixir/WORKFLOW.md` instead of the older OpenAI-template
contract.

## Confirmed Current State

1. `elixir/WORKFLOW.md` in `PowerSymphony` already matches the intended newer
   contract. The old repo working tree carries the same text.
2. The old repo does **not** provide a clean committed implementation that fully
   lands this contract. Its `HEAD` still contains older workflow assumptions, and
   many local changes are unrelated to this migration.
3. `elixir/lib/symphony_elixir/workflow.ex` and
   `elixir/lib/symphony_elixir/prompt_builder.ex` already treat `WORKFLOW.md` as
   runtime input and do not need a contract-specific parser change for the new
   template.
4. The first obvious contract mismatch is in tests:
   - `elixir/test/symphony_elixir/core_test.exs` still asserts old prompt phrases
     such as `This is an unattended orchestration session.`
   - the same file still expects old hook content such as cloning
     `https://github.com/openai/symphony`.
5. Local targeted testing exposed an additional independent blocker:
   `elixir/lib/symphony_elixir_web/static_assets.ex` reads Phoenix JS assets from
   `Application.app_dir(...)`, which resolves into `_build/<env>/lib/...`. In a
   fresh local test environment those static files are not reliably present even
   after dependency compilation, so test compilation can fail before any workflow
   assertions run.

## Non-Goals

This migration does **not** attempt to absorb every local change from the old repo.
In particular, it does not automatically merge:

- unrelated control-plane work
- orchestrator retry policy changes
- dashboard/runtime summary work
- broad CLI or app-server experiments

Those areas are only touched if they are directly required to make the new
workflow contract testable and runnable in the current repository.

## Design Decisions

### 1. Treat the current `elixir/WORKFLOW.md` as the source contract

The migration target is the current checked-in `PowerSymphony` workflow file plus
the user-provided design intent from earlier external workflow notes, not the old
repo's committed `HEAD`.

Implication:

- update tests and docs to the new contract
- avoid speculative rewrites to prompt/rendering code unless tests prove they are
  needed

### 2. Update workflow-facing tests to assert stable semantics, not stale prose

`core_test.exs` should keep verifying that the in-repo workflow renders critical
runtime guidance, issue interpolation, retry context, and repository-specific
instructions. It should stop hard-coding phrases that were intentionally replaced
by the newer contract.

This includes:

- prompt assertions for new sections like `Stable issue-body model`,
  `Preflight body gate`, `Execution Brief`, and `Codex Workpad`
- workflow config assertions for the new hook commands and repository path
- retention of checks that still matter regardless of wording, such as issue
  identifiers, retry context, and repo-skill instructions

### 3. Make embedded Phoenix asset loading robust for local targeted tests

`StaticAssets` should read vendored JS assets from a path that is stable in both
local source checkouts and compiled dependency layouts.

Preferred behavior:

- first use `deps/<package>/priv/static/...` when present in a source checkout
- otherwise fall back to `Application.app_dir(...)` for packaged/compiled layouts

This keeps runtime behavior unchanged while removing a local test/compile trap.

### 4. Sync README run instructions with the current repository reality

`elixir/README.md` still documents cloning `openai/symphony` and does not reflect
the current `PowerSymphony` workflow defaults. The migration should update the
README so the documented bootstrap path matches the actual repository and current
workflow expectations.

### 5. Use targeted verification only

Per repo policy, do not run `make all`. Verification will stay local and scoped:

- targeted `core_test.exs`
- targeted `cli_test.exs` if README or startup behavior depends on it
- targeted `extensions_test.exs` or a focused static-asset route test if the
  asset loader changes
- one bounded local startup check using the documented CLI entrypoint, only after
  tests are green enough to support it

## Files Expected To Change

- `elixir/lib/symphony_elixir_web/static_assets.ex`
- `elixir/test/symphony_elixir/core_test.exs`
- `elixir/README.md`

Potentially touched only if required by verification:

- `elixir/test/symphony_elixir/extensions_test.exs`
- `elixir/test/symphony_elixir/cli_test.exs`

## Verification Strategy

1. Red phase:
   - run targeted workflow tests and capture current failures
   - run enough local compile/test setup to expose the static-assets blocker
2. Green phase:
   - fix static asset loading so targeted tests can compile reliably
   - update workflow tests to the new contract
   - update README instructions
3. Final evidence:
   - targeted test commands pass
   - documented local startup command can at least evaluate/launch with the new
     workflow path assumptions
   - diff stays constrained to workflow migration scope
