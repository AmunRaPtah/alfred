"""Automatic cross-session memory capture.

Periodically scans sessions for ones that have gone idle (no meta.json update
for AUTOCAPTURE_IDLE_SECONDS) and have new user/assistant text since the last
capture (tracked by `memory_seq` in meta.json, so nothing is processed
twice). The new text is sent to a cheap extraction model (local LiteLLM
proxy, see config.AUTOCAPTURE_*) asking for durable facts about the owner;
each returned fact is appended via memory.remember with rough de-duplication
against what is already stored.

Failures (LLM unreachable, bad JSON, etc.) are logged and swallowed; this is
a best-effort background enrichment, never something that should disturb a
live session or the tmux/harness flow.
"""
import json
import logging
import re
import threading
import time

import httpx

from . import config, memory, sessionio

log = logging.getLogger("alfredd.autocapture")

EXTRACT_SYSTEM_PROMPT = (
    "You extract durable facts about a person (the owner of an AI assistant) "
    "from a transcript snippet, for long-term memory across sessions. "
    "Return ONLY a JSON array of short strings, each one self-contained fact "
    "(preferences, people, relationships, dates/deadlines, decisions, ongoing "
    "projects). Exclude: one-off chatter with no lasting relevance, anything "
    "that looks like it is already common knowledge or already stored, "
    "secrets/passwords/API keys/tokens, health or medical details, "
    "government ID numbers, financial account numbers, and never include a "
    "pharmacy/PCN licence number. If nothing durable is present, return []. "
    "Respond with ONLY the JSON array, no prose, no markdown fences."
)

_JSON_ARRAY_RE = re.compile(r"\[.*\]", re.S)


def _http_client() -> httpx.Client:
    """One place to build the outbound client, so tests can monkeypatch it."""
    return httpx.Client(timeout=httpx.Timeout(20.0, connect=5.0))


def _session_text(sid: str, after_seq: int) -> tuple:
    """Returns (text, last_seq) for user/assistant events after `after_seq`,
    capped at config.AUTOCAPTURE_MAX_INPUT_CHARS (oldest trimmed first)."""
    events = sessionio.read_events(sid, after=after_seq, limit=100000)
    last_seq = after_seq
    lines = []
    for ev in events:
        last_seq = max(last_seq, ev.get("seq", last_seq))
        t = ev.get("type")
        text = ev.get("text")
        if t in ("user", "assistant") and isinstance(text, str) and text.strip():
            who = "User" if t == "user" else "Assistant"
            lines.append(f"{who}: {text.strip()}")
    blob = "\n".join(lines)
    if len(blob) > config.AUTOCAPTURE_MAX_INPUT_CHARS:
        blob = blob[-config.AUTOCAPTURE_MAX_INPUT_CHARS:]
    return blob, last_seq


def extract_facts(transcript: str, client: httpx.Client = None) -> list:
    """Calls the extraction model and returns a list of fact strings. Raises
    on failure (network, bad status, unparseable JSON); callers decide how
    to handle that; sweep_once() logs and moves on."""
    if not transcript.strip():
        return []
    body = {
        "model": config.AUTOCAPTURE_MODEL,
        "messages": [
            {"role": "system", "content": EXTRACT_SYSTEM_PROMPT},
            {"role": "user", "content": transcript},
        ],
        "max_tokens": 500,
        "temperature": 0,
    }
    headers = {"content-type": "application/json",
               "authorization": f"Bearer {config.AUTOCAPTURE_KEY}"}
    owns_client = client is None
    client = client or _http_client()
    try:
        r = client.post(config.AUTOCAPTURE_URL, json=body, headers=headers)
        r.raise_for_status()
        content = r.json()["choices"][0]["message"]["content"]
    finally:
        if owns_client:
            client.close()
    m = _JSON_ARRAY_RE.search(content)
    raw = m.group(0) if m else content
    facts = json.loads(raw)
    if not isinstance(facts, list):
        raise ValueError(f"expected a JSON list, got {type(facts)}")
    return [f.strip() for f in facts if isinstance(f, str) and f.strip()]


def _already_known(fact: str, existing_lower: str) -> bool:
    """Rough de-dupe: skip a fact if a good chunk of it already appears
    verbatim in current memory text."""
    norm = fact.strip().lower()
    if not norm:
        return True
    if norm in existing_lower:
        return True
    # Loose containment on the long tail of the sentence (drops leading
    # connective words like "the"/"owner is"/etc. having little effect).
    words = norm.split()
    if len(words) >= 6:
        tail = " ".join(words[2:])
        if tail and tail in existing_lower:
            return True
    return False


def capture_new_facts(facts: list) -> list:
    """Appends facts not already present in memory, returns the ones added."""
    existing_lower = memory.read().lower()
    added = []
    for fact in facts:
        if _already_known(fact, existing_lower):
            continue
        memory.remember(fact)
        existing_lower += "\n" + fact.lower()
        added.append(fact)
    return added


def process_session(sid: str, meta: dict, client: httpx.Client = None) -> list:
    """Extracts and stores new facts for one session; advances its
    memory_seq cursor on success. Returns the list of facts added (possibly
    empty). Raises nothing; logs and returns [] on any failure."""
    cursor = meta.get("memory_seq", 0)
    last_seq = meta.get("last_seq", 0)
    if last_seq <= cursor:
        return []
    text, new_cursor = _session_text(sid, cursor)
    if not text.strip():
        sessionio.update_meta(sid, memory_seq=last_seq)
        return []
    try:
        facts = extract_facts(text, client=client)
    except Exception as e:
        log.warning("autocapture: extraction failed for session %s: %s", sid, e)
        return []
    added = capture_new_facts(facts)
    sessionio.update_meta(sid, memory_seq=max(new_cursor, last_seq))
    return added


def _is_idle(meta: dict, now: float) -> bool:
    updated = meta.get("updated") or 0
    return (now - updated) >= config.AUTOCAPTURE_IDLE_SECONDS


def sweep_once() -> list:
    """Scans all sessions, processing any that are idle with unprocessed
    text. Returns the list of {"sid", "added"} results for sessions that
    had new facts captured."""
    results = []
    if not config.SESSIONS_DIR.exists():
        return results
    now = time.time()
    with _http_client() as client:
        for d in config.SESSIONS_DIR.iterdir():
            if not d.is_dir():
                continue
            sid = d.name
            meta = sessionio.read_meta(sid)
            if not meta or not _is_idle(meta, now):
                continue
            try:
                added = process_session(sid, meta, client=client)
            except Exception as e:
                log.warning("autocapture: sweep failed for session %s: %s", sid, e)
                continue
            if added:
                results.append({"sid": sid, "added": added})
    return results


def loop_forever():
    while True:
        try:
            if config.AUTOCAPTURE_ENABLED:
                sweep_once()
        except Exception as e:
            log.warning("autocapture: sweep loop error: %s", e)
        time.sleep(config.AUTOCAPTURE_INTERVAL_SECONDS)


def start_background():
    if not config.AUTOCAPTURE_ENABLED:
        return
    threading.Thread(target=loop_forever, name="alfred-autocapture", daemon=True).start()
