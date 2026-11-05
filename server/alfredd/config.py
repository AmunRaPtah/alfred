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
# Fast voice turns (POST /voice/turn): ordered OpenAI-compatible backends.
VOICE_CONFIG_FILE = ALFRED_HOME / "voice.json"
# TTS proxy (POST /tts, GET /tts/voices): {"url","key","default_engine","default_voice"}.
TTS_CONFIG_FILE = ALFRED_HOME / "tts.json"

BIND_HOST = "10.66.66.1"
BIND_PORT = 3341

# Default session cwd. Must sit outside /root: Claude Code loads CLAUDE.md and
# .claude/settings*.json from every ancestor of the cwd, and /root/CLAUDE.md is
# the operator's own Claude Code brief (vault, AXI, token rules), not Alfred's.
# Verified 2026-11-05: a session in /root saw it, one in /tmp did not.
WORKSPACE = os.environ.get("ALFRED_WORKSPACE", "/srv/alfred")
# cwd values older app builds send by default; remapped to WORKSPACE.
LEGACY_WORKSPACES = {"/root/projects/alfred/workspace", "/root", str(Path.home())}

ALFRED_RUNNER = str(Path(__file__).resolve().parent.parent / "alfred-runner")

# Kaggle TPU (qwen122-tpu) tunnel base URL. alfred-brain health-checks it and
# uses the TPU model when it answers; otherwise the brain is off (no T4
# fallback, to spare Kaggle GPU quota; ALFRED_ALLOW_T4=1 re-enables it).
# Default there is http://127.0.0.1:8193.
ALFRED_TPU_URL = os.environ.get("ALFRED_TPU_URL")

# Cross-session memory auto-capture (server/alfredd/autocapture.py): on by
# default, disable with ALFRED_AUTOCAPTURE=0. Uses the local LiteLLM proxy
# (same one voice.py's litellm-deepseek-v4-flash backend talks to); that
# proxy accepts any bearer token locally, so "sk-none" matches voice.json.
AUTOCAPTURE_ENABLED = os.environ.get("ALFRED_AUTOCAPTURE", "1") != "0"
AUTOCAPTURE_URL = os.environ.get("ALFRED_AUTOCAPTURE_URL", "http://127.0.0.1:4000/v1/chat/completions")
AUTOCAPTURE_MODEL = os.environ.get("ALFRED_AUTOCAPTURE_MODEL", "kbench-gemini-flash-lite")
AUTOCAPTURE_KEY = os.environ.get("ALFRED_AUTOCAPTURE_KEY", "sk-none")
AUTOCAPTURE_IDLE_SECONDS = 600  # a session is "idle" 10 minutes after its last update
AUTOCAPTURE_INTERVAL_SECONDS = 300  # periodic sweep cadence
AUTOCAPTURE_MAX_INPUT_CHARS = 6000  # cap on transcript text sent to the extraction model


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
