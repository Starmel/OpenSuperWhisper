import json
import subprocess
from dataclasses import dataclass

from config import FORK_REPO, REPO_ROOT, UPSTREAM_REPO


class GitHubError(Exception):
    pass


@dataclass
class Issue:
    number: int
    title: str
    body: str
    url: str
    labels: list

    @property
    def label_names(self) -> list:
        return [label.get("name", "") for label in self.labels]


def _run(args: list) -> str:
    result = subprocess.run(
        args,
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise GitHubError(f"command failed: {' '.join(args)}\n{result.stderr.strip()}")
    return result.stdout


def list_open_issues(limit: int = 50) -> list:
    raw = _run([
        "gh", "issue", "list",
        "--repo", UPSTREAM_REPO,
        "--state", "open",
        "--limit", str(limit),
        "--json", "number,title,body,labels,url",
    ])
    data = json.loads(raw)
    return [
        Issue(
            number=item["number"],
            title=item["title"],
            body=item.get("body") or "",
            url=item["url"],
            labels=item.get("labels") or [],
        )
        for item in data
    ]


def create_pull_request(branch: str, title: str, body: str, base: str) -> str:
    raw = _run([
        "gh", "pr", "create",
        "--repo", FORK_REPO,
        "--base", base,
        "--head", branch,
        "--title", title,
        "--body", body,
    ])
    return raw.strip()
