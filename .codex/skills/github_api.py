#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

API_ROOT = "https://api.github.com"
GRAPHQL_URL = f"{API_ROOT}/graphql"
DEFAULT_HEADERS = {
    "Accept": "application/vnd.github+json",
    "User-Agent": "symphony-github-helper",
    "X-GitHub-Api-Version": "2022-11-28",
}
REPO_URL_RE = re.compile(
    r"github\.com[:/](?P<owner>[^/]+)/(?P<repo>[^/.]+)(?:\.git)?$"
)


class GitHubApiError(RuntimeError):
    def __init__(
        self,
        message: str,
        *,
        status: int | None = None,
        payload: Any | None = None,
    ) -> None:
        super().__init__(message)
        self.status = status
        self.payload = payload


@dataclass(frozen=True)
class RepoContext:
    owner: str
    repo: str
    root: Path | None


def run_git(args: list[str], cwd: Path | None = None) -> str:
    cmd = ["git", *args]
    proc = subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if proc.returncode != 0:
        error = proc.stderr.strip() or proc.stdout.strip() or "git command failed"
        raise GitHubApiError(error)
    return proc.stdout.strip()


def git_token() -> str:
    proc = subprocess.run(
        ["git", "credential", "fill"],
        input="protocol=https\nhost=github.com\n\n",
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if proc.returncode != 0:
        error = proc.stderr.strip() or "git credential fill failed"
        raise GitHubApiError(error)

    fields: dict[str, str] = {}
    for line in proc.stdout.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        fields[key] = value

    token = fields.get("password")
    if not token:
        raise GitHubApiError("GitHub token unavailable from git credential helper")
    return token


def repo_root(cwd: Path | None = None) -> Path | None:
    try:
        return Path(run_git(["rev-parse", "--show-toplevel"], cwd=cwd))
    except GitHubApiError:
        return None


def resolve_repo(repo: str | None = None, cwd: Path | None = None) -> RepoContext:
    if repo:
        if "/" not in repo:
            raise GitHubApiError(f"invalid repo {repo!r}; expected owner/repo")
        owner, name = repo.split("/", 1)
        return RepoContext(owner=owner, repo=name, root=repo_root(cwd))

    root = repo_root(cwd)
    if root is None:
        raise GitHubApiError("not inside a git repository and no --repo override provided")

    origin = run_git(["remote", "get-url", "origin"], cwd=root)
    match = REPO_URL_RE.search(origin)
    if not match:
        raise GitHubApiError(f"cannot parse GitHub origin URL: {origin}")

    return RepoContext(
        owner=match.group("owner"),
        repo=match.group("repo"),
        root=root,
    )


def current_branch(cwd: Path | None = None) -> str:
    branch = run_git(["branch", "--show-current"], cwd=cwd)
    if not branch:
        raise GitHubApiError("current git branch is blank")
    return branch


def read_body(body: str | None, body_file: str | None) -> str | None:
    if body is not None and body_file is not None:
        raise GitHubApiError("use either --body or --body-file, not both")
    if body_file is not None:
        return Path(body_file).read_text()
    return body


def request_json(
    method: str,
    url: str,
    *,
    body: Any | None = None,
    headers: dict[str, str] | None = None,
) -> Any:
    token = git_token()
    payload = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=payload, method=method)
    merged_headers = dict(DEFAULT_HEADERS)
    if headers:
        merged_headers.update(headers)
    if payload is not None:
        merged_headers["Content-Type"] = "application/json"
    merged_headers["Authorization"] = f"Bearer {token}"

    for key, value in merged_headers.items():
        req.add_header(key, value)

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            text = resp.read().decode()
    except urllib.error.HTTPError as exc:
        text = exc.read().decode()
        payload_obj: Any
        try:
            payload_obj = json.loads(text)
        except json.JSONDecodeError:
            payload_obj = text

        message = extract_error_message(payload_obj) or f"GitHub API HTTP {exc.code}"
        raise GitHubApiError(message, status=exc.code, payload=payload_obj) from None

    if not text:
        return {}

    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise GitHubApiError(f"GitHub API returned non-JSON response: {text}") from exc


