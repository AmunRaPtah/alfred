"""Cross-session memory for Alfred: a flat facts list at ~/.alfred/MEMORY.md,
newest entries last so a simple tail-truncation keeps the most recent facts
when the file grows past MEMORY_MAX_CHARS. alfred-brain reads this file and
injects it into the system prompt at launch (see /root/.local/bin/alfred-brain).
"""
from datetime import datetime, timezone

from . import config

_HEADER = "# Alfred memory\n\nFacts the owner has told Alfred to remember, oldest first.\n\n"


def read() -> str:
    if not config.MEMORY_FILE.exists():
        return ""
    return config.MEMORY_FILE.read_text()


def _trim(text: str) -> str:
    """Keeps the newest content when over the cap: drop whole lines from the
    front (after the header) until it fits, never truncate mid-line."""
    if len(text) <= config.MEMORY_MAX_CHARS:
        return text
    lines = text.splitlines(keepends=True)
    # Keep the header (first paragraph) and drop oldest fact lines after it.
    header_end = 0
    for i, line in enumerate(lines):
        if line.strip() == "" and i > 0:
            header_end = i + 1
            break
    header = "".join(lines[:header_end])
    body = lines[header_end:]
    while body and len(header) + sum(len(l) for l in body) > config.MEMORY_MAX_CHARS:
        body.pop(0)
    return header + "".join(body)


def write(text: str) -> str:
    config.ALFRED_HOME.mkdir(parents=True, exist_ok=True)
    text = _trim(text)
    config.MEMORY_FILE.write_text(text)
    config.MEMORY_FILE.chmod(0o600)
    return text


def remember(fact: str) -> str:
    """Appends one fact as a dated bullet, then trims from the oldest end."""
    existing = read()
    if not existing:
        existing = _HEADER
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    line = f"- [{stamp}] {fact.strip()}\n"
    return write(existing + line)
