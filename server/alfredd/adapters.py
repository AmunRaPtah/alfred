"""Command building and NDJSON event parsing for the `alfred` harness.

alfredd has exactly one harness: `alfred`, launched by
`/root/.local/bin/alfred-brain`. That launcher ends in `exec claude-burst
... "$@"` (same pattern as helmd's glm/dsv/sukuna launchers), so it emits the
same claude `-p --input-format stream-json --output-format stream-json
--verbose --include-partial-messages` NDJSON shape once this module appends
the stream flags. One parser (`claude_parse`, copied verbatim from helmd's
adapters.py) therefore covers it; see helmd's adapters.py docstring for the
shapes this was verified against on 2026-10-18.
"""
import base64
import re
import json
import mimetypes
import os
from pathlib import Path

from . import config

PERMISSION_MAP_CLAUDE = {
    "bypass": "bypassPermissions",
    "acceptEdits": "acceptEdits",
    "default": "default",
    "plan": "plan",
}


def _image_block(path):
    mt, _ = mimetypes.guess_type(path)
    mt = mt or "application/octet-stream"
    with open(path, "rb") as f:
        data = base64.b64encode(f.read()).decode()
    return {"type": "image", "source": {"type": "base64", "media_type": mt, "data": data}}


def _is_image(path):
    mt, _ = mimetypes.guess_type(path)
    return bool(mt and mt.startswith("image/"))


# Stream-json flags the claude-family harness needs, identical to helmd's.
_STREAM_FLAGS = ["-p", "--input-format", "stream-json", "--output-format",
                 "stream-json", "--verbose", "--include-partial-messages"]

LAUNCHER = "/root/.local/bin/alfred-brain"


def _sandbox_env():
    return {"IS_SANDBOX": "1"} if os.geteuid() == 0 else {}


def claude_cmd(meta):
    cmd = [LAUNCHER] + _STREAM_FLAGS + [
        "--permission-mode",
        PERMISSION_MAP_CLAUDE.get(meta["permission"], "bypassPermissions")]
    if meta.get("native_session_id"):
        cmd += ["--resume", meta["native_session_id"]]
    # The model is fixed by alfred-brain (Kaggle-hosted Qwen3.8-27B, or a TPU
    # endpoint later); ignore any meta["model"].
    return cmd, _sandbox_env()


def claude_input_line(text, attachments):
    content = [{"type": "text", "text": text}]
    for a in attachments or []:
        if _is_image(a):
            content.append(_image_block(a))
        else:
            content[0]["text"] += f"\n[attached file: {a}]"
    return json.dumps({"type": "user", "message": {"role": "user", "content": content}}) + "\n"


def claude_parse(obj):
    """Return list of normalized event dicts (no seq/ts) and an optional
    native_session_id update, from one raw NDJSON line of the alfred harness."""
    events = []
    native_id = None
    t = obj.get("type")
    if t == "system" and obj.get("subtype") == "init":
        native_id = obj.get("session_id")
        events.append({"type": "system", "text": f"session started (model={obj.get('model') or 'default'})"})
        if obj.get("slash_commands"):
            events.append({"type": "_meta", "fields": {"commands": obj["slash_commands"]}})
    elif t == "system" and obj.get("subtype", "").startswith("hook_"):
        pass  # local plugin noise, not protocol
    elif t == "stream_event":
        ev = obj.get("event", {})
        if ev.get("type") == "content_block_delta":
            delta = ev.get("delta", {})
            if delta.get("type") == "text_delta" and delta.get("text"):
                msg_id = obj.get("message_id") or obj.get("parent_tool_use_id") or "stream"
                events.append({"type": "assistant_delta", "msg_id": msg_id, "text": delta["text"]})
    elif t == "assistant":
        msg = obj.get("message", {})
        msg_id = msg.get("id", "?")
        text_parts = []
        for block in msg.get("content", []) or []:
            if block.get("type") == "text":
                text_parts.append(block.get("text", ""))
            elif block.get("type") == "tool_use":
                events.append({"type": "tool_call", "call_id": block.get("id", "?"),
                                "name": block.get("name", "?"),
                                "input": json.dumps(block.get("input", {}), indent=1)})
        if obj.get("error"):
            events.append({"type": "error", "text": "".join(text_parts) or obj["error"]})
        elif text_parts:
            events.append({"type": "assistant", "msg_id": msg_id, "text": "".join(text_parts)})
    elif t == "user":
        msg = obj.get("message", {})
        for block in msg.get("content", []) or []:
            if block.get("type") == "tool_result":
                out = block.get("content")
                if isinstance(out, list):
                    out = "".join(b.get("text", "") for b in out if isinstance(b, dict))
                out = str(out or "")[:4000]
                events.append({"type": "tool_result", "call_id": block.get("tool_use_id", "?"),
                                "output": out, "is_error": bool(block.get("is_error"))})
    elif t == "result":
        usage = obj.get("usage", {}) or {}
        events.append({"type": "usage",
                        "input_tokens": usage.get("input_tokens", 0),
                        "output_tokens": usage.get("output_tokens", 0),
                        "cost_usd": obj.get("total_cost_usd")})
        if obj.get("is_error"):
            events.append({"type": "error", "text": obj.get("result") or "turn errored"})
        elif isinstance(obj.get("result"), str):
            events.append({"type": "_result_text", "text": obj["result"]})
    return events, native_id


# ------------------------------------------------------------ slash commands

CLAUDE_BUILTINS = ["compact", "context", "cost", "init", "review", "security-review"]


def _commands_cache(harness):
    return config.ALFRED_HOME / f"commands-{harness}.json"


def save_commands(harness, commands):
    try:
        _commands_cache(harness).write_text(json.dumps(commands))
    except OSError:
        pass


def known_commands(meta):
    if meta["harness"] not in LONG_LIVED:
        return []
    if meta.get("commands"):
        return meta["commands"]
    try:
        return json.loads(_commands_cache(meta["harness"]).read_text())
    except (OSError, ValueError):
        pass
    skills = Path.home() / ".claude" / "skills"
    names = sorted(p.name for p in skills.iterdir() if (p / "SKILL.md").exists()) if skills.is_dir() else []
    return CLAUDE_BUILTINS + names


LONG_LIVED = {"alfred"}


_THINK_BLOCK = re.compile(r"<think>.*?</think>", re.S)


def strip_leaked_reasoning(text: str) -> str:
    """Drop chain-of-thought the model let into its reply.

    Qwen's template opens `<think>` in the prompt, so when llama-server's
    reasoning parser misses it the reply arrives as `reasoning</think>answer`
    with no opening tag (seen in the 2026-11-04 eval). Keep only what follows
    the last closing tag; whole `<think>...</think>` blocks go too.
    """
    if "think>" not in text:
        return text
    text = _THINK_BLOCK.sub("", text)
    if "</think>" in text:
        text = text.rsplit("</think>", 1)[1]
    return text.strip()
