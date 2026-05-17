---
name: land
description:
  Land a PR by monitoring conflicts, resolving them, waiting for checks, and
  squash-merging when green; use when asked to land, merge, or shepherd a PR to
  completion.
---

# Land

## Goals

- Ensure the PR is conflict-free with main.
- Keep CI green and fix failures when they occur.
- Squash-merge the PR once checks pass.
- Do not yield to the user until the PR is merged; keep the watcher loop running
  unless blocked.
- No need to delete remote branches after merge; the repo auto-deletes head
  branches.
- Treat manual merge as a fallback path. The default path should already have
  attempted auto-merge immediately after the latest successful push.
- Reuse the same explicit `Next Push Gate` logic as the `push` skill for every
  repair-loop branch update.
- Keep `.codex/skills/github_api.py` as the only normal GitHub write path for
  review replies, audit comments, and merge in this flow.
- If any key GitHub write is found to have happened through GitHub UI, `gh`,
  ad-hoc CLI, or another helper without explicit user authorization or a
  recorded `github_api.py unavailable` blocker, stop merge/closeout until that
  out-of-band write has been audited and the PR state has been re-checked.

## Preconditions

- `python3` is available to run `.codex/skills/github_api.py` and `.codex/skills/land/land_watch.py`.
- GitHub token access is available through `git credential fill`.
- You are on the PR branch with a clean working tree.

## Steps

1. Locate the PR for the current branch.
2. Confirm which `Next Push Gate` applies to the next branch update:
   - Base the decision on the cumulative diff that the updated branch / PR head
     will have against PR base after the next push. Do not classify an open PR
     update from only the latest local patch.
   - `local make all` when the next push will update an open PR and that
     cumulative diff hits `.github/workflows/make-all.yml`, `elixir/**`,
     `AGENTS.md`, or `SPEC.md`
   - `closeout gate` when the next push will update an open PR without hitting
     those full-gate paths in that cumulative diff
   - `light validation` only when no PR create/update push will happen
3. If the working tree has uncommitted changes, commit with the `commit` skill
   and push with the `push` skill before proceeding.
4. Check mergeability and conflicts against main.
5. If conflicts exist, use the `pull` skill to fetch/merge `origin/main` and
   resolve conflicts, then use the `push` skill to publish the updated branch.
6. Ensure Codex review comments (if present) are acknowledged and any required
   fixes are handled before merging.
7. Watch checks until complete.
8. If checks fail, pull logs, fix the issue, commit with the `commit` skill,
   rerun the exact `Next Push Gate` required for the next PR update push, then
   push with the `push` skill and re-run checks.
9. If you discover any out-of-band key GitHub write during the landing flow, stop normal merge execution immediately.
   - Recovery order is fixed: record the exact fact and reason through `.codex/skills/github_api.py`, then refresh PR state, review delta, latest head required checks, and finally rerun the applicable gate before resuming.
10. When all checks are green and review feedback is addressed, prefer waiting
   for the existing auto-merge path to complete.
   - Manual squash-merge is allowed only as an explicit fallback after one of
     these conditions is true for the latest head:
     - the latest auto-merge attempt returned exact `clean status`, and latest
       head SHA required checks are green
     - the latest auto-merge attempt failed for another reason, that exact
       failure has already been audited in the PR or issue comment stream, and
       latest head SHA required checks are green
   - Only then may you squash-merge using `.codex/skills/github_api.py` plus
     the PR title/body for the merge subject/body. Do not use GitHub UI, `gh`,
     ad-hoc CLI, or other helpers for normal merge execution.
11. **Context guard:** Before implementing review feedback, confirm it does not
    conflict with the user’s stated intent or task context. If it conflicts,
    respond inline with a justification and ask the user before changing code.
12. **Pushback template:** When disagreeing, reply inline with: acknowledge +
    rationale + offer alternative.
13. **Ambiguity gate:** When ambiguity blocks progress, use the clarification
    flow (assign PR to current GH user, mention them, wait for response). Do not
    implement until ambiguity is resolved.
    - If you are confident you know better than the reviewer, you may proceed
      without asking the user, but reply inline with your rationale.
14. **Per-comment mode:** For each review comment, choose one of: accept,
    clarify, or push back. Reply inline (or in the issue thread for Codex
    reviews) stating the mode before changing code.
15. **Reply before change:** Always respond with intended action before pushing
    code changes (inline for review comments, issue thread for Codex reviews).

## Commands

