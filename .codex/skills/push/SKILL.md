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
- Attempt to enable auto-merge immediately after every successful PR creation or branch update push.

## Related Skills

- `pull`: use this when push is rejected or sync is not clean (non-fast-forward,
  merge conflict risk, or stale branch).

## Steps

1. Identify current branch and confirm remote state.
2. Run the lightest local validation that matches the diff, following `AGENTS.md`.
3. Push branch to `origin` with upstream tracking if needed, using whatever
   remote URL is already configured.
4. If push is not clean/rejected:
   - If the failure is a non-fast-forward or sync problem, run the `pull`
     skill to merge `origin/main`, resolve conflicts, and rerun validation.
   - Push again; use `--force-with-lease` only when history was rewritten.
   - If the failure is due to auth, permissions, or workflow restrictions on
     the configured remote, stop and surface the exact error instead of
     rewriting remotes or switching protocols as a workaround.

5. Ensure a PR exists for the branch:
   - If no PR exists, create one.
   - If a PR exists and is open, update it.
   - If branch is tied to a closed/merged PR, create a new branch + PR.
   - Write a proper PR title that clearly describes the change outcome
   - For branch updates, explicitly reconsider whether current PR title still
     matches the latest scope; update it if it no longer does.
6. Immediately after the successful push and PR create/update step, attempt to enable auto-merge for the current PR before reading checks or mergeability:
   - If auto-merge is already enabled, treat that as success.
   - If GitHub reports the PR is already in clean status, do not treat that as a blocker; it means the PR has already moved past the auto-merge window.
   - If any other error occurs, capture the exact failure text and post it to the PR or issue comment stream because any later manual merge must cite that failure.
7. Write/update PR body explicitly using `.github/pull_request_template.md`:
   - Fill every section with concrete content for this change.
   - Replace all placeholder comments (`<!-- ... -->`).
   - Keep bullets/checkboxes where template expects them.
   - If PR already exists, refresh body content so it reflects the total PR
     scope (all intended work on the branch), not just the newest commits,
     including newly added work, removed work, or changed approach.
   - Do not reuse stale description text from earlier iterations.
8. Validate PR body with `mix pr_body.check` and fix all reported issues.
9. Reply with the PR URL returned by `.codex/skills/github_api.py`.

## Commands

```sh
# Identify branch
branch=$(git branch --show-current)

# Minimal validation gate
# Choose the lightest validation that matches the change scope per AGENTS.md.
# Examples:
# cd elixir && mise exec -- mix format --check-formatted path/to/file.ex
# cd elixir && SYMPHONY_TEST_MAX_CASES=2 mise exec -- mix test test/path/to_test.exs

# Initial push: respect the current origin remote.
git push -u origin HEAD

# If that failed because the remote moved, use the pull skill. After
# pull-skill resolution and re-validation, retry the normal push:
git push -u origin HEAD

# If the configured remote rejects the push for auth, permissions, or workflow
# restrictions, stop and surface the exact error.

# Only if history was rewritten locally:
git push --force-with-lease origin HEAD

# Write a clear, human-friendly title that summarizes the shipped change.
pr_title="<clear PR title written for this change>"
python3 .codex/skills/github_api.py ensure-pr \
  --title "$pr_title" \
  --body-file /tmp/pr_body.md > /tmp/pr_info.json

# Attempt auto-merge immediately after push + PR create/update, before reading
# checks or mergeability.
pr_number=$(python3 - <<'PY'
import json
from pathlib import Path
payload = json.loads(Path("/tmp/pr_info.json").read_text())
print(payload["pull_request"]["number"])
PY
)
python3 .codex/skills/github_api.py enable-auto-merge --number "$pr_number" || true

# Write/edit PR body to match .github/pull_request_template.md before validation.
# Example workflow:
# 1) open the template and draft body content for this PR into /tmp/pr_body.md
# 2) ensure-pr will create or refresh title/body using that file
# 3) for branch updates, re-check that title/body still match current diff

(cd elixir && mix pr_body.check --file /tmp/pr_body.md)

# Show PR URL for the reply
python3 - <<'PY'
import json
from pathlib import Path
payload = json.loads(Path("/tmp/pr_info.json").read_text())
print(payload["pull_request"]["url"])
PY
```

## Notes

- Do not use `--force`; only use `--force-with-lease` as the last resort.
- Do not defer the auto-merge attempt until after reading checks. The default
  order is push first, auto-merge attempt second, signal inspection third.
- Use `.codex/skills/github_api.py` as the standard GitHub write path. `gh` is
  not part of the required workflow contract in this repo.
- Distinguish sync problems from remote auth/permission problems:
  - Use the `pull` skill for non-fast-forward or stale-branch issues.
  - Surface auth, permissions, or workflow restrictions directly instead of
    changing remotes or protocols.
