---
name: push
description:
  Push current branch changes to origin and create or update the corresponding
  pull request; use when asked to push, publish updates, or create pull request.
---

# Push

## Prerequisites

- `git` is installed and authenticated for pushes to this repo.
- `python3` is available to run `.codex/skills/github_api.py`.
- GitHub token access is available through `git credential fill`.

## Goals

- Push current branch changes to `origin` safely.
- Create a PR if none exists for the branch, otherwise update the existing PR.
- Keep branch history clean when remote has moved.
- Select and satisfy the correct `Next Push Gate` before every push attempt.
- Treat ordinary development branches as PR-bound by default when they will later create/update a PR.
- Attempt to enable auto-merge immediately after every successful PR creation or branch update push.
- Use `.codex/skills/github_api.py` as the only normal GitHub write path for PR create/update and related audit writes in this flow.

## Related Skills

- `pull`: use this when push is rejected or sync is not clean (non-fast-forward,
  merge conflict risk, or stale branch).

## Steps

1. Identify current branch and confirm remote state.
2. Determine which branch this push falls into before any `git push`:
   - Use the cumulative diff that the branch / PR head will have after this push, relative to PR base. For a branch with no PR yet, use the intended PR base, normally `origin/main`. Treat ordinary development branches as PR-bound whenever they will later create/update a PR. For an open PR update, or for a planned PR create on the same head, never narrow the decision to only the latest unpushed patch.
   - `local make all`: this push will create a PR or update an open PR, and that cumulative diff hits `.github/workflows/make-all.yml`, `elixir/**`, `AGENTS.md`, or `SPEC.md`.
   - `closeout gate`: this push will create a PR or update an open PR, but that cumulative diff does not hit those full-gate paths.
   - `light validation`: this push will not create a PR and will not update an open PR.
   - If an earlier branch push already happened under `light validation` but the same head is now going to be used to create a PR, stop and rerun the gate that now applies before any PR creation. Do not create the PR until that make-up gate is green.
3. Run the selected `Next Push Gate` and do not push until it is green:
   - `local make all` -> run `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- make all`.
   - `closeout gate` -> run `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix format --check-formatted`, `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix lint`, and targeted tests for the touched area.
   - `light validation` -> run the lightest local validation that matches the diff.
   - If the selected gate fails, stop, fix the issue, rerun the same gate, and only continue once it passes.
4. Push branch to `origin` with upstream tracking if needed, using whatever
   remote URL is already configured.
5. If push is not clean/rejected:
   - If the failure is a non-fast-forward or sync problem, run the `pull`
     skill to merge `origin/main`, resolve conflicts, and rerun the same `Next Push Gate`.
   - Push again; use `--force-with-lease` only when history was rewritten.
   - If the failure is due to auth, permissions, or workflow restrictions on
     the configured remote, stop and surface the exact error instead of
     rewriting remotes or switching protocols as a workaround.

6. Before any PR create/update write, verify no unauthorized out-of-band key GitHub write has already happened for this PR flow:
   - If such a write is discovered from GitHub UI, `gh`, ad-hoc CLI, or another helper without explicit user authorization or a recorded `github_api.py unavailable` blocker, stop normal closeout immediately.
   - Recovery order is fixed: first record the exact out-of-band write fact and reason through `.codex/skills/github_api.py`, then refresh PR state, review delta, and latest head required checks, and finally rerun the applicable `Next Push Gate` before continuing.
7. Resolve the current PR without doing extra GitHub writes ahead of the required auto-merge attempt:
   - If no PR exists yet, first draft `/tmp/pr_body.md` from `.github/pull_request_template.md` and validate it locally, then create the PR with `.codex/skills/github_api.py`; for a first-time PR create, that creation write is the only allowed GitHub write before the immediate auto-merge attempt.
   - If a PR already exists and is open, do not refresh title/body, labels, or other GitHub metadata yet; after an open-PR branch-update push, the first-priority GitHub write must be the auto-merge attempt itself.
   - If branch is tied to a closed/merged PR, create a new branch + PR.
8. Immediately after the successful push and required PR create/no-op PR lookup step, attempt to enable auto-merge for the current PR before reading checks or mergeability and before any other GitHub write:
   - If auto-merge is already enabled, treat that as success.
   - If GitHub reports the PR is already in clean status, do not treat that as a blocker; it means the PR has already moved past the auto-merge window.
   - If any other error occurs, capture the exact failure text, record it through `.codex/skills/github_api.py` in the PR or issue comment stream, and stop normal closeout until that audit trail exists because any later manual merge must cite that failure.
