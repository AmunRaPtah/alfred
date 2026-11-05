"""Fast voice turns: a direct, streamed chat completion that answers in a few
spoken sentences, bypassing the harness. Anything needing tools is handed to
the session's harness via an `[[ACT: task]]` tag in the reply.

Backends come from ~/.alfred/voice.json, tried in order:
  {"backends": [{"name", "url", "model", "key" | "key_file", "health"?}, ...]}
`url` is an OpenAI-compatible base (e.g. http://127.0.0.1:4000/v1); requests
go to `{url}/chat/completions` with stream=true.
"""
import json
import re
from pathlib import Path
from typing import AsyncIterator, Optional

import httpx

from . import adapters, config, memory, sessionio

HEALTH_TIMEOUT = 1.5
CONNECT_TIMEOUT = 5.0
READ_TIMEOUT = 30.0
MAX_TOKENS = 300
HISTORY_TURNS = 10
HISTORY_TURN_CHARS = 1000

ACK_SENTENCE = "On it, I'll tell you when it's done."

SYSTEM_PROMPT = (
    "You are Alfred, the owner's loyal, discreet and capable butler and chief of "
    "staff, speaking aloud by voice. Answer in 1-3 short spoken sentences. No "
    "markdown, no lists, no code, no headings, no emoji; plain speech only. "
    "If the user asks you to DO something that needs tools — files, email "
    "drafts, web lookups, reminders, running code — reply with one short "
    "acknowledgement sentence and end with the tag [[ACT: <concise task "
    "description>]]."
)

_ACT_RE = re.compile(r"\[\[\s*ACT:\s*(.*?)\s*\]\]", re.S)
_THINK_BLOCK = re.compile(r"<think>.*?</think>", re.S)
# Sentence end: one or more of .!? plus optional closing quotes/brackets,
# followed by whitespace. End-of-stream is handled by flush().
_BOUNDARY = re.compile(r"[.!?]+[\"'”’)\]]*(?=\s)")
_ABBREV = {"mr", "mrs", "ms", "dr", "st", "sr", "jr", "prof", "vs", "etc",
           "e.g", "i.e", "no", "approx", "inc", "ltd", "co", "mt", "fig", "u.s"}


class NoBackend(Exception):
    pass


def http_client(timeout: Optional[httpx.Timeout] = None) -> httpx.AsyncClient:
    """One place to build the outbound client, so tests can swap in a
    MockTransport."""
    return httpx.AsyncClient(timeout=timeout or httpx.Timeout(READ_TIMEOUT, connect=CONNECT_TIMEOUT))


# ---------- prompt ----------

def _history(sid: str) -> list:
    msgs = []
    for ev in sessionio.read_events(sid, after=0, limit=100000):
        t = ev.get("type")
        if t in ("user", "assistant") and isinstance(ev.get("text"), str) and ev["text"].strip():
            text = adapters.strip_leaked_reasoning(ev["text"]) if t == "assistant" else ev["text"]
            msgs.append({"role": t, "content": text.strip()[:HISTORY_TURN_CHARS]})
    return msgs[-HISTORY_TURNS:]


def build_messages(sid: str, text: str) -> list:
    system = SYSTEM_PROMPT
    mem = memory.read().strip()
    if mem:
        system += "\n\nWhat you remember about the owner:\n" + mem[-config.MEMORY_MAX_CHARS:]
    return [{"role": "system", "content": system}, *_history(sid),
            {"role": "user", "content": text}]


# ---------- backends ----------

def load_backends() -> list:
    p = config.VOICE_CONFIG_FILE
    if not p.exists():
        return []
    try:
        return list(json.loads(p.read_text()).get("backends") or [])
    except (OSError, ValueError):
        return []


def _backend_key(b: dict) -> Optional[str]:
    if b.get("key_file"):
        return Path(b["key_file"]).expanduser().read_text().strip()
    return b.get("key")