def extract_error_message(payload: Any) -> str | None:
    if isinstance(payload, dict):
        if "message" in payload and isinstance(payload["message"], str):
            return payload["message"]
        errors = payload.get("errors")
        if isinstance(errors, list) and errors:
            first = errors[0]
            if isinstance(first, dict) and isinstance(first.get("message"), str):
                return first["message"]
    if isinstance(payload, str):
        return payload.strip() or None
    return None


def rest_api(
    repo_ctx: RepoContext,
    method: str,
    path: str,
    *,
    params: dict[str, Any] | None = None,
    body: Any | None = None,
) -> Any:
    query = ""
    if params:
        query = "?" + urllib.parse.urlencode(params, doseq=True)
    url = f"{API_ROOT}/repos/{repo_ctx.owner}/{repo_ctx.repo}{path}{query}"
    return request_json(method, url, body=body)


def graphql(query: str, variables: dict[str, Any]) -> Any:
    payload = {"query": query, "variables": variables}
    result = request_json("POST", GRAPHQL_URL, body=payload)
    errors = result.get("errors")
    if errors:
        message = extract_error_message(result) or "GitHub GraphQL request failed"
        raise GitHubApiError(message, payload=result)
    return result["data"]


def default_branch(repo_ctx: RepoContext) -> str:
    repo = request_json(
        "GET", f"{API_ROOT}/repos/{repo_ctx.owner}/{repo_ctx.repo}"
    )
    branch = repo.get("default_branch")
    if not branch:
        raise GitHubApiError("repository default branch is unavailable")
    return branch


def list_pull_requests(
    repo_ctx: RepoContext,
    *,
    branch: str,
    state: str = "open",
) -> list[dict[str, Any]]:
    prs = rest_api(
        repo_ctx,
        "GET",
        "/pulls",
        params={
            "head": f"{repo_ctx.owner}:{branch}",
            "state": state,
            "per_page": 100,
        },
    )
    if not isinstance(prs, list):
        raise GitHubApiError("unexpected pull request list response")
    return sorted(
        prs,
        key=lambda pr: pr.get("updated_at", ""),
        reverse=True,
    )


def current_pull_request(
    repo_ctx: RepoContext,
    *,
    branch: str | None = None,
    state: str = "open",
) -> dict[str, Any] | None:
    branch_name = branch or current_branch(repo_ctx.root)
    prs = list_pull_requests(repo_ctx, branch=branch_name, state=state)
    return prs[0] if prs else None


def view_pull_request(repo_ctx: RepoContext, number: int) -> dict[str, Any]:
    data = graphql(
        """
        query($owner: String!, $repo: String!, $number: Int!) {
          repository(owner: $owner, name: $repo) {
            pullRequest(number: $number) {
              id
              number
              url
              title
              body
              state
              mergeable
              mergeStateStatus
              viewerCanEnableAutoMerge
              headRefOid
              autoMergeRequest {
                enabledAt
                mergeMethod
              }
            }
          }
          viewer {
            login
          }
        }
        """,
        {"owner": repo_ctx.owner, "repo": repo_ctx.repo, "number": number},
    )
    pr = data["repository"]["pullRequest"]
    if pr is None:
        raise GitHubApiError(f"pull request #{number} not found")
    pr["viewer"] = data["viewer"]["login"]
    return pr


def ensure_pull_request(
    repo_ctx: RepoContext,
    *,
    title: str,
    body: str,
    base: str | None = None,
    branch: str | None = None,
) -> dict[str, Any]:
    branch_name = branch or current_branch(repo_ctx.root)
    open_pr = current_pull_request(repo_ctx, branch=branch_name, state="open")
    if open_pr:
        rest_api(
            repo_ctx,
            "PATCH",
            f"/pulls/{open_pr['number']}",
            body={"title": title, "body": body},
        )
        pr = view_pull_request(repo_ctx, int(open_pr["number"]))
        return {"action": "updated", "pull_request": pr}

    existing = list_pull_requests(repo_ctx, branch=branch_name, state="all")
    if existing:
        raise GitHubApiError(
            "Current branch is tied to a closed or merged PR; create a new branch + PR."
        )

    created = rest_api(
        repo_ctx,
        "POST",
        "/pulls",
        body={
            "title": title,
            "head": branch_name,
            "base": base or default_branch(repo_ctx),
            "body": body,
        },
    )
    pr = view_pull_request(repo_ctx, int(created["number"]))
    return {"action": "created", "pull_request": pr}


