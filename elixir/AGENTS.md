# Symphony Elixir

This directory contains the Elixir agent orchestration service that polls Linear, creates per-issue workspaces, and runs Codex in app-server mode.

## Environment

- Elixir: `1.19.x` (OTP 28) via `mise`.
- Install deps: `mix setup`.
- Full validation command: `make all` (format check, lint, coverage, dialyzer).
- Do not run `make all` by default.
- First inspect `git diff` and choose a validation level that matches the change scope.
- For ordinary local milestone checks or pre-PR self-checks, prefer `SYMPHONY_TEST_MAX_CASES=2 mix test --cover`.
- Only run `SYMPHONY_TEST_MAX_CASES=2 make all` locally for core code changes, test/build config changes, startup/execution-flow changes, external-process orchestration changes, or when reproducing a remote full-gate failure.
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

- Docs-only, read-only investigation, or Linear triage/cleanup: no test run required.
- Localized code changes: run targeted tests that directly cover the edited behavior.
- Ordinary local milestone checks or pre-PR self-checks: run `SYMPHONY_TEST_MAX_CASES=2 mix test --cover`.
- Core code changes, test/build config changes, startup/execution-flow changes, external-process orchestration changes, or remote gate reproduction: run `SYMPHONY_TEST_MAX_CASES=2 make all`.

Keep test isolation strict:

- Do not let test boot automatically start polling runtime workers or external process chains.
- Tests that touch `Port.open`, `ssh`, `codex app-server`, Docker, or fake workers must start them explicitly and clean them up explicitly with `on_exit` or equivalent.
- Do not treat the repo `WORKFLOW.md` as the default runtime config in tests.

```bash
SYMPHONY_TEST_MAX_CASES=2 mix test --cover

SYMPHONY_TEST_MAX_CASES=2 make all
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
- Validate PR body locally when needed:

```bash
mix pr_body.check --file /path/to/pr_body.md
```

## Docs Update Policy

If behavior/config changes, update docs in the same PR:

- `../README.md` for project concept and goals.
- `README.md` for Elixir implementation and run instructions.
- `WORKFLOW.md` for workflow/config contract changes.