async def _healthy(client: httpx.AsyncClient, url: str) -> bool:
    try:
        r = await client.get(url, timeout=HEALTH_TIMEOUT)
        return r.status_code == 200
    except Exception:
        return False


async def _stream_backend(client: httpx.AsyncClient, b: dict, key: Optional[str],
                          messages: list) -> AsyncIterator[str]:
    headers = {"content-type": "application/json"}
    if key:
        headers["authorization"] = f"Bearer {key}"
    body = {"model": b["model"], "messages": messages, "stream": True,
            "max_tokens": MAX_TOKENS}
    url = b["url"].rstrip("/") + "/chat/completions"
    async with client.stream("POST", url, json=body, headers=headers) as r:
        if r.status_code != 200:
            detail = (await r.aread())[:300].decode(errors="replace")
            raise RuntimeError(f"HTTP {r.status_code}: {detail}")
        async for line in r.aiter_lines():
            line = line.strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            try:
                chunk = json.loads(data)
            except ValueError:
                continue
            for choice in chunk.get("choices") or []:
                piece = (choice.get("delta") or {}).get("content")
                if piece:
                    yield piece


async def stream_reply(messages: list, errors: list):
    """Yields (backend_name, token) pairs from the first backend that
    produces a token. A backend that fails before its first token is skipped
    (reason appended to `errors`); a failure after that propagates."""
    async with http_client() as client:
        for b in load_backends():
            name = b.get("name") or b.get("url", "?")
            if b.get("health") and not await _healthy(client, b["health"]):
                errors.append(f"{name}: health check failed")
                continue
            try:
                key = _backend_key(b)
            except OSError as e:
                errors.append(f"{name}: key file unreadable ({e.__class__.__name__})")
                continue
            started = False
            try:
                async for tok in _stream_backend(client, b, key, messages):
                    started = True
                    yield name, tok
            except Exception as e:
                if started:
                    raise
                errors.append(f"{name}: {e.__class__.__name__}: {e}"[:300])
                continue
            if started:
                return
            errors.append(f"{name}: empty reply")
    raise NoBackend("; ".join(errors) or "no voice backends configured")


# ---------- text shaping ----------

def visible_text(raw: str) -> str:
    """The speakable part of the reply so far: reasoning and ACT tags removed,
    and anything after an unclosed `<think>` or `[[` held back."""
    text = raw
    if "think>" in text:
        text = _THINK_BLOCK.sub("", text)
        if "</think>" in text:
            text = text.rsplit("</think>", 1)[1]
        if "<think>" in text:
            text = text.split("<think>", 1)[0]
    text = _ACT_RE.sub("", text)
    if "[[" in text:
        text = text.split("[[", 1)[0]
    return text


def find_action(raw: str) -> Optional[str]:
    text = adapters.strip_leaked_reasoning(raw)
    m = _ACT_RE.search(text)
    return m.group(1).strip() if m and m.group(1).strip() else None


class SentenceSplitter:
    """Feed it the growing visible text; it returns newly completed sentences."""

    def __init__(self):
        self.pos = 0

    def feed(self, visible: str) -> list:
        out = []
        self.pos = min(self.pos, len(visible))
        start = self.pos
        for m in _BOUNDARY.finditer(visible, self.pos):
            words = visible[start:m.end()].split()
            last = words[-1].rstrip("\"'”’)]").lower() if words else ""
            if last.endswith(".") and not last.endswith(".."):
                stem = last.rstrip(".")
                if stem in _ABBREV or (len(stem) == 1 and stem.isalpha()):
                    continue
            sentence = visible[start:m.end()].strip()
            if sentence:
                out.append(sentence)
            start = m.end()
        self.pos = start
        return out

    def flush(self, visible: str) -> list:
        rest = visible[self.pos:].strip()
        self.pos = len(visible)
        return [rest] if rest else []


def tidy(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def sse(event: str, data: dict) -> str:
    return f"event: {event}\ndata: {json.dumps(data)}\n\n"