def classify_auto_merge_error(message: str) -> str | None:
    normalized = message.lower()
    if "already enabled" in normalized or "already has auto-merge" in normalized:
        return "already_enabled"
    if "clean status" in normalized:
        return "clean_status"
    return None


def enable_auto_merge(
    repo_ctx: RepoContext,
    *,
    number: int,
    merge_method: str = "SQUASH",
) -> dict[str, Any]:
    pr = view_pull_request(repo_ctx, number)
    if pr.get("autoMergeRequest"):
        return {
            "classification": "already_enabled",
            "pull_request": pr,
            "message": "auto-merge already enabled",
        }

    try:
        data = graphql(
            """
            mutation($prId: ID!, $mergeMethod: PullRequestMergeMethod!) {
              enablePullRequestAutoMerge(
                input: {pullRequestId: $prId, mergeMethod: $mergeMethod}
              ) {
                pullRequest {
                  number
                  autoMergeRequest {
                    enabledAt
                    mergeMethod
                  }
                }
              }
            }
            """,
            {"prId": pr["id"], "mergeMethod": merge_method.upper()},
        )
    except GitHubApiError as exc:
        classification = classify_auto_merge_error(str(exc))
        if classification:
            return {
                "classification": classification,
                "pull_request": pr,
                "message": str(exc),
            }
        raise

    return {
        "classification": "enabled",
        "pull_request": pr,
        "auto_merge": data["enablePullRequestAutoMerge"]["pullRequest"]["autoMergeRequest"],
    }


def merge_pull_request(
    repo_ctx: RepoContext,
    *,
    number: int,
    merge_method: str = "squash",
    subject: str | None = None,
    body: str | None = None,
) -> dict[str, Any]:
    pr = view_pull_request(repo_ctx, number)
    payload: dict[str, Any] = {
        "merge_method": merge_method.lower(),
        "sha": pr["headRefOid"],
    }
    if subject is not None:
        payload["commit_title"] = subject
    if body is not None:
        payload["commit_message"] = body

    return rest_api(
        repo_ctx,
        "PUT",
        f"/pulls/{number}/merge",
        body=payload,
    )


def issue_comments(repo_ctx: RepoContext, *, number: int) -> list[dict[str, Any]]:
    comments = rest_api(
        repo_ctx,
        "GET",
        f"/issues/{number}/comments",
        params={"per_page": 100},
    )
    if not isinstance(comments, list):
        raise GitHubApiError("unexpected issue comments response")
    return comments


def create_issue_comment(
    repo_ctx: RepoContext,
    *,
    number: int,
    body: str,
) -> dict[str, Any]:
    return rest_api(
        repo_ctx,
        "POST",
        f"/issues/{number}/comments",
        body={"body": body},
    )


def review_comments(repo_ctx: RepoContext, *, number: int) -> list[dict[str, Any]]:
    comments = rest_api(
        repo_ctx,
        "GET",
        f"/pulls/{number}/comments",
        params={"per_page": 100},
    )
    if not isinstance(comments, list):
        raise GitHubApiError("unexpected review comments response")
    return comments


def reply_review_comment(
    repo_ctx: RepoContext,
    *,
    number: int,
    comment_id: int,
    body: str,
) -> dict[str, Any]:
    return rest_api(
        repo_ctx,
        "POST",
        f"/pulls/{number}/comments",
        body={"body": body, "in_reply_to": comment_id},
    )


def reviews(repo_ctx: RepoContext, *, number: int) -> list[dict[str, Any]]:
    payload = rest_api(
        repo_ctx,
        "GET",
        f"/pulls/{number}/reviews",
        params={"per_page": 100},
    )
    if not isinstance(payload, list):
        raise GitHubApiError("unexpected reviews response")
    return payload