9. Only after the immediate auto-merge attempt has been made, perform any remaining PR metadata writes explicitly using `.github/pull_request_template.md`:
   - Fill every section with concrete content for this change.
   - Replace all placeholder comments (`<!-- ... -->`).
   - Keep bullets/checkboxes where template expects them.
   - If PR already exists, refresh title/body content only after the immediate auto-merge attempt so it reflects the total PR
     scope (all intended work on the branch), not just the newest commits,
     including newly added work, removed work, or changed approach.
   - Do not reuse stale description text from earlier iterations.
10. Validate PR body with `mix pr_body.check` and fix all reported issues:
   - First-time PR create: body validation happens before `ensure-pr`.
   - Existing PR metadata refresh: body validation happens after the immediate auto-merge attempt and before the refresh write.
11. Reply with the PR URL returned by `.codex/skills/github_api.py`.

## Commands

```sh
# Identify branch
branch=$(git branch --show-current)

# Validation gate
# Select the Next Push Gate before any push attempt.
# Always classify against the cumulative diff the branch/PR head will have after
# this push, relative to PR base (normally origin/main). Treat ordinary
# development branches as PR-bound when they will later create/update a PR.
# Do not classify an open PR update or planned PR create from only the newest
# local patch.
# A) PR create/update + full-gate path hit in that cumulative diff -> local make all
# B) PR create/update + no full-gate path hit in that cumulative diff -> closeout gate
# C) not a PR create/update push -> light validation
# If a prior push on the same head used light validation but you now intend to
# create a PR, rerun the now-applicable gate before `ensure-pr`.
# Examples:
# cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- make all
# cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix format --check-formatted
# cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix lint
# cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/path/to_test.exs

# Initial push: respect the current origin remote.
git push -u origin HEAD

# If that failed because the remote moved, use the pull skill. After
# pull-skill resolution and re-validation, retry the normal push:
git push -u origin HEAD

# If the configured remote rejects the push for auth, permissions, or workflow
# restrictions, stop and surface the exact error.

# Only if history was rewritten locally:
git push --force-with-lease origin HEAD

# Resolve the PR number without doing extra writes before the required
# auto-merge attempt. For open PR updates, do not refresh title/body/labels
# before the attempt. For first-time PR create, only create the PR when
# `current-pr` fails with the exact `no matching pull request found` result.
current_pr_output=$(python3 .codex/skills/github_api.py current-pr 2>&1)
current_pr_status=$?
current_pr_output_trimmed=$(printf '%s' "$current_pr_output" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
if [ "$current_pr_status" -eq 0 ]; then
  printf '%s\n' "$current_pr_output" > /tmp/current_pr.json
  pr_number=$(python3 - <<'PY'
import json
from pathlib import Path
payload = json.loads(Path("/tmp/current_pr.json").read_text())
print(payload["number"])
PY
)
elif [ "$current_pr_output_trimmed" = "no matching pull request found" ]; then
  # First-time PR create path:
  # 1) draft /tmp/pr_body.md from .github/pull_request_template.md
  # 2) run `cd elixir && mix pr_body.check --file /tmp/pr_body.md`
  # 3) only then call ensure-pr with that validated body file
  pr_title="<clear PR title written for this change>"
  (cd elixir && mix pr_body.check --file /tmp/pr_body.md)
  python3 .codex/skills/github_api.py ensure-pr \
    --title "$pr_title" \
    --body-file /tmp/pr_body.md > /tmp/pr_info.json
  pr_number=$(python3 - <<'PY'
import json
from pathlib import Path
payload = json.loads(Path("/tmp/pr_info.json").read_text())
print(payload["pull_request"]["number"])
PY
)
else
  printf '%s\n' "$current_pr_output" >&2
  exit "$current_pr_status"
fi

# Attempt auto-merge immediately after push + PR create/no-op PR lookup, before
# reading checks or mergeability and before any other GitHub write.
auto_merge_output=$(python3 .codex/skills/github_api.py enable-auto-merge --number "$pr_number" 2>&1)
auto_merge_status=$?
auto_merge_output_trimmed=$(printf '%s' "$auto_merge_output" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
if [ "$auto_merge_status" -ne 0 ] && { [ "$auto_merge_output_trimmed" = "already enabled" ] || [ "$auto_merge_output_trimmed" = "clean status" ]; }; then
  auto_merge_status=0
fi
if [ "$auto_merge_status" -ne 0 ]; then
  printf '%s\n' "$auto_merge_output" > /tmp/auto_merge_failure.txt
  {
    printf '[codex] auto-merge enable failed for PR #%s\n\n' "$pr_number"
    printf 'Exact failure text:\n'
    printf '```\n'
    cat /tmp/auto_merge_failure.txt
    printf '```\n'
  } > /tmp/auto_merge_failure_comment.md
  python3 .codex/skills/github_api.py issue-comment-create \
    --number "$pr_number" \
    --body-file /tmp/auto_merge_failure_comment.md
  exit "$auto_merge_status"
