# Symphony Elixir

This directory contains the Elixir agent orchestration service that polls Linear, creates per-issue workspaces, and runs Codex in app-server mode.

## Environment

- Elixir: `1.19.x` (OTP 28) via `mise`.
- Install deps: `mix setup`.
- Full validation command: `make all` (format check, lint, coverage, dialyzer).
- Do not run `make all` by default.
- First inspect `git diff` and choose a validation level that matches the change scope.
- Do not run full local `mix test --cover`, `make all`, or any other whole-suite validation command unless a human explicitly confirms it.
- For ordinary local milestone checks or pre-PR self-checks, prefer targeted tests first.
- If a wider local run is explicitly approved by a human, keep `SYMPHONY_TEST_MAX_CASES` at `10` or below.
- Only run local `make all` after explicit human confirmation, including for core code changes, test/build config changes, startup/execution-flow changes, external-process orchestration changes, or remote full-gate reproduction.
- Keep local ExUnit concurrency explicitly bounded. Default to `SYMPHONY_TEST_MAX_CASES=4` or lower, and drop to `2` or `1` if the machine is under pressure.
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

- Important local reminder: do not run full local `mix test --cover`, `make all`, or any other whole-suite test command unless a human explicitly confirms it. Start with targeted tests first and let CI carry the full gate.
- Docs-only, read-only investigation, or Linear triage/cleanup: no test run required.
- Localized code changes: run targeted tests that directly cover the edited behavior.
- Ordinary local milestone checks or pre-PR self-checks: stay on targeted tests unless a human explicitly asks for broader coverage; if coverage is approved, keep `SYMPHONY_TEST_MAX_CASES` at `10` or below.
- Core code changes, test/build config changes, startup/execution-flow changes, external-process orchestration changes, or remote gate reproduction: do not run local `make all` without explicit human confirmation, and keep `SYMPHONY_TEST_MAX_CASES` at `10` or below when running wider tests.
- Local ExUnit concurrency must always be explicitly bounded. Default to `SYMPHONY_TEST_MAX_CASES=4` or lower, and drop to `2` or `1` if the machine shows pressure.

Keep test isolation strict:

- Do not let test boot automatically start polling runtime workers or external process chains.
- Tests that touch `Port.open`, `ssh`, `codex app-server`, Docker, or fake workers must start them explicitly and clean them up explicitly with `on_exit` or equivalent.
- Do not treat the repo `WORKFLOW.md` as the default runtime config in tests.

```bash
# Only after explicit human confirmation for a broader local run:
SYMPHONY_TEST_MAX_CASES=4 mix test --cover

# Only after explicit human confirmation:
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