def check_runs(repo_ctx: RepoContext, *, sha: str) -> dict[str, Any]:
    payload = rest_api(
        repo_ctx,
        "GET",
        f"/commits/{sha}/check-runs",
        params={"per_page": 100},
    )
    if not isinstance(payload, dict):
        raise GitHubApiError("unexpected check-runs response")
    return payload


def close_branch_pull_requests(
    repo_ctx: RepoContext,
    *,
    branch: str,
    comment: str,
) -> dict[str, Any]:
    results: list[dict[str, Any]] = []
    for pr in list_pull_requests(repo_ctx, branch=branch, state="open"):
        number = int(pr["number"])
        try:
            if comment:
                create_issue_comment(repo_ctx, number=number, body=comment)
            rest_api(
                repo_ctx,
                "PATCH",
                f"/pulls/{number}",
                body={"state": "closed"},
            )
            results.append({"number": number, "status": "closed"})
        except GitHubApiError as exc:
            results.append(
                {
                    "number": number,
                    "status": "error",
                    "message": str(exc),
                    "http_status": exc.status,
                }
            )
    return {"results": results}


def close_pull_request(
    repo_ctx: RepoContext,
    *,
    number: int,
    comment: str,
) -> dict[str, Any]:
    if comment:
        create_issue_comment(repo_ctx, number=number, body=comment)
    return rest_api(
        repo_ctx,
        "PATCH",
        f"/pulls/{number}",
        body={"state": "closed"},
    )


