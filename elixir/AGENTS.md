# Symphony Elixir

This directory contains the Elixir agent orchestration service that polls Linear, creates per-issue workspaces, and runs Codex in app-server mode.

## Environment

- Elixir: `1.19.x` (OTP 28) via `mise`.
- Install deps: `mix setup`.
- Full validation command: `make all` (format check, lint, coverage, dialyzer), used only for final confirmation.
- Do not run `make all` by default.
- First inspect `git diff` and choose the lightest validation that proves the change.
- Development uses targeted tests only.
- Before opening a PR or updating an existing PR, run a closeout gate with format check, lint, and targeted tests for the touched area; docs-only updates still run the gate, but may omit targeted tests when there is no executable coverage tied to the diff.
- Keep local ExUnit concurrency explicitly bounded. All test commands must include `SYMPHONY_TEST_MAX_CASES=4`, and reduce to `2` or `1` if the machine is under pressure.
- GitHub Actions remains the authoritative full `make all` gate when the PR touches `.github/workflows/make-all.yml`, `elixir/**`, `AGENTS.md`, or `SPEC.md`.
- For docs-only updates, read-only investigation, or Linear triage/cleanup, do not run `make all`.


## Codebase-Specific Conventions

- Runtime config is loaded from `WORKFLOW.md` front matter via `SymphonyElixir.Workflow` and `SymphonyElixir.Config`.
- Keep the implementation aligned with [`../SPEC.md`](../SPEC.md) where practical.
  - The implementation may be a superset of the spec.
  - The implementation must not conflict with the spec.
  - If implementation changes meaningfully alter the intended behavior, update the spec in the same
    change where practical so the spec stays current.
- Prefer adding config access through `SymphonyElixir.Config` instead of ad-hoc env reads.
- Workspace safety is critical:
  - Never run Codex turn cwd in source repo.
  - Workspaces must stay under configured workspace root.
- Orchestrator behavior is stateful and concurrency-sensitive; preserve retry, reconciliation, and cleanup semantics.
- Follow `docs/logging.md` for logging conventions and required issue/session context fields.

## Tests and Validation

Start by checking `git diff`, then choose the lightest validation that proves the change.

- Important local reminder: development uses targeted tests only. `make all` is not a default dev command and is not a reproduction tool.
- Docs-only, read-only investigation, or Linear triage/cleanup: no development-stage test run required.
- Localized code changes: run targeted tests that directly cover the edited behavior.
- Before opening a PR or updating an existing PR, run a closeout gate that includes `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix format --check-formatted`, `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix lint`, and targeted tests for the touched area.
- `make all` is reserved for final confirmation only. Use it only for major fixes, high-risk changes, or after CI has already failed and you have finished local targeted investigation and repair, right before pushing again for final confirmation.
- If CI fails, the order is fixed: read the CI error first, do targeted local checks next, fix the issue, and only after the fix is complete run local `make all` once for final confirmation.
- Local ExUnit concurrency must always be explicitly bounded. All test commands must carry `SYMPHONY_TEST_MAX_CASES`, default to `SYMPHONY_TEST_MAX_CASES=4`, drop to `2` if the machine shows pressure, and drop to `1` if it is still unstable.

Keep test isolation strict:

- Do not let test boot automatically start polling runtime workers or external process chains.
- Tests that touch `Port.open`, `ssh`, `codex app-server`, Docker, or fake workers must start them explicitly and clean them up explicitly with `on_exit` or equivalent.
- Do not treat the repo `WORKFLOW.md` as the default runtime config in tests.
- Heavy tests and `make all` must be monitored for memory growth, swap growth, CPU saturation that does not recover, abnormal subprocess/port/worker growth, and signs of system lag or loss of responsiveness.
- If monitoring shows resource pressure, stop the current heavy test immediately, clean up the scene, drop concurrency from `4` to `2`, then to `1` if needed, and stop with a report if `1` is still unstable.
- After every test run, clean up any leftover workers, fake workers, background servers, open ports, temporary files/directories/logs, and test-injected environment or config overrides.

```bash
# Targeted local validation:
SYMPHONY_TEST_MAX_CASES=4 mix test test/some_targeted_test.exs

# Final confirmation only:
SYMPHONY_TEST_MAX_CASES=4 make all
```

## Required Rules

- Public functions (`def`) in `lib/` must have an adjacent `@spec`.
- `defp` specs are optional.
- `@impl` callback implementations are exempt from local `@spec` requirement.
- Keep changes narrowly scoped; avoid unrelated refactors.
- Follow existing module/style patterns in `lib/symphony_elixir/*`.

Validation command:

```bash
mix specs.check
```

## PR Requirements

- PR body must follow `../.github/pull_request_template.md` exactly.
- GitHub write actions for repo-local workflows should go through `../.codex/skills/github_api.py`; do not require `gh` as a precondition.
- After every successful PR creation or branch-update push, immediately attempt
  to enable auto-merge before reading checks or mergeability.
- Treat `already enabled` as success.
- Treat `clean status` as “direct merge stage reached”, not as a permission
  blocker.
- Manual merge is fallback-only: use it only when auto-merge failed for another
  reason and the latest head SHA required checks are green, and report that
  failure reason in the PR or issue comment stream first.
- Before creating or updating a PR, run the closeout gate first: format check, lint, and targeted tests for the changed area, all with explicit `SYMPHONY_TEST_MAX_CASES`; docs-only diffs may omit targeted tests when no executable coverage applies.
- Validate PR body locally when needed:

```bash
mix pr_body.check --file /path/to/pr_body.md
```

## Docs Update Policy

If behavior/config changes, update docs in the same PR:

- `../README.md` for project concept and goals.
- `README.md` for Elixir implementation and run instructions.
- `WORKFLOW.md` for workflow/config contract changes.

## Document Flow Override

- For repo-local design docs, specs, implementation plans, and similar documentation, treat the user as having already authorized drafting, editing, self-review, and continuation into the next development step.
- Do not stop solely to wait for the user to review or explicitly approve a written doc/spec/plan unless the user directly asks for that gate.
