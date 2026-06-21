import re
import subprocess

from config import REPO_ROOT


class GitError(Exception):
    pass


def _run(args: list) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise GitError(f"git {' '.join(args)} failed:\n{result.stderr.strip()}")
    return result.stdout.strip()


def tracked_changes() -> list:
    """Modified or staged tracked files (untracked files are ignored)."""
    output = _run(["status", "--porcelain", "--untracked-files=no"])
    return [line for line in output.splitlines() if line.strip()]


def is_clean() -> bool:
    return tracked_changes() == []


def stash_push(label: str) -> bool:
    if is_clean():
        return False
    # Default stash excludes untracked files, which is what we want.
    _run(["stash", "push", "-m", label])
    return True


def stash_pop() -> None:
    _run(["stash", "pop"])


def current_branch() -> str:
    return _run(["rev-parse", "--abbrev-ref", "HEAD"])


def checkout(branch: str) -> None:
    _run(["checkout", branch])


def slugify(text: str, max_len: int = 40) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return slug[:max_len].strip("-") or "issue"


def create_issue_branch(number: int, title: str, base: str) -> str:
    branch = f"issue-{number}-{slugify(title)}"
    existing = _run(["branch", "--list", branch])
    if existing:
        _run(["checkout", branch])
    else:
        _run(["checkout", "-b", branch, base])
    return branch


def push_branch(branch: str) -> None:
    _run(["push", "-u", "origin", branch])


def has_commits_since(base: str) -> bool:
    return _run(["rev-list", f"{base}..HEAD", "--count"]) != "0"