fi

# If you later discover an unauthorized out-of-band GitHub write for this PR
# flow, stop first and audit it before any further closeout or merge action.
# Run this only when the violation
# was actually detected:
out_of_band_write_detected=0
if [ "$out_of_band_write_detected" = "1" ]; then
  {
    printf '[codex] detected out-of-band GitHub write for PR #%s\n\n' "$pr_number"
    printf -- '- Write path: GitHub UI / gh / ad-hoc CLI / other helper\n'
    printf -- '- Exact action: <create PR | update PR | review reply | audit comment | merge>\n'
    printf -- '- Reason observed: <exact fact and reason>\n'
    printf -- '- Recovery: stopped closeout first, auditing here, then rechecking PR state/review delta/latest head checks, and only then rerunning the applicable Next Push Gate before proceeding.\n'
  } > /tmp/out_of_band_write_comment.md
  python3 .codex/skills/github_api.py issue-comment-create \
    --number "$pr_number" \
    --body-file /tmp/out_of_band_write_comment.md
fi

# Only after the immediate auto-merge attempt, refresh any remaining PR
# metadata such as title/body/labels for an existing PR.
# Example workflow:
# 1) open the template and draft body content for this PR into /tmp/pr_body.md
# 2) for a first-time PR create, body validation already happened before
#    ensure-pr and should not be deferred to this stage
# 3) for an existing PR, run body validation only now, after the auto-merge
#    attempt and before the refresh write, so the branch-update path does not
#    write metadata first
# 4) for branch updates, re-check that title/body still match the cumulative
#    updated branch/PR diff, not only the latest local patch

# Existing-PR metadata refresh validation (run only after the immediate
# auto-merge attempt and before the refresh write):
# (cd elixir && mix pr_body.check --file /tmp/pr_body.md)

# Existing-PR metadata refresh example (run only after the immediate
# auto-merge attempt if title/body need updating):
# python3 .codex/skills/github_api.py ensure-pr \
#   --title "$pr_title" \
#   --body-file /tmp/pr_body.md > /tmp/pr_info.json

# Show PR URL for the reply
python3 - <<'PY'
import json
from pathlib import Path
for path in [Path("/tmp/pr_info.json"), Path("/tmp/current_pr.json")]:
    if path.exists():
        payload = json.loads(path.read_text())
        if "pull_request" in payload:
            print(payload["pull_request"]["url"])
        else:
            print(payload["url"])
        break
PY
```

## Notes

- Do not use `--force`; only use `--force-with-lease` as the last resort.
- Do not collapse the gate decision back into a generic "required validation" check.
  Pick one explicit `Next Push Gate`: `local make all`, `closeout gate`, or
  `light validation`.
- `local make all` is mandatory for PR create/update pushes whose updated
  cumulative branch/PR diff against PR base hits `.github/workflows/make-all.yml`,
  `elixir/**`, `AGENTS.md`, or `SPEC.md`.
- Ordinary development branches do not get to bypass that rule just because the
  PR does not exist yet. If the same head later becomes PR-bound after an
  earlier non-PR push, run the current `Next Push Gate` before creating the PR.
  If the first remote full gate still exposes coverage, dialyzer, or similar
  failures, treat that as a missed or non-compliant local gate unless you have
  evidence of environment drift.
- Do not defer the auto-merge attempt until after reading checks. The default
  order is push first, auto-merge attempt second, signal inspection third.
- For an open PR branch-update push, the first-priority GitHub write after the
  successful `git push` must be the auto-merge attempt itself. Do not refresh
  PR title/body, attach labels, or perform other GitHub writes first.
- For a first-time PR create, the create-PR write must happen first because the
  PR does not exist yet; immediately after that creation write, the first-priority
  next GitHub write must be the auto-merge attempt.
- Do not treat a fuzzy substring match as a successful auto-merge outcome.
  Only a zero exit status, or an exact trimmed output of `already enabled` or
  `clean status`, counts as success in the example flow.
- Use `.codex/skills/github_api.py` as the default and only normal GitHub write
  path in this flow. Do not switch to GitHub UI, `gh`, ad-hoc CLI, or another
  helper unless the user explicitly authorizes it or `github_api.py` is
  unavailable and that blocker has already been recorded.
- If you discover a key GitHub write already happened through an out-of-band
  path without that exception, treat it as a workflow violation: stop closeout,
  record the exact fact and reason via `.codex/skills/github_api.py`, then
  re-check PR state, review delta, and latest head required checks, rerun the
  applicable `Next Push Gate`, and only then resume.
- Distinguish sync problems from remote auth/permission problems:
  - Use the `pull` skill for non-fast-forward or stale-branch issues.
  - Surface auth, permissions, or workflow restrictions directly instead of
    changing remotes or protocols.