```
# Ensure branch and PR context
branch=$(git branch --show-current)
python3 .codex/skills/github_api.py current-pr > /tmp/current_pr.json
pr_number=$(python3 - <<'PY'
import json
from pathlib import Path
payload = json.loads(Path("/tmp/current_pr.json").read_text())
print(payload["number"])
PY
)
pr_title=$(python3 - <<'PY'
import json
from pathlib import Path
payload = json.loads(Path("/tmp/current_pr.json").read_text())
print(payload["title"])
PY
)
pr_body=$(python3 - <<'PY'
import json
from pathlib import Path
payload = json.loads(Path("/tmp/current_pr.json").read_text())
print(payload["body"])
PY
)

# Check mergeability and conflicts
mergeable=$(python3 - <<'PY'
import json
from pathlib import Path
payload = json.loads(Path("/tmp/current_pr.json").read_text())
print(payload["mergeable"])
PY
)

if [ "$mergeable" = "CONFLICTING" ]; then
  # Run the `pull` skill to handle fetch + merge + conflict resolution.
  # Then run the `push` skill to publish the updated branch.
fi

# Preferred: use the Async Watch Helper below. It polls review comments, reviews,
# check-runs, and head updates through `.codex/skills/github_api.py`.
python3 .codex/skills/land/land_watch.py

# Squash-merge fallback. This is not the default path.
# Run it only after the latest auto-merge attempt either:
# 1) returned exact `clean status`, or
# 2) failed for another reason whose exact failure has already been audited in
#    the PR/issue comment stream;
# and in both cases only when latest head SHA required checks are green.
python3 .codex/skills/github_api.py merge-pr \
  --number "$pr_number" \
  --method squash \
  --subject "$pr_title" \
  --body "$pr_body"
```

## Async Watch Helper

Preferred: use the asyncio watcher to monitor review comments, CI, and head
updates in parallel:

```
python3 .codex/skills/land/land_watch.py
```

Exit codes:

- 2: Review comments detected (address feedback)
- 3: CI checks failed
- 4: PR head updated (autofix commit detected)

## Failure Handling

- If checks fail, pull failing check names from `.codex/skills/land/land_watch.py`,
  inspect the corresponding GitHub run details or logs through your available
  GitHub read path, then fix locally, commit with the `commit` skill, push with
  the `push` skill, and re-run the watch.
- Do not relax the gate inside `land`. If the repaired cumulative branch/PR
  diff against PR base still updates an open PR on `.github/workflows/make-all.yml`,
  `elixir/**`, `AGENTS.md`, or `SPEC.md`, rerun local `make all` before the next
  push. `land` does not get a looser branch than `push`.
- The same PR-bound rule from `push` still applies here: a branch update that
  will continue the current PR must be classified from the updated cumulative
  branch/PR diff, not from only the latest repair patch.
- Use judgment to identify flaky failures. If a failure is a flake (e.g., a
  timeout on only one platform), you may proceed without fixing it.
- If CI pushes an auto-fix commit (authored by GitHub Actions), it does not
  trigger a fresh CI run. Detect the updated PR head, pull locally, merge
  `origin/main` if needed, add a real author commit, and force-push to retrigger
  CI, then restart the checks loop.
- If all jobs fail with corrupted pnpm lockfile errors on the merge commit, the
  remediation is to fetch latest `origin/main`, merge, force-push, and rerun CI.
- If mergeability is `UNKNOWN`, wait and re-check.
- Do not merge while review comments (human or Codex review) are outstanding.
- Codex review jobs retry on failure and are non-blocking; use the presence of
  `## Codex Review — <persona>` issue comments (not job status) as the signal
  that review feedback is available.
- If auto-merge is already active, prefer waiting for the auto-merge path over
  forcing a manual merge.
- Manual merge is never the default interpretation of “checks are green”.
  Checks being green only means the fallback may be considered; it does not by
  itself authorize merge.
- If auto-merge was not activated because the latest attempt failed for another
  reason, manual merge is allowed only after that exact failure reason has been
  reported in the PR or issue comment stream and the latest head SHA required
  checks are green.
- If the latest auto-merge attempt returned exact `clean status`, treat that as
  “auto-merge no longer necessary”, not as a permission blocker; manual merge
  may then be used as the documented fallback once latest head SHA required
  checks are green.
- If the first remote full gate on the latest repaired head still exposes
  coverage, dialyzer, or similar full-gate failures, treat that as a missed or
  non-compliant local `make all` gate unless you have concrete evidence of
  environment drift or instability.
- If the remote PR branch advanced due to your own prior force-push or merge,
  avoid redundant merges; re-run the formatter locally if needed and
  `git push --force-with-lease`.

