import os
from pathlib import Path


class ConfigError(Exception):
    pass


REPO_ROOT = Path(__file__).resolve().parent.parent
AGENT_DIR = REPO_ROOT / "agent"
ENV_FILE = AGENT_DIR / ".env"

MODEL = "openrouter/deepseek/deepseek-v4-flash"
BASE_BRANCH = "master"

# CA bundle used by aider's HTTP client (this Python build ships without one).
CA_BUNDLE = "/etc/ssl/cert.pem"

BUILD_APP_PATH = REPO_ROOT / "build" / "Build" / "Products" / "Debug" / "OpenSuperWhisper.app"
ISSUES_DIR = REPO_ROOT / "issues"
LOG_DIR = AGENT_DIR / "logs"

MAX_BUILD_FIX_ATTEMPTS = 3


def _load_env_file() -> None:
    if not ENV_FILE.exists():
        return
    for raw in ENV_FILE.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


def openrouter_api_key() -> str:
    _load_env_file()
    key = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if not key:
        raise ConfigError(
            f"OPENROUTER_API_KEY is not set. Add it to {ENV_FILE} or the environment."
        )
    return key
