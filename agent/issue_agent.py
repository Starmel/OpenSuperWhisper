import sys

import builder
import coder
import gitops
import github
from config import (
    BASE_BRANCH,
    MAX_BUILD_FIX_ATTEMPTS,
    UPSTREAM_REPO,
    ConfigError,
    openrouter_api_key,
)


STASH_LABEL = "issue-agent-autostash"


def prompt(message: str) -> str:
    try:
        return input(message).strip()
    except (EOFError, KeyboardInterrupt):
        print()
        sys.exit(0)


def ensure_clean_worktree() -> bool:
    """Aider commits tracked changes, so the worktree must be clean.

    Untracked files are fine and ignored. Tracked changes are stashed (with
    consent) and restored when the agent exits. Returns True if a stash was made.
    """
    changes = gitops.tracked_changes()
    if not changes:
        return False

    print("\nTracked changes present (Aider would commit these):")
    for line in changes:
        print(f"  {line}")
    answer = prompt(
        "\nStash them now and restore on exit? (y = stash, n = abort): "
    ).lower()
    if answer != "y":
        print("Aborting. Commit or stash your changes, then re-run.")
        sys.exit(1)

    gitops.stash_push(STASH_LABEL)
    print("Changes stashed.")
    return True


def restore_worktree(stashed: bool) -> None:
    if not stashed:
        return
    try:
        gitops.checkout(BASE_BRANCH)
        gitops.stash_pop()
        print(f"\nRestored stashed changes onto '{BASE_BRANCH}'.")
    except gitops.GitError as error:
        print(f"\nCould not auto-restore stash: {error}\n"
              f"Run 'git stash list' / 'git stash pop' manually (label: {STASH_LABEL}).")


def choose_issue(issues: list):
    print("\nOpen issues:")
    for index, issue in enumerate(issues, start=1):
        labels = ", ".join(issue.label_names)
        suffix = f"  [{labels}]" if labels else ""
        print(f"  {index:>2}. #{issue.number} {issue.title}{suffix}")
    print("   q. quit")

    while True:
        choice = prompt("\nPick an issue number (list index, or 'q'): ")
        if choice.lower() == "q":
            return None
        if choice.isdigit():
            idx = int(choice)
            if 1 <= idx <= len(issues):
                return issues[idx - 1]
        print("Invalid choice.")


def build_with_fixes() -> builder.BuildResult:
    result = builder.build()
    attempts = 0
    while not result.succeeded and attempts < MAX_BUILD_FIX_ATTEMPTS:
        attempts += 1
        print(f"\nBuild failed (attempt {attempts}/{MAX_BUILD_FIX_ATTEMPTS}). "
              f"Asking the model to fix it. Log: {result.log_path}")
        coder.fix_build(builder.build_error_summary(result))
        result = builder.build()
    return result


def handle_issue(issue) -> None:
    branch = gitops.create_issue_branch(issue.number, issue.title, BASE_BRANCH)
    print(f"\nWorking on #{issue.number} on branch '{branch}'.")

    print("\nImplementing with the model...")
    coder.implement_issue(issue.number, issue.title, issue.body)

    while True:
        result = build_with_fixes()
        if not result.succeeded:
            print(f"\nStill failing to build. See log: {result.log_path}")
            action = prompt("Provide more guidance (g), skip this issue (s): ").lower()
            if action == "g":
                feedback = prompt("Your guidance: ")
                if feedback:
                    coder.apply_feedback(feedback)
                continue
            print("Skipping issue. Branch left as-is for inspection.")
            gitops.checkout(BASE_BRANCH)
            return

        app_path = builder.deliver_app(issue.number)
        print(f"\nBuild OK. Test the app (double-click to run):\n  {app_path}")

        decision = prompt(
            "\nApprove and open PR (a), request changes (c), skip (s): "
        ).lower()

        if decision == "a":
            if not gitops.has_commits_since(BASE_BRANCH):
                print("No commits on this branch; nothing to open a PR for.")
                gitops.checkout(BASE_BRANCH)
                return
            gitops.push_branch(branch)
            pr_url = github.create_pull_request(
                branch=branch,
                title=f"Fix #{issue.number}: {issue.title}",
                body=(
                    f"Implements upstream issue {UPSTREAM_REPO}#{issue.number}\n\n"
                    f"{issue.title}\n\n{issue.url}"
                ),
                base=BASE_BRANCH,
            )
            print(f"\nPR created: {pr_url}")
            gitops.checkout(BASE_BRANCH)
            return

        if decision == "c":
            feedback = prompt("Describe the changes you want: ")
            if feedback:
                coder.apply_feedback(feedback)
            continue

        print("Skipping issue. Branch left as-is for inspection.")
        gitops.checkout(BASE_BRANCH)
        return


def main() -> None:
    try:
        openrouter_api_key()
    except ConfigError as error:
        print(f"Configuration error: {error}")
        sys.exit(1)

    stashed = ensure_clean_worktree()

    if gitops.current_branch() != BASE_BRANCH:
        print(f"Note: current branch is '{gitops.current_branch()}', "
              f"issue branches will be created from '{BASE_BRANCH}'.")

    print("Loading open issues from GitHub...")
    issues = github.list_open_issues()
    if not issues:
        print("No open issues found.")
        restore_worktree(stashed)
        return

    try:
        while True:
            issue = choose_issue(issues)
            if issue is None:
                print("Bye.")
                return
            handle_issue(issue)
    finally:
        restore_worktree(stashed)


if __name__ == "__main__":
    main()
