# Symphony Elixir

This directory contains the Elixir agent orchestration service that polls Linear, creates per-issue workspaces, and runs Codex in app-server mode.

## Environment

- Elixir: `1.19.x` (OTP 28) via `mise`.
- Install deps: `mix setup`.
- Full validation command: `make all` (format check, lint, coverage, dialyzer), used as the local hard gate before PR create/update pushes that hit the full-gate paths, and as final confirmation after CI-guided repair.
- Do not run `make all` by default.
- First inspect `git diff` and choose the lightest validation that proves the change.
- Development uses targeted tests only.
- Before any PR create/update push, choose the `Next Push Gate` first using the cumulative branch/PR diff after that push lands: use `local make all` when the updated current branch / PR head relative to PR base (default `origin/main`) hits `.github/workflows/make-all.yml`, `elixir/**`, `AGENTS.md`, or `SPEC.md`; otherwise use `closeout gate`. Ordinary development branches are PR-bound by default when they are going to create/update a PR, so do not downgrade merely because the PR does not exist yet. Open PR updates must use the whole accumulated branch diff, not only the latest unpushed patch. Docs-only updates still follow the selected gate, and may omit targeted tests only when no executable coverage applies.
- If a branch push was previously treated as a non-PR push but the same head is later going to be used for PR creation, rerun the now-applicable `Next Push Gate` before creating the PR. Do not treat that later PR creation as a free light-validation follow-up.
- Keep local ExUnit concurrency explicitly bounded. All test commands must include `SYMPHONY_TEST_MAX_CASES=4`, and reduce to `2` or `1` if the machine is under pressure.
- GitHub Actions remains the authoritative full `make all` gate when the PR touches `.github/workflows/make-all.yml`, `elixir/**`, `AGENTS.md`, or `SPEC.md`.
- For docs-only updates, read-only investigation, or Linear triage/cleanup, do not run `make all` by default during development; if a PR create/update push hits those full-gate paths, still follow the selected `Next Push Gate`, including local `make all`.


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
- Docs-only, read-only investigation, or Linear triage/cleanup: no development-stage test run required; before a PR create/update push, still run the selected `Next Push Gate`.
- Localized code changes: run targeted tests that directly cover the edited behavior.
- Before every push, classify the push first:
  - First decide against the cumulative diff that the branch / PR head will have after the push, relative to PR base (default `origin/main` for a branch without PR). Ordinary development branches remain PR-bound when they are going to create/update a PR, and you must not classify an open PR update or planned PR create from only the latest local patch.
  - If it will create a PR or update an open PR and that cumulative diff hits `.github/workflows/make-all.yml`, `elixir/**`, `AGENTS.md`, or `SPEC.md`, the `Next Push Gate` is `local make all`, so run `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- make all` before pushing.
  - If it will create a PR or update an open PR but that cumulative diff does not hit those full-gate paths, the `Next Push Gate` is `closeout gate`, so run `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix format --check-formatted`, `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix lint`, and targeted tests for the touched area before pushing.
  - If it is not a PR create/update push, run the lightest validation that matches the change scope.
  - If an earlier branch push was treated as a non-PR push but the same head is now going to be used for PR creation, rerun the gate that now applies and do not create the PR until it passes.
- `make all` is not a universal pre-push command. It is reserved for the PR create/update full-gate branch above and for CI-guided repair loops when the next push still updates an open PR on those paths.
- If CI fails, the order is fixed: read the CI error first, do targeted local checks next, fix the issue, and only after the fix is complete run the gate required for the next push; if that next push still updates an open PR whose updated cumulative diff against PR base hits a full-gate path, rerun local `make all` before pushing.
- GitHub Actions remains the authoritative remote full `make all` gate when the PR touches `.github/workflows/make-all.yml`, `elixir/**`, `AGENTS.md`, or `SPEC.md`, but it now serves as the final reviewer rather than the first normal place to discover coverage or dialyzer problems. If the first remote full gate still exposes those problems, treat that as local gate non-execution, non-compliant execution, or environment drift that needs escalation.
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
- PR create/update, review replies, PR/issue comment audit writes, and merge writes must use `../.codex/skills/github_api.py` as the default and only normal path.
- GitHub UI, `gh`, ad-hoc CLI, or other helpers are not part of the normal write workflow for those actions. Only explicit user authorization or a recorded `github_api.py unavailable` blocker allows an exception.
- If any of those key writes are discovered to have happened through GitHub UI, `gh`, ad-hoc CLI, or another helper without that authorization/blocker exception, treat it as a workflow violation: stop closeout/merge, record the exact out-of-band write fact and reason through `../.codex/skills/github_api.py`, then re-confirm PR state, review delta, latest head required checks, and rerun the applicable gate before proceeding.
- The recovery order on that violation path is fixed: stop further closeout/merge work first, publish the audit note through `../.codex/skills/github_api.py`, then re-confirm PR state, review delta, and latest head required checks, and only then rerun the applicable gate if another push or merge decision is still pending.
- After every successful PR creation or branch-update push, immediately attempt
  to enable auto-merge before reading checks or mergeability.
- Treat `already enabled` as success.
- Treat `clean status` as “direct merge stage reached”, not as a permission
  blocker.
- Manual merge is fallback-only:
  - if the latest auto-merge attempt returned `clean status`, documented manual
    merge fallback is allowed once the latest head SHA required checks are green
  - if auto-merge failed for another reason, manual merge fallback is allowed
    only after that exact failure has been reported in the PR or issue comment
    stream and the latest head SHA required checks are green
- Code additions, deletions, refactors, or behavior changes must pass a post-implementation zero-context reviewer before any PR create/update push.
- Before creating or updating a PR, select the gate explicitly:
  - cumulative diff of the updated branch/PR head against PR base hits a full-gate path (`.github/workflows/make-all.yml`, `elixir/**`, `AGENTS.md`, `SPEC.md`) -> run local `make all` first, with explicit `SYMPHONY_TEST_MAX_CASES`
  - otherwise -> run the closeout gate first: format check, lint, and targeted tests for the changed area, all with explicit `SYMPHONY_TEST_MAX_CASES`
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
