import os
import secrets
from pathlib import Path

ALFRED_HOME = Path(os.environ.get("ALFRED_HOME", Path.home() / ".alfred"))
SESSIONS_DIR = ALFRED_HOME / "sessions"
TOKEN_FILE = ALFRED_HOME / "token"
DB_PATH = ALFRED_HOME / "alfred.db"
APNS_CONFIG_FILE = ALFRED_HOME / "apns.json"
TELEGRAM_CONFIG_FILE = ALFRED_HOME / "telegram.json"
MEMORY_FILE = ALFRED_HOME / "MEMORY.md"
MEMORY_MAX_CHARS = 4000

BIND_HOST = "10.66.66.1"
BIND_PORT = 3341

ALFRED_RUNNER = str(Path(__file__).resolve().parent.parent / "alfred-runner")

# Hook for a future on-box TPU inference endpoint. Unused today: alfred-brain
# always runs against the Kaggle-hosted abliterated Qwen3.8-27B via
# claude-burst. Once a TPU endpoint exists, alfred-brain will prefer it when
# this is set.
ALFRED_TPU_URL = os.environ.get("ALFRED_TPU_URL")


def ensure_dirs():
    SESSIONS_DIR.mkdir(parents=True, exist_ok=True)


def ensure_token() -> str:
    """Generate ~/.alfred/token (32 random url-safe bytes) if missing,
    chmod 600, and return its contents."""
    ALFRED_HOME.mkdir(parents=True, exist_ok=True)
    if not TOKEN_FILE.exists():
        TOKEN_FILE.write_text(secrets.token_urlsafe(32))
        TOKEN_FILE.chmod(0o600)
    return TOKEN_FILE.read_text().strip()


def load_token() -> str:
    if not TOKEN_FILE.exists():
        raise RuntimeError(f"token file missing: {TOKEN_FILE}")
    return TOKEN_FILE.read_text().strip()


def session_dir(sid: str) -> Path:
    return SESSIONS_DIR / sid


def meta_path(sid: str) -> Path:
    return session_dir(sid) / "meta.json"


def events_path(sid: str) -> Path:
    return session_dir(sid) / "events.jsonl"


def inbox_path(sid: str) -> Path:
    return session_dir(sid) / "inbox"


def uploads_dir(sid: str) -> Path:
    return session_dir(sid) / "uploads"
