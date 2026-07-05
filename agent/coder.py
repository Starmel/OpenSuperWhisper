import os
import subprocess
from pathlib import Path

from config import CA_BUNDLE, MODEL, REPO_ROOT, openrouter_api_key


class CoderError(Exception):
    pass


def _aider_executable() -> str:
    venv_aider = REPO_ROOT / "agent" / ".venv" / "bin" / "aider"
    if venv_aider.exists():
        return str(venv_aider)
    return "aider"


def run_aider(message: str) -> int:
    env = dict(os.environ)
    env["OPENROUTER_API_KEY"] = openrouter_api_key()
    if Path(CA_BUNDLE).exists():
        env.setdefault("SSL_CERT_FILE", CA_BUNDLE)
        env.setdefault("REQUESTS_CA_BUNDLE", CA_BUNDLE)

    args = [
        _aider_executable(),
        "--model", MODEL,
        "--yes-always",
        "--no-show-model-warnings",
        "--no-check-update",
        "--no-analytics",
        "--message", message,
    ]
    result = subprocess.run(args, cwd=REPO_ROOT, env=env)
    if result.returncode != 0:
        raise CoderError(f"aider exited with code {result.returncode}")
    return result.returncode


def implement_issue(number: int, title: str, body: str) -> None:
    message = (
        f"Implement GitHub issue #{number}: {title}\n\n"
        f"{body}\n\n"
        "Make the minimal, correct change in the Swift sources to resolve this issue. "
        "Do not add unrelated changes."
    )
    run_aider(message)


def apply_feedback(feedback: str) -> None:
    run_aider(
        "The previous change needs revision. Apply this feedback precisely:\n\n"
        + feedback
    )


def fix_build(build_log: str) -> None:
    run_aider(
        "The macOS build failed after your last change. Fix the code so it compiles. "
        "Here is the relevant build output:\n\n"
        + build_log
    )