## Review Handling

- Codex reviews now arrive as issue comments posted by GitHub Actions. They
  start with `## Codex Review — <persona>` and include the reviewer’s
  methodology + guardrails used. Treat these as feedback that must be
  acknowledged before merge.
- Human review comments are blocking and must be addressed (responded to and
  resolved) before requesting a new review or merging.
- If multiple reviewers comment in the same thread, respond to each comment
  (batching is fine) before closing the thread.
- Fetch review comments via `.codex/skills/github_api.py` and reply with a
  prefixed comment.
- Inline review replies and PR/issue audit comments must use
  `.codex/skills/github_api.py`. Do not use GitHub UI, `gh`, ad-hoc CLI, or
  other helpers for those writes unless the user explicitly authorizes it or
  `github_api.py` is unavailable and that blocker is already recorded.
- If such an out-of-band write is discovered anyway, stop closeout/merge
  first, publish an audit note describing the exact fact and reason through
  `.codex/skills/github_api.py`, then refresh PR state, review delta, and
  latest head required checks, rerun the applicable gate, and only then
  resume.
- Use review comment endpoints (not issue comments) to find inline feedback:
  - List PR review comments:
    ```
    python3 .codex/skills/github_api.py review-comments --number <pr_number>
    ```
  - PR issue comments (top-level discussion):
    ```
    python3 .codex/skills/github_api.py issue-comments --number <pr_number>
    ```
  - Reply to a specific review comment:
    ```
    python3 .codex/skills/github_api.py review-comment-reply \
      --number <pr_number> \
      --comment-id <comment_id> \
      --body '[codex] <response>'
    ```
- `in_reply_to` must be the numeric review comment id (e.g., `2710521800`), not
  the GraphQL node id (e.g., `PRRC_...`), and the endpoint must include the PR
  number (`/pulls/<pr_number>/comments`).
- If GraphQL review reply mutation is forbidden, use REST.
- A 404 on reply typically means the wrong endpoint (missing PR number) or
  insufficient scope; verify by listing comments first.
- All GitHub comments generated by this agent must be prefixed with `[codex]`.
- For Codex review issue comments, reply in the issue thread (not a review
  thread) with `[codex]` and state whether you will address the feedback now or
  defer it (include rationale).
- If feedback requires changes:
  - For inline review comments (human), reply with intended fixes
    (`[codex] ...`) **as an inline reply to the original review comment** using
    the review comment endpoint and `in_reply_to` (do not use issue comments for
    this).
  - Implement fixes, commit, push.
  - Reply with the fix details and commit sha (`[codex] ...`) in the same place
    you acknowledged the feedback (issue comment for Codex reviews, inline reply
    for review comments).
  - The land watcher treats Codex review issue comments as unresolved until a
    newer `[codex]` issue comment is posted acknowledging the findings.
- Only request a new Codex review when you need a rerun (e.g., after new
  commits). Do not request one without changes since the last review.
  - Before requesting a new Codex review, re-run the land watcher and ensure
    there are zero outstanding review comments (all have `[codex]` inline
    replies).
  - After pushing new commits, the Codex review workflow will rerun on PR
    synchronization (or you can re-run the workflow manually). Post a concise
    root-level summary comment so reviewers have the latest delta:
    ```
    [codex] Changes since last review:
    - <short bullets of deltas>
    Commits: <sha>, <sha>
    Tests: <commands run>
    ```
  - Only request a new review if there is at least one new commit since the
    previous request.
  - Wait for the next Codex review comment before merging.

## Scope + PR Metadata

- The PR title and description should reflect the full scope of the change, not
  just the most recent fix.
- If review feedback expands scope, decide whether to include it now or defer
  it. You can accept, defer, or decline feedback. If deferring or declining,
  call it out in the root-level `[codex]` update with a brief reason (e.g.,
  out-of-scope, conflicts with intent, unnecessary).
- Correctness issues raised in review comments should be addressed. If you plan
  to defer or decline a correctness concern, validate first and explain why the
  concern does not apply.
- Classify each review comment as one of: correctness, design, style,
  clarification, scope.
- For correctness feedback, provide concrete validation (test, log, or
  reasoning) before closing it.
- When accepting feedback, include a one-line rationale in the root-level
  update.
- When declining feedback, offer a brief alternative or follow-up trigger.
- Prefer a single consolidated "review addressed" root-level comment after a
  batch of fixes instead of many small updates.
- For doc feedback, confirm the doc change matches behavior (no doc-only edits
  to appease review).