def print_json(payload: Any) -> None:
    json.dump(payload, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="GitHub helper without gh CLI")
    subparsers = parser.add_subparsers(dest="command", required=True)

    def add_repo_flag(cmd: argparse.ArgumentParser) -> None:
        cmd.add_argument("--repo", help="owner/repo override")

    current_pr_cmd = subparsers.add_parser("current-pr")
    add_repo_flag(current_pr_cmd)
    current_pr_cmd.add_argument("--branch")
    current_pr_cmd.add_argument("--state", default="open")

    list_prs_cmd = subparsers.add_parser("list-prs")
    add_repo_flag(list_prs_cmd)
    list_prs_cmd.add_argument("--branch", required=True)
    list_prs_cmd.add_argument("--state", default="open")

    pr_view_cmd = subparsers.add_parser("pr-view")
    add_repo_flag(pr_view_cmd)
    pr_view_cmd.add_argument("--number", type=int, required=True)

    ensure_pr_cmd = subparsers.add_parser("ensure-pr")
    add_repo_flag(ensure_pr_cmd)
    ensure_pr_cmd.add_argument("--title", required=True)
    ensure_pr_cmd.add_argument("--body")
    ensure_pr_cmd.add_argument("--body-file")
    ensure_pr_cmd.add_argument("--base")
    ensure_pr_cmd.add_argument("--branch")

    enable_cmd = subparsers.add_parser("enable-auto-merge")
    add_repo_flag(enable_cmd)
    enable_cmd.add_argument("--number", type=int, required=True)
    enable_cmd.add_argument("--method", default="SQUASH")

    merge_cmd = subparsers.add_parser("merge-pr")
    add_repo_flag(merge_cmd)
    merge_cmd.add_argument("--number", type=int, required=True)
    merge_cmd.add_argument("--method", default="squash")
    merge_cmd.add_argument("--subject")
    merge_cmd.add_argument("--body")
    merge_cmd.add_argument("--body-file")

    issue_comments_cmd = subparsers.add_parser("issue-comments")
    add_repo_flag(issue_comments_cmd)
    issue_comments_cmd.add_argument("--number", type=int, required=True)

    issue_comment_create_cmd = subparsers.add_parser("issue-comment-create")
    add_repo_flag(issue_comment_create_cmd)
    issue_comment_create_cmd.add_argument("--number", type=int, required=True)
    issue_comment_create_cmd.add_argument("--body")
    issue_comment_create_cmd.add_argument("--body-file")

    review_comments_cmd = subparsers.add_parser("review-comments")
    add_repo_flag(review_comments_cmd)
    review_comments_cmd.add_argument("--number", type=int, required=True)

    review_reply_cmd = subparsers.add_parser("review-comment-reply")
    add_repo_flag(review_reply_cmd)
    review_reply_cmd.add_argument("--number", type=int, required=True)
    review_reply_cmd.add_argument("--comment-id", type=int, required=True)
    review_reply_cmd.add_argument("--body")
    review_reply_cmd.add_argument("--body-file")

    reviews_cmd = subparsers.add_parser("reviews")
    add_repo_flag(reviews_cmd)
    reviews_cmd.add_argument("--number", type=int, required=True)

    checks_cmd = subparsers.add_parser("check-runs")
    add_repo_flag(checks_cmd)
    checks_cmd.add_argument("--sha", required=True)

    close_cmd = subparsers.add_parser("close-branch-prs")
    add_repo_flag(close_cmd)
    close_cmd.add_argument("--branch", required=True)
    close_cmd.add_argument("--comment", default="")

    close_pr_cmd = subparsers.add_parser("close-pr")
    add_repo_flag(close_pr_cmd)
    close_pr_cmd.add_argument("--number", type=int, required=True)
    close_pr_cmd.add_argument("--comment", default="")

    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_ctx = resolve_repo(args.repo)

    if args.command == "current-pr":
        pr = current_pull_request(
            repo_ctx,
            branch=args.branch,
            state=args.state,
        )
        if pr is None:
            raise GitHubApiError("no matching pull request found")
        print_json(view_pull_request(repo_ctx, int(pr["number"])))
        return 0

    if args.command == "list-prs":
        print_json(
            list_pull_requests(
                repo_ctx,
                branch=args.branch,
                state=args.state,
            )
        )
        return 0

    if args.command == "pr-view":
        print_json(view_pull_request(repo_ctx, args.number))
        return 0

    if args.command == "ensure-pr":
        body = read_body(args.body, args.body_file)
        if body is None:
            raise GitHubApiError("pull request body is required")
        print_json(
            ensure_pull_request(
                repo_ctx,
                title=args.title,
                body=body,
                base=args.base,
                branch=args.branch,
            )
        )
        return 0

    if args.command == "enable-auto-merge":
        print_json(
            enable_auto_merge(
                repo_ctx,
                number=args.number,
                merge_method=args.method,
            )
        )
        return 0

    if args.command == "merge-pr":
        print_json(
            merge_pull_request(
                repo_ctx,
                number=args.number,
                merge_method=args.method,
                subject=args.subject,
                body=read_body(args.body, args.body_file),
            )
        )
        return 0

    if args.command == "issue-comments":
        print_json(issue_comments(repo_ctx, number=args.number))
        return 0

    if args.command == "issue-comment-create":
        body = read_body(args.body, args.body_file)
        if body is None:
            raise GitHubApiError("comment body is required")
        print_json(create_issue_comment(repo_ctx, number=args.number, body=body))
        return 0

    if args.command == "review-comments":
        print_json(review_comments(repo_ctx, number=args.number))
        return 0

    if args.command == "review-comment-reply":
        body = read_body(args.body, args.body_file)
        if body is None:
            raise GitHubApiError("review reply body is required")
        print_json(
            reply_review_comment(
                repo_ctx,
                number=args.number,
                comment_id=args.comment_id,
                body=body,
            )
        )
        return 0

    if args.command == "reviews":
        print_json(reviews(repo_ctx, number=args.number))
        return 0

    if args.command == "check-runs":
        print_json(check_runs(repo_ctx, sha=args.sha))
        return 0

    if args.command == "close-branch-prs":
        print_json(
            close_branch_pull_requests(
                repo_ctx,
                branch=args.branch,
                comment=args.comment,
            )
        )
        return 0

    if args.command == "close-pr":
        print_json(
            close_pull_request(
                repo_ctx,
                number=args.number,
                comment=args.comment,
            )
        )
        return 0

    raise GitHubApiError(f"unsupported command: {args.command}")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except GitHubApiError as exc:
        sys.stderr.write(f"{exc}\n")
        raise SystemExit(1) from None
