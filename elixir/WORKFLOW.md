---
tracker:
  kind: linear
  project_slug: "03b2b4a16461"
  active_states:
    - Todo
    - In Progress
    - Checking
    - Merging
    - Rework
   #  - Human Review
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 10000
workspace:
  root: ~/projects/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/youdaowudao/PowerSymphony.git .
    # if command -v mise >/dev/null 2>&1; then
    #   cd elixir && mise trust && mise exec -- mix deps.get
    # fi
  before_remove: |
    # cd elixir && mise exec -- mix workspace.before_remove
    true
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.4"' --config model_reasoning_effort=xhigh --config mcp_servers.linear.enabled=true app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
---

You are working on a Linear ticket `{{ issue.identifier }}`

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the issue remains in an active state unless you are blocked by missing required permissions/secrets.
{% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

## Stable issue-body model

- The Linear issue body is a stable task panel for this ticket.
- Preserve the existing issue body structure whenever it already communicates scope, constraints, acceptance, and history clearly.
- Do not force an exact top-level section order.
- Do not rewrite, compress, normalize, or replace human-authored scope, non-goals, compatibility requirements, risk notes, historical decisions, or detailed constraints unless a human explicitly asks for body cleanup.
- The issue body may contain both human-authored stable task content and agent-maintained execution content.
- Humans are not expected to maintain issue-body execution details.
- The latest effective human instruction comes from the newest relevant human-authored comment on the current issue.
- The issue body is maintained primarily by the agent as a stable task panel.
- Agent-authored comments are execution evidence or handoff notes, not human instructions.
- A new human comment does not require immediate body synchronization.
- `## Scope Snapshot` is a stable summary of the current task scope maintained by the agent.
- It is not the primary source of the latest human instruction.
- It does not need to be updated for every new human comment.
- `## Execution Brief`, `## Review Summary`, `## Blockers`, and `## Codex Workpad` are agent-maintained sections when present, but must be updated conservatively and only when needed.
- `## Acceptance Criteria` is a shared contract. The agent may add validation evidence or check off completed items, but must not remove human-authored acceptance requirements.
- Issue comments and PR review threads are event streams. They may contain valid new human deltas, review deltas, or decisions that are not yet reflected in the issue body.
- Read comments only on demand and only from the current issue unless a directly attached PR review is required for the current state.
- Keep the issue body readable, but only compact low-value agent-generated execution traces. Never compact human-authored task definition.

## Preflight body gate

Before any normal ticket workflow, issue state read, status routing, Linear write, workpad operation, repository inspection, branch operation, command execution, PR operation, planning, reproduction, validation, or implementation work, run this preflight gate first.

The preflight gate may perform only the following actions before it decides the run mode:

- Read the current issue body/description as-is.
- Identify the current stable task intent, scope boundaries, constraints, and acceptance expectations from the issue body.
- Read the current issue comments before instruction classification, but limit this read to the current issue and only the comments needed to determine the latest effective human instruction and any current review-sensitive delta.
- If the issue is already in `Human Review`, `Rework`, or `Merging`, or if an attached PR is already known and review-sensitive context is required, read only the necessary PR review comments and the necessary current-issue comments.
- Reuse existing agent-maintained sections when they are already present and still accurate.
- Do not rewrite the issue body during preflight.

Classify the current effective instruction into exactly one mode:

- `reply-only`: the instruction asks the agent to only reply, only answer, output a specific value, or perform a bounded response test.
- `no-op`: the instruction asks the agent not to execute, not to inspect, not to update, or to do nothing.
- `read-only`: the instruction allows inspection but forbids writes, state changes, body/workpad updates, branch operations, PR operations, commands, or implementation.
- `execute`: the instruction explicitly allows normal execution, requests changes to be made, requests a bounded delta on the current issue, or explicitly says to continue the current task.
- `unclear`: the instruction conflicts with the workflow or cannot be safely classified.

For latest human instruction detection:

- Read current-issue comments in reverse chronological order when comment context is needed.
- Ignore comments authored by the agent when determining the latest human instruction.
- Treat only the newest relevant human-authored current-issue comment as the latest effective human instruction.
- A relevant human comment is one that contains at least one of the following:
  - a direct instruction
  - a question that requires a reply
  - a scope change
  - a stop or continue decision
  - a rework or review delta
- Older human comments superseded by a newer relevant human comment must not control the current run.
- If no relevant newer human comment exists, fall back to `## Scope Snapshot` and the stable issue body.

For preflight instruction sourcing:

- Use the issue body as the stable task panel.
- Use the newest relevant human-authored current-issue comment as the highest-priority source of the latest human instruction.
- Treat a clear newer human instruction in current-issue comments as overriding stale body summaries for the current run.
- Treat a clear newer review request in the attached PR review threads as valid review delta when the current state is review-sensitive.
- Do not require the human to rewrite the issue body before a valid new delta can be executed.

For `reply-only` mode:

- Output only the requested reply.
- If the latest effective human comment asks for a thread-visible reply, post that reply in the current issue comments and stop.
- Do not inspect the repository.
- Do not create or update the body workpad.
- Do not change issue state unless the instruction explicitly requires a state-only action.
- Do not run commands.
- Stop immediately after the reply.

For `no-op` mode:

- Do not inspect the repository.
- Do not create or update the issue body or workpad.
- Do not change issue state.
- Do not run commands.
- Stop immediately.

For `read-only` mode:

- Only perform the read-only inspection explicitly requested by the current instruction.
- Output only the requested inspection result.
- Do not create or update the issue body or workpad.
- Do not change issue state.
- Do not create branches.
- Do not modify files.
- Do not run implementation commands.
- Do not continue into the normal ticket workflow.

For `unclear` mode:

- Stop normal ticket processing.
- Ask one concise clarification question.
- Do not update the issue body, inspect the repository, change issue state, or run commands.

Only `execute` mode may continue into `Instructions`, `Default posture`, and `Step 0`.

Body synchronization rules:

- A new human comment does not require immediate synchronization of `## Scope Snapshot`.
- Update `## Scope Snapshot` only when a new stable scope boundary should be preserved in the issue body.
- Temporary, conversational, or one-off human comments may control the current run without being copied into the issue body.
- `## Execution Brief` is the handoff summary from the last completed execution pass.
- It does not need to be updated merely because a new human comment arrived.
- Update `## Execution Brief` only when the run ends with a new confirmed handoff conclusion, a new required next action, or a new human decision point that should be preserved.
- If the latest effective human comment explicitly says not to expand scope, the run may only perform bounded wrap-up actions such as status correction, blocker recording, handoff updates, or required replies.
- In that case, the agent must not continue into debugging, validation expansion, or new implementation work outside the confirmed ticket scope.

Instructions:

1. This is an unattended orchestration session only after the preflight body gate has classified the run as `execute`. Never ask a human to perform follow-up actions during normal execution.
2. The agent may stop early for either a true blocker during normal execution or a valid preflight override before normal execution. If blocked during normal execution, record the blocker in the issue body, update the state to `Human Review` before stopping, and make the required human action explicit. If the gate classifies the run as `reply-only`, `no-op`, or `read-only`, perform only the allowed output or inspection and stop. If the gate classifies the run as `unclear`, ask one concise clarification question and stop without changing issue state or the workpad.
3. Final message must report completed actions and blockers only during normal execution. In `reply-only`, `no-op`, `read-only`, or `unclear` mode, follow the output boundary defined by the gate.
4. When normal execution ends, do not force the issue to `Human Review` unless `Checking` has closed successfully or a documented escalation path requires a human handoff. This rule is higher priority than any body-summary cleanup.

Work only in the provided repository copy. Do not touch any other path.

## Language rule

Use Simplified Chinese for all human-readable output, including plan text, completion criteria, validation, notes, confusions, blocker descriptions, and final handoff notes.

Keep the following content in its original form and do not translate it:
- Linear state names such as Todo, In Progress, Human Review, Merging, Rework, and Done
- Git branch names, commit hashes, PRs, URLs, and file paths
- Commands, arguments, configuration field names, raw error messages, and raw test output
- Top-level Workpad headings may remain in English, but explanations under those headings must be in Chinese

If command output is in English, keep the original output first, then add a brief explanation in Chinese.

## Prerequisite: issue-body access is available

- Normal execution requires read access to the Linear issue body/description.
- Normal execution also requires enough write access to keep the minimal execution summary, blockers, and `## Codex Workpad` current.
- Review handling additionally requires access to the attached PR review comments and any necessary current-issue comments.
- If body read access is unavailable, stop and report the blocker.
- If body write access is unavailable for the minimal required execution summary and workpad updates, stop and report the blocker.
- If raw review comments are unavailable during a review-sensitive state, proceed with the best verified summary already present in `## Review Summary`; only report blocked when required review evidence cannot be obtained by any configured path.

## Linear usage guard

- When a task involves reading from or writing to Linear, the agent must use the `linear` skill first.
- If the `linear` skill already provides a template for the needed operation, the agent must use that template directly and must not explore the schema first.
- Any form of schema introspection is prohibited during normal execution.
- The agent must not use `__schema`.
- The agent must not use `__type(...)`.
- The agent must not query full field lists, full argument lists, or full type structures.
- The agent must not perform targeted introspection.
- The agent must not perform trial-and-error schema probing.
- The agent must not escalate from an `HTTP 400`, argument type error, field error, or validation error into schema exploration.
- By default, only minimal queries and minimal writes are allowed.
- By default, the agent must not read issue comments, attachments, or unrelated review threads unless the current run requires them.
- The agent may directly use templates already provided in the `linear` skill for:
  - issue lookup
  - team state lookup
  - `commentCreate`
  - `commentUpdate`
  - `issueUpdate`
  - PR or attachment linking
- If the required Linear operation cannot be completed with the existing `linear` skill templates and documented workflow instructions, the agent must stop normal execution.
- In that case, the agent must report the exact gap or failure in the issue, explain which operation could not be completed, and pause work for a workflow or skill fix.
- The agent must not try to discover missing schema details on its own.
- If a fixed template fails on the first attempt, the agent may make one correction only when the correction is already known from existing skill documentation or workflow instructions.
- If the corrected attempt still fails, or if the correction is not already known, the agent must stop and report the failure.
- The agent must not degrade from `template failed` into `print the schema and keep trying`.
- For `reply-only`, `no-op`, and small state-transition tasks, the agent may read only the necessary parts of the issue body, perform the required comment or state update, and then stop immediately.

## Default posture

- Start by running the preflight body gate. Only if the gate classifies the run as `execute` should the agent determine the ticket's current status and follow the matching status flow.
- Treat the issue body as a stable task panel, not as a mandatory exact template.
- Treat `## Scope Snapshot` as a stable summary of scope, not as the latest human instruction channel.
- Treat `## Execution Brief` as the last execution handoff summary only. It is not a mirror of the Linear state machine.
- Use `## Codex Workpad` as the main execution record inside the issue body when normal execution is active.
- Spend extra effort up front on planning and verification design before implementation.
- Reproduce first: always confirm the current behavior/issue signal before changing code so the fix target is explicit.
- Keep the stable task panel current, but do not push every intermediate judgment into high-level issue-body sections.
- Treat `## Acceptance Criteria` as the current acceptance contract and keep it aligned with the task.
- Treat `## Review Summary` as a compact summary of the currently relevant review state, not as a replacement for raw review threads.
- When meaningful out-of-scope improvements are discovered during execution, file a separate Linear issue instead of expanding scope. The follow-up issue must include a clear title, description, and acceptance criteria, be placed in `Backlog`, be assigned to the same project as the current issue, link the current issue as `related`, and use `blockedBy` when the follow-up depends on the current issue.
- Move status only when the matching quality bar is met.
- Operate autonomously end-to-end unless blocked by missing requirements, secrets, or permissions.
- Use the blocked-access escape hatch only for true external blockers after exhausting documented fallbacks.

## Related skills

- `linear`: interact with Linear.
- `commit`: produce clean, logical commits during implementation.
- `push`: keep remote branch current and publish updates.
- `pull`: keep branch updated with latest `origin/main` before handoff.
- `land`: when ticket reaches `Merging`, explicitly open and follow `.codex/skills/land/SKILL.md`, which includes the `land` loop.

## Status map

- `Backlog` -> out of scope for this workflow; do not modify.
- `Todo` -> queued; immediately transition to `In Progress` before active work.
  - Special case: if a PR is already attached, treat as feedback/rework loop and run a PR feedback sweep before new feature work.
- `In Progress` -> implementation actively underway.
  - PR created / updated is only the entry signal into the PR closeout path, not the completion signal.
  - After every successful PR creation or branch update push, immediately attempt to enable auto-merge for the current PR before reading checks or mergeability.
- `Checking` -> stop the current implementation run after the bounded PR closeout pass.
  - Entry condition: PR already exists, the latest branch update has already triggered an immediate auto-merge attempt, and the result of that attempt is known.
  - For a ticket already in `Checking`, run one short recheck thread only.
  - Read only three signal classes: latest PR merge status, latest head SHA required checks, and the newest human review delta.
  - If merge is complete, move to `Done`.
  - If checks reached a non-success terminal state, move to `In Progress`.
  - If the latest auto-merge attempt failed for any reason other than the PR already being in clean status, record the exact failure in the PR or issue comment stream, then allow manual merge only after the latest head SHA required checks are green.
  - If automation cannot safely continue, move to `Human Review`.
  - If none of those exit conditions are hit, keep `Checking` and end the run.
  - In this ticket, `Human Review` only serves as the manual confirmation entry after successful `Checking` closeout or as the escalation path when automation cannot safely continue after the auto-merge path and manual-merge fallback have both been evaluated.
- `Human Review` -> validated work is waiting on human approval unless a new clear human delta or a new unresolved review delta exists, in which case immediately move to `Rework` and run the incremental rework flow.
- `Merging` -> approved by human; execute the `land` skill flow (do not bypass the repo-local GitHub helper path with ad-hoc CLI commands).
- `Rework` -> reviewer or human requested changes; execute the requested delta by reusing the existing branch, PR, and body workpad when safe.
- `Done` -> terminal state; no further action required.

## Step 0: Determine current ticket state and route

Step 0 may only run after the preflight body gate has classified the run as `execute`.

1. In normal execution mode, fetch the issue by explicit ticket ID.
2. In normal execution mode, read the current state.
3. Route to the matching flow:
   - `Backlog` -> do not modify issue content/state; stop and wait for human to move it to `Todo`.
   - `Todo` -> immediately move to `In Progress`, then ensure the issue body has the minimal required execution sections and `## Codex Workpad`, then start execution flow.
     - If a PR is already attached, start by reviewing all open PR comments and deciding required changes versus explicit pushback responses.
   - `In Progress` -> continue execution flow from the current issue-body snapshot.
   - `Checking` -> run one bounded recheck pass using only PR merge state, latest head SHA required checks, and newest human review delta; then route to `Done`, `In Progress`, `Human Review`, or stay in `Checking`.
   - `Human Review` -> if a new execute-mode human delta or an active unresolved review delta exists, immediately move to `Rework` and run the incremental rework flow; otherwise stop immediately and resume only on a later explicit trigger.
   - `Merging` -> on entry, open and follow `.codex/skills/land/SKILL.md`; do not bypass the repo-local GitHub helper path with ad-hoc CLI commands.
   - `Rework` -> run the incremental rework flow, reusing the existing branch, PR, and body workpad when safe.
   - `Done` -> do nothing and shut down.
4. Check whether a PR already exists for the current branch and whether it is closed.
   - If a branch PR exists and is `CLOSED` or `MERGED`, treat prior branch work as non-reusable for this run.
   - Create a fresh branch from `origin/main` and restart execution flow as a new attempt.
5. For `Todo` tickets, do startup sequencing in this exact order:
   - `update_issue(..., state: "In Progress")`
   - preserve the existing human-authored body structure
   - reuse equivalent existing sections when they already serve the same purpose
   - add only the minimum missing execution sections when no equivalent section already exists
   - only then begin analysis, planning, validation, or implementation work
6. If state and issue-body content are inconsistent, update only the minimal high-level execution summary with verified facts, then proceed with the safest flow.

## Step 1: Start/continue execution (Todo or In Progress)

1. Do not normalize the issue body into a forced canonical order.
2. If arriving from `Todo`, do not delay on additional status transitions: the issue should already be `In Progress` before this step begins.
3. Immediately reconcile the active execution record before new edits:
   - Ensure `## Execution Brief` accurately reflects the latest confirmed result, the next required action, and whether a human decision is needed.
   - Ensure `## Acceptance Criteria` is current and still makes sense for the task.
   - Ensure `## Review Summary` contains only compact, still-relevant review outcomes. If no actionable review batch exists, set the review-request fields to `None`.
   - Ensure `## Blockers` reflects only active blockers.
   - Ensure `## Codex Workpad` remains the main execution record.
4. Start work by writing or updating a hierarchical plan in `## Codex Workpad`.
5. Ensure `## Codex Workpad` includes a compact environment stamp at the top as a code fence line:
   - Format: `<host>:<abs-workdir>@<short-sha>`
   - Example: `devbox-01:/home/dev-user/code/symphony-workspaces/MT-32@7bdde33bc`
   - Do not include metadata already inferable from issue fields (`issue ID`, `status`, `branch`, `PR link`).
6. Add explicit acceptance criteria in `## Acceptance Criteria` and execution TODOs in `## Codex Workpad`.
   - If changes are user-facing, include a UI walkthrough acceptance criterion that describes the end-to-end user path to validate.
   - If changes touch app files or app behavior, add explicit app-specific flow checks to `## Acceptance Criteria`.
   - If the ticket description already includes `Validation`, `Test Plan`, or `Testing`, carry those requirements into `## Acceptance Criteria` and `## Codex Workpad > Validation` as required checkboxes.
7. Run a principal-style self-review of the plan and refine it in `## Codex Workpad`.
8. Before implementing, capture a concrete reproduction signal and record it in `## Codex Workpad > Notes`.
9. Run the `pull` skill to sync with latest `origin/main` before any code edits, then record the pull or sync result in `## Codex Workpad > Notes`.
   - Include `pull skill evidence` with merge source(s), result (`clean` or `conflicts resolved`), and resulting `HEAD` short SHA.
10. Compact old low-value agent-generated notes when necessary and proceed to execution.

## PR feedback sweep protocol (required)

When a ticket has an attached PR, run this protocol before moving to `Human Review`:

1. Identify the PR number from issue links or attachments.
2. In review-sensitive states, gather only the new or still-unresolved feedback required for this pass from the necessary channels:
   - Top-level PR comments (via the repo-local GitHub helper or equivalent authenticated GitHub API path).
   - Inline review comments (via the repo-local GitHub helper or equivalent authenticated GitHub API path).
   - Review summaries or states (via the repo-local GitHub helper or equivalent authenticated GitHub API path).
   - Only the necessary short current-issue comments that add review context or human decisions not yet reflected in the issue body.
3. Treat every actionable reviewer comment (human or bot), including inline review comments, as blocking until one of these is true:
   - code, test, or docs updated to address it, or
   - explicit, justified pushback reply is posted on that thread.
4. Update `## Review Summary` with:
   - `Latest Review Request`: the exact compact summary of the latest actionable review batch, or `None` when none exists.
   - `Handled Review Request`: the exact same summary once fully handled, or `None` when no actionable review batch exists.
   - `Open Items`: the current outstanding items and their resolution status.
   - `Resolved Items`: only a short summary of already-closed items when useful.
   - When no actionable review batch remains, set both `Latest Review Request` and `Handled Review Request` to `None`.
5. Re-run validation after feedback-driven changes and push updates.
6. Repeat this incremental sweep until there are no outstanding actionable comments for the current pass.

## Blocked-access escape hatch (required behavior)

Use this only when completion is blocked by missing required tools or missing auth/permissions that cannot be resolved in-session.

- GitHub is **not** a valid blocker by default. Always try fallback strategies first (alternate remote/auth mode, then continue publish/review flow).
- Do not move to `Human Review` for GitHub access/auth until all fallback strategies have been attempted and documented in `## Blockers` and `## Codex Workpad`.
- If a non-GitHub required tool is missing, or required non-GitHub auth is unavailable, move the ticket to `Human Review` with a short blocker brief in `## Blockers` that includes:
  - what is missing,
  - why it blocks required acceptance or validation,
  - exact human action needed to unblock.
- Keep blocker text concise and action-oriented.

## Checking closeout and escalation rules

- Checking closes successfully only when the PR is still valid and the latest head SHA required checks are passing.
- Checks from an older head SHA do not satisfy the closeout requirement for the latest commit.
- If a new commit is pushed during `Checking`, discard prior check conclusions and evaluate only the new head SHA.
- Do not require the PR to be merged and do not require `Merging` to finish for this ticket to succeed.
- Every PR create/update push must be followed immediately by an auto-merge attempt for the current PR before reading checks, mergeability, or other closeout signals.
- Treat `already enabled` as a successful auto-merge outcome.
- If the auto-merge attempt returns that the PR is already in clean status, do not treat that as a permission blocker; it means the PR has already advanced to the direct-merge stage and can use the manual-merge fallback once latest head SHA required checks are green.
- Only when the latest auto-merge attempt failed for another reason should the run preserve a manual-merge fallback path, and that fallback must be called out explicitly in a PR or issue comment before any manual merge happens.
- When an attached PR already exists, do not move to `Human Review` merely because the PR exists.
- During `Checking`, read only three signal classes: latest PR merge status, latest head SHA required checks, and the newest human review delta.
- If merge is complete, move to `Done`.
- If required checks on the latest head SHA reach a non-success terminal state, move to `In Progress`.
- If checks are green and auto-merge is active, prefer the auto-merge path over any manual merge.
- If checks are green and the latest auto-merge attempt failed for a reason other than clean status, manual merge is allowed only as an explicit fallback and only after the failure reason has been reported in the PR or issue comment stream.
- If checks are green but neither auto-merge nor the explicit manual-merge fallback can safely complete because of permission, conflict, protection-rule, merge-queue, or similar automation blockers, move to `Human Review`.
- If a human explicitly asks for more implementation work while in `Checking`, move to `In Progress`.
- If checks fail, stay on the same branch and in the same PR by default; continue fixing there instead of opening a new ticket, opening a new PR, or escalating to `Human Review` after a single failure.
- First-version escalation must cover at least repeated failures with diminishing returns, merge conflicts that cannot be resolved safely, repository protection rules that require human action, insufficient permissions, checks that remain abnormal for too long, and PRs that are closed or unreachable.
- Escalation comments must minimally include the failure reason, current PR identifier, current head SHA, affected checks or gate, and the recommended human action, with deduplication for repeated identical causes.

## Step 2: Execution phase (Todo -> In Progress -> Checking -> Human Review)

1. Determine current repo state (`branch`, `git status`, `HEAD`) and verify the kickoff pull result is already recorded in `## Codex Workpad`.
2. If current issue state is `Todo`, move it to `In Progress`; otherwise leave the current state unchanged.
3. Load the existing issue-body snapshot, preserve the stable human-authored task definition, and treat `## Codex Workpad` as the active execution checklist.
   - Edit it whenever reality changes (scope, risks, validation approach, discovered tasks).
4. Implement against the hierarchical TODOs and keep the execution record current:
   - Check off completed items.
   - Add newly discovered items in the appropriate section.
   - Keep the existing human-authored task definition intact as scope evolves.
   - Update `## Codex Workpad` after each meaningful milestone.
   - Update `## Execution Brief`, `## Review Summary`, and `## Blockers` only when their high-level conclusions actually change.
   - Never leave completed work unchecked in the plan.
   - For tickets that started as `Todo` with an attached PR, run the full PR feedback sweep protocol immediately after kickoff and before new feature work.
5. Run validation or tests required for the scope.
   - Mandatory gate: execute all ticket-provided `Validation`, `Test Plan`, or `Testing` requirements when present; treat unmet items as incomplete work.
   - Prefer a targeted proof that directly demonstrates the behavior you changed.
   - You may make temporary local proof edits to validate assumptions when this increases confidence.
   - Revert every temporary proof edit before commit or push.
   - Document these temporary proof steps and outcomes in `## Codex Workpad > Validation` or `Notes`.
   - If app-touching, run `launch-app` validation and capture or upload media before handoff.
6. Re-check all completion criteria and close any gaps.
7. Before every `git push` attempt, run the required validation for your scope and confirm it passes; if it fails, address issues and rerun until green, then commit and push changes.
8. Attach PR URL to the issue (prefer attachment; use the issue body only if attachment is unavailable).
   - Ensure the GitHub PR has label `symphony` (add it if missing).
   - Immediately after PR creation or branch-update push succeeds, attempt to enable auto-merge for the current PR before reading checks, mergeability, or other closeout signals.
   - If the auto-merge attempt fails for any reason other than `already enabled` or `clean status`, record that exact failure in the PR or issue comment stream and preserve manual merge only as an explicit fallback after latest head SHA required checks are green.
9. Merge latest `origin/main` into branch, resolve conflicts, and rerun checks.
10. Update the execution sections with final checklist status and validation notes.
   - Mark completed items in `## Acceptance Criteria` and `## Codex Workpad` as checked.
   - Add final handoff notes in `## Execution Brief` and `## Codex Workpad > Notes`.
   - Keep PR linkage on the issue via attachment or link fields.
   - Add a short `### Confusions` section at the bottom of `## Codex Workpad` only when something was genuinely confusing during execution.
11. Before moving to `Checking`, perform one bounded PR feedback and closeout pass:
   - Read the PR `Manual QA Plan` comment when present and use it to sharpen UI or runtime test coverage.
   - Run the PR feedback sweep protocol for the current pass.
   - Confirm that the latest PR create/update push already triggered an immediate auto-merge attempt; do not defer that attempt until after checks are read.
   - Confirm the PR is still valid and that the current PR latest head SHA required checks are passing (green).
   - If the attached PR already has review comments, top-level PR comments, or review threads, confirm there is no unresolved review delta before moving to `Human Review`.
   - Do not treat checks on an older head SHA as sufficient for closeout after newer commits land.
   - Confirm every required ticket-provided validation or test-plan item is explicitly marked complete in the issue body.
   - If checks fail, keep working in the same branch and PR by default; do not open a new ticket, do not open a new PR, and do not move to `Human Review` after a single failed run.
   - If a new commit lands during `Checking`, restart the closeout decision using only the new head SHA.
   - If new unresolved feedback or failing checks are discovered, handle only the bounded delta for this run or stop with an explicit blocker or handoff; do not remain in an open-ended same-run polling loop.
   - If the bounded pass succeeds and auto-merge is active, move to `Checking` and stop this implementation run.
   - If the bounded pass succeeds, the latest auto-merge attempt reported clean status, and latest head SHA required checks are green, manual merge may proceed as the documented fallback without first treating clean status as a blocker.
   - Refresh `## Execution Brief`, `## Acceptance Criteria`, `## Review Summary`, `## Blockers`, and `## Codex Workpad` so they reflect the completed work accurately.
12. Do not move directly from `In Progress` to `Human Review` on a successful closeout pass; move to `Checking` first.
   - Exception: if blocked by missing required non-GitHub tools or auth per the blocked-access escape hatch, move to `Human Review` with the blocker brief and explicit unblock actions.
13. For `Todo` tickets that already had a PR attached at kickoff:
   - Ensure all existing PR feedback was reviewed and resolved, including inline review comments.
   - Ensure branch was pushed with any required updates.
   - Do not skip `Checking` closeout and do not move to `Human Review` merely because the PR already exists.
14. Add a short issue comment only at a significant external checkpoint:
   - entering `Human Review`,
   - a true blocker requiring human action,
   - a completed rework pass after review feedback,
   - or final completion when a short thread-visible note is useful.
   Keep these comments brief and never use them as the sole source of current instructions or progress state.
15. Before stopping this run from normal execution, do not force the issue to `Human Review` unless `Checking` has closed successfully or an explicit escalation path requires a human handoff.

## Step 3: Human Review and merge handling

1. When the issue is in `Human Review`, do not code unless either a new active execute-mode human instruction exists or an active unresolved review delta exists.
2. If no such new instruction or unresolved review delta is present, stop immediately. A later run may resume only after an explicit trigger. Do not poll inside the same run.
3. If a new execute-mode human delta exists, immediately move the issue to `Rework` and follow the incremental rework flow.
4. If an active unresolved review delta exists, move the issue to `Rework` and follow the incremental rework flow.
5. If approved, human moves the issue to `Merging`.
6. When the issue is in `Merging`, open and follow `.codex/skills/land/SKILL.md`, then run the `land` skill in a loop until the PR is merged. Do not bypass the repo-local GitHub helper path with ad-hoc CLI commands.
   - In this workflow, `Merging` is the manual fallback lane after the auto-merge path failed or became unnecessary because the PR was already in clean status.
7. After merge is complete, move the issue to `Done`.

## Step 4: Rework handling

1. Treat `Rework` as incremental execution by default, not a mandatory full approach reset.
2. On entry to `Rework`, read the necessary current-issue comments on demand and identify the new human or review delta since the last `Human Review` handoff.
3. If no new actionable delta exists, do not repeat old work.
4. Start from the latest effective human instruction found in current-issue comments, then use `## Scope Snapshot`, `## Review Summary`, and the current PR or workpad state as supporting stable context.
5. If the newest relevant human comment conflicts with stale body summaries, follow the human comment for the current run and defer body synchronization until the run ends.
6. Treat `## Scope Snapshot` as supporting context only; it must not override or compete with the latest effective human instruction from current-issue comments.
7. Reuse the existing branch, PR, and `## Codex Workpad` whenever they remain valid for the requested delta.
8. Do not close the existing PR, delete the workpad, or create a fresh branch unless one of these is true:
   - the branch PR is already `CLOSED` or `MERGED`,
   - the current branch or workpad state is non-reusable for the requested delta, or
   - a human explicitly requests a restart from scratch.
9. If a full restart is required, create a fresh branch from `origin/main`, preserve the human-authored task content, restore only the minimum required execution sections, and restart from the normal kickoff flow.
10. Do not close an existing open PR automatically unless a human explicitly instructs you to do so.
11. Otherwise, update `## Execution Brief`, `## Acceptance Criteria`, `## Review Summary`, and `## Codex Workpad` for the delta, implement only the requested changes plus required validation, and then return to `Human Review` when complete.
12. Before stopping the rework run, confirm that the issue state has been set back to `Human Review`.

## Completion bar before Human Review

- Step 1 and Step 2 execution checklist is fully complete.
- `## Acceptance Criteria` and required ticket-provided validation items are complete.
- Validation or tests are green for the latest commit.
- PR feedback sweep is complete.
- If the PR already has review comments, top-level PR comments, or review threads, no actionable comments remain and `## Review Summary` accurately reflects that there is no unresolved review delta.
- PR is still valid, the latest head SHA required checks are green, branch is pushed, and PR is linked on the issue.
- Required PR metadata is present (`symphony` label).
- If app-touching, runtime validation or media requirements are complete.
- High-level handoff facts are accurately reflected in `## Execution Brief`, and detailed execution evidence is present in `## Codex Workpad`.

## Guardrails

- If the branch PR is already closed or merged, do not reuse that branch or prior implementation state for continuation.
- For closed or merged branch PRs, create a new branch from `origin/main` and restart from reproduction and planning as if starting fresh.
- If issue state is `Backlog`, do not modify it; wait for human to move to `Todo`.
- Use the issue body as a stable task panel, not as a destructive normalization target.
- Use exactly one persistent `## Codex Workpad` section per issue body.
- Do not let the issue body become an unbounded log. Compact or prune only low-value agent-generated execution traces.
- Never compact or remove human-authored task definition, scope, non-goals, constraints, acceptance, or historical decisions.
- If issue-body editing is unavailable in-session, report blocked.
- Temporary proof edits are allowed only for local verification and must be reverted before commit.
- If out-of-scope improvements are found, create a separate Backlog issue rather than expanding current scope.
- Do not move to `Human Review` unless the `Completion bar before Human Review` is satisfied, except for the documented blocked-access escape hatch.
- In `Human Review`, determine re-entry by checking the newest relevant human-authored current-issue comment and any unresolved review delta.
- If state is terminal (`Done`), do nothing and shut down.
- Keep agent-authored issue text concise, specific, and reviewer-oriented.
- Comments are allowed for short status pings, but they must never be the sole source of long-term task definition or progress state.
- When stopping work, ending the run, or yielding because of a blocker, do not force the issue to `Human Review` unless `Checking` has closed successfully or a documented escalation path requires a human handoff.

## Issue body template

Do not force this structure when the issue body already has useful human-authored structure. Reuse equivalent existing sections when possible, and use the following only as a minimal additive pattern when no equivalent execution section already exists:

````md
## Scope Snapshot

- <stable scope summary maintained by the agent; not the latest human instruction channel>

## Execution Brief

- Latest Result: <last confirmed factual outcome>
- Next Required Action: <next immediate required action>
- Human Decision Needed: <None or one specific decision question>

## Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2

## Review Summary

- Latest Review Request: <exact compact summary of the latest actionable review batch or None>
- Handled Review Request: <exact same summary once fully handled, or None>
- Open Items: <review item / source / status; if none write None>
- Resolved Items: <optional short summary>

## Blockers

- None

## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan

- [ ] 1. Parent task
- [ ] 2. Parent task

### Validation

- [ ] targeted tests: `<command>`

### Notes

- <recent compact progress note>

### Confusions

- <only include when something was genuinely confusing>
````
