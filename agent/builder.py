import shutil
import subprocess
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from config import BUILD_APP_PATH, ISSUES_DIR, LOG_DIR, REPO_ROOT


class BuildError(Exception):
    pass


@dataclass
class BuildResult:
    succeeded: bool
    log_path: Path
    log_text: str


def _extract_errors(log_text: str) -> str:
    error_lines = [
        line for line in log_text.splitlines()
        if "error:" in line.lower() or "BUILD FAILED" in line
    ]
    if not error_lines:
        return "\n".join(log_text.splitlines()[-60:])
    return "\n".join(error_lines[:60])


def build() -> BuildResult:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    log_path = LOG_DIR / f"build-{timestamp}.log"

    with open(log_path, "w") as log_file:
        result = subprocess.run(
            ["./run.sh", "build"],
            cwd=REPO_ROOT,
            stdout=log_file,
            stderr=subprocess.STDOUT,
        )

    log_text = log_path.read_text(errors="replace")
    succeeded = result.returncode == 0 and "BUILD FAILED" not in log_text
    return BuildResult(succeeded=succeeded, log_path=log_path, log_text=log_text)


def build_error_summary(result: BuildResult) -> str:
    return _extract_errors(result.log_text)


def deliver_app(issue_number: int) -> Path:
    if not BUILD_APP_PATH.exists():
        raise BuildError(f"built app not found at {BUILD_APP_PATH}")

    dest_dir = ISSUES_DIR / str(issue_number)
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest_app = dest_dir / BUILD_APP_PATH.name

    if dest_app.exists():
        shutil.rmtree(dest_app)
    shutil.copytree(BUILD_APP_PATH, dest_app)
    return dest_app
