import asyncio
import hmac
import json
import os
import shutil
import subprocess
import threading
import time
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, Header, HTTPException, Query, Request, UploadFile, File, Form, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse, Response, StreamingResponse

from pydantic import BaseModel

import httpx

from . import adapters, autocapture, brains, config, db, memory, outbox, push, reaper, sessionio, voice
from .harnesses import get_harnesses
from .idgen import new_id

app = FastAPI()

VALID_PERMISSIONS = {"bypass", "acceptEdits", "default", "plan"}
VALID_BRAINS = set(brains.IDS)  # sonnet, khermes, kqwen, kglm, tpu
VALID_HARNESSES = {h["id"] for h in get_harnesses()}

# Session ids with a live WebSocket client attached right now. Used so the
# auto-push (PROTOCOL.md: "pushes automatically when a session's turn
# finishes while no WebSocket client is attached") doesn't double up with a
# client that already saw the reply live.
ATTACHED_SESSIONS: set = set()
_PUSHER_INTERVAL = 2.0


# ---------- auth ----------

def check_auth(authorization: Optional[str] = Header(None)):
    token = config.load_token()
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "missing bearer token")
    if not hmac.compare_digest(authorization[7:].encode(), token.encode()):
        raise HTTPException(401, "bad token")


# ---------- tmux helpers ----------

def tmux_has_session(name: str) -> bool:
    r = subprocess.run(["tmux", "has-session", "-t", name], capture_output=True)
    return r.returncode == 0


def tmux_kill_session(name: str) -> None:
    subprocess.run(["tmux", "kill-session", "-t", name], capture_output=True)


def tmux_start_runner(sid: str, cwd: str) -> None:
    name = f"ax-{sid}"
    if tmux_has_session(name):
        tmux_kill_session(name)
    Path(cwd).mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["tmux", "new-session", "-d", "-s", name, "-c", cwd,
         "-e", f"ALFRED_HOME={config.ALFRED_HOME}", config.ALFRED_RUNNER, sid],
        check=True,
    )
    subprocess.run(["tmux", "set-option", "-t", name, "remain-on-exit", "on"], capture_output=True)


# ---------- auto-push on turn finished with no WebSocket attached ----------

def _first_assistant_line(events: list) -> str:
    for ev in reversed(events):
        if ev.get("type") == "assistant" and ev.get("text"):
            line = ev["text"].strip().splitlines()[0] if ev["text"].strip() else ""
            if line:
                return line
    return ""


def _scan_for_finished_turns():
    if not config.SESSIONS_DIR.exists():
        return
    for d in config.SESSIONS_DIR.iterdir():
        if not d.is_dir():
            continue
        sid = d.name
        meta = sessionio.read_meta(sid)
        if not meta or meta.get("state") != "idle" or meta.get("ephemeral"):
            continue
        last_seq = meta.get("last_seq", 0)
        pushed_seq = meta.get("push_seq", 0)
        if last_seq <= pushed_seq:
            continue
        if sid in ATTACHED_SESSIONS:
            # A live client already saw this turn; just advance the marker.
            sessionio.update_meta(sid, push_seq=last_seq)
            continue
        new_events = sessionio.read_events(sid, after=pushed_seq, limit=1000)
        first_line = _first_assistant_line(new_events)
        sessionio.update_meta(sid, push_seq=last_seq)
        try:
            push.notify_turn_finished(meta.get("title", ""), first_line, sid)
        except Exception:
            pass


def _pusher_loop():
    while True:
        try:
            _scan_for_finished_turns()
        except Exception:
            pass
        time.sleep(_PUSHER_INTERVAL)


def start_pusher_background():
    threading.Thread(target=_pusher_loop, name="alfred-pusher", daemon=True).start()


# ---------- startup ----------

@app.on_event("startup")
def on_startup():
    config.ensure_dirs()
    config.ensure_token()  # generate ~/.alfred/token if missing
    db.init_db()
    reaper.start_background()
    start_pusher_background()
    autocapture.start_background()
    # Reconcile: any session claiming to be alive but with no tmux session
    # behind it (e.g. the box rebooted) is marked exited.
    if not config.SESSIONS_DIR.exists():
        return
    for d in config.SESSIONS_DIR.iterdir():
        if not d.is_dir():
            continue
        sid = d.name
        meta = sessionio.read_meta(sid)
        if not meta:
            continue
        if meta.get("state") in ("starting", "running", "idle") and not tmux_has_session(f"ax-{sid}"):
            sessionio.update_meta(sid, state="exited")
            sessionio.append_event(sid, {"type": "status", "state": "exited",
                                          "detail": "alfredd restart: runner/tmux not found"})


# ---------- REST ----------

@app.get("/health")
def health():
    return {"ok": True, "version": "1"}


@app.get("/harnesses")
def harnesses(authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return get_harnesses()


@app.get("/sessions")
def list_sessions(authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    out = []
    if config.SESSIONS_DIR.exists():
        for d in config.SESSIONS_DIR.iterdir():
            meta = sessionio.read_meta(d.name)
            if meta:
                out.append(meta)
    out.sort(key=lambda m: m.get("updated", 0), reverse=True)
    return out


@app.post("/sessions")
async def create_session(request: Request, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    body = await request.json()
    harness = body.get("harness")
    if harness not in VALID_HARNESSES:
        raise HTTPException(400, f"unknown harness {harness!r}")
    permission = body.get("permission", "bypass")
    if permission not in VALID_PERMISSIONS:
        raise HTTPException(400, f"bad permission {permission!r}")
    brain = body.get("brain") or None
    if brain is not None and brain not in VALID_BRAINS:
        raise HTTPException(400, f"unknown brain {brain!r}")
    cwd = body.get("cwd") or config.WORKSPACE
    if cwd.rstrip("/") in config.LEGACY_WORKSPACES:
        cwd = config.WORKSPACE
    sid = new_id()
    now = time.time()
    text = body.get("text")
    title = (text or "").strip()[:60] or harness
    meta = {
        "id": sid, "title": title, "harness": harness,
        "profile": body.get("profile"), "model": body.get("model"),
        "cwd": cwd, "permission": permission, "state": "starting",
        "created": now, "updated": now, "last_seq": 0,
        "native_session_id": None, "tmux": f"ax-{sid}",
        # Ephemeral sessions (the eval suite) skip memory capture and push.
        "ephemeral": bool(body.get("ephemeral")),
        # Per-session brain override (alfred-brain's ALFRED_BRAIN); None = default.
        "brain": brain,
    }
    sdir = config.session_dir(sid)
    sdir.mkdir(parents=True, exist_ok=True)
    config.uploads_dir(sid).mkdir(parents=True, exist_ok=True)
    sessionio.write_meta(sid, meta)
    config.events_path(sid).touch()
    os.mkfifo(str(config.inbox_path(sid)))
    tmux_start_runner(sid, cwd)
    if text:
        ok = await asyncio.get_event_loop().run_in_executor(
            None, sessionio.write_inbox, sid, {"op": "message", "text": text,
                                                "attachments": body.get("attachments", [])})
        if not ok:
            sessionio.append_event(sid, {"type": "error", "text": "runner did not come up to accept first message"})
    return sessionio.read_meta(sid)


def _require_session(sid: str) -> dict:
    meta = sessionio.read_meta(sid)
    if not meta:
        raise HTTPException(404, "no such session")
    return meta


@app.get("/sessions/{sid}")
def get_session(sid: str, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return _require_session(sid)


@app.patch("/sessions/{sid}")
async def patch_session(sid: str, request: Request, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    _require_session(sid)
    body = await request.json()
    fields = {}
    if "title" in body:
        fields["title"] = body["title"]
    return sessionio.update_meta(sid, **fields)


@app.delete("/sessions/{sid}")
def delete_session(sid: str, purge: int = Query(0), authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    _require_session(sid)
    tmux_kill_session(f"ax-{sid}")
    if purge:
        shutil.rmtree(config.session_dir(sid), ignore_errors=True)
    return {"ok": True}


@app.get("/sessions/{sid}/events")
def get_events(sid: str, after: int = 0, limit: int = 500, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    _require_session(sid)
    return sessionio.read_events(sid, after=after, limit=limit)


@app.post("/sessions/{sid}/messages")
async def post_message(sid: str, request: Request, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    meta = _require_session(sid)
    body = await request.json()
    if not await _queue_message(sid, body):
        raise HTTPException(503, "runner not accepting input")
    # Messages sent mid-turn are queued by the runner, not rejected.
    return {"ok": True, "queued": meta.get("state") == "running" or bool(meta.get("queue"))}


async def _queue_message(sid: str, body: dict) -> bool:
    """Hands one user message to the session's runner via its inbox FIFO.
    Shared by POST /sessions/{sid}/messages and voice-turn [[ACT]] hand-offs."""
    return await asyncio.get_event_loop().run_in_executor(
        None, sessionio.write_inbox, sid, _message_op(body))


def _message_op(body: dict) -> dict:
    return {"op": "message", "text": body.get("text", ""),
            "attachments": body.get("attachments", []), "client_id": body.get("client_id")}


@app.delete("/sessions/{sid}/queue/{qid}")
async def dequeue_one(sid: str, qid: str, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    _require_session(sid)
    ok = await asyncio.get_event_loop().run_in_executor(
        None, sessionio.write_inbox, sid, {"op": "dequeue", "queue_id": qid})
    if not ok:
        raise HTTPException(503, "runner not accepting input")
    return {"ok": True}


@app.delete("/sessions/{sid}/queue")
async def dequeue_all(sid: str, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    _require_session(sid)
    ok = await asyncio.get_event_loop().run_in_executor(
        None, sessionio.write_inbox, sid, {"op": "dequeue", "queue_id": None})
    if not ok:
        raise HTTPException(503, "runner not accepting input")
    return {"ok": True}


@app.get("/sessions/{sid}/commands")
def session_commands(sid: str, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    meta = _require_session(sid)
    return {"commands": adapters.known_commands(meta), "shell": True}


@app.post("/sessions/{sid}/interrupt")
async def interrupt_session(sid: str, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    _require_session(sid)
    ok = await asyncio.get_event_loop().run_in_executor(
        None, sessionio.write_inbox, sid, {"op": "interrupt"})
    if not ok:
        raise HTTPException(503, "runner not accepting input")
    return {"ok": True}


@app.post("/sessions/{sid}/resume")
def resume_session(sid: str, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    meta = _require_session(sid)
    sessionio.update_meta(sid, state="starting")
    tmux_start_runner(sid, meta["cwd"])
    return sessionio.read_meta(sid)


@app.post("/upload")
async def upload(file: UploadFile = File(...), session_id: str = Form(...),
                  authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    _require_session(session_id)
    dest = await _save_upload(file, config.uploads_dir(session_id))
    return {"path": str(dest)}


async def _save_upload(file: UploadFile, udir: Path) -> Path:
    """Streams an upload into udir without overwriting: a clash becomes name-1.ext."""
    udir.mkdir(parents=True, exist_ok=True)
    name = Path(file.filename or "").name or f"upload-{int(time.time())}"
    stem, suffix = Path(name).stem, Path(name).suffix
    dest, n = udir / name, 1
    while dest.exists():
        dest, n = udir / f"{stem}-{n}{suffix}", n + 1
    with dest.open("wb") as out:
        while chunk := await file.read(1 << 20):
            out.write(chunk)
    return dest


@app.get("/dirs")
def dirs(path: str = Query(str(Path.home())), authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    p = Path(path)
    if not p.is_dir():
        raise HTTPException(400, "not a directory")
    entries = []
    try:
        for e in sorted(p.iterdir(), key=lambda x: x.name.lower()):
            if e.is_dir():
                entries.append({"name": e.name, "is_dir": True})
    except PermissionError:
        pass
    return {"path": str(p), "entries": entries}


@app.get("/quota")
def quota(authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    qa = shutil.which("quota-axi")
    if not qa:
        return {}
    try:
        out = subprocess.run([qa, "--json"], capture_output=True, text=True, timeout=15).stdout
        return json.loads(out)
    except Exception:
        return {}


# ---------- brains (model picker + Kaggle session control) ----------

@app.get("/brains")
def list_brains(authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return brains.status()


def _brain_call(fn, *args):
    try:
        return fn(*args)
    except brains.BrainError as e:
        raise HTTPException(e.code, e.detail)


@app.post("/brains/{bid}/start")
def start_brain(bid: str, replace: int = Query(0), authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return _brain_call(brains.start, bid, bool(replace))


@app.post("/brains/{bid}/stop")
def stop_brain(bid: str, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return _brain_call(brains.stop, bid)


# ---------- devices (Alfred protocol addition) ----------

class DeviceBody(BaseModel):
    token: str
    env: str
    bundle_id: str


@app.post("/devices")
def register_device(body: DeviceBody, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    if body.env not in ("sandbox", "production"):
        raise HTTPException(400, "env must be sandbox or production")
    db.upsert_device(body.token, body.env, body.bundle_id)
    return {"ok": True}


@app.delete("/devices/{token}")
def unregister_device(token: str, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    db.delete_device(token)
    return {"ok": True}


# ---------- reminders (Alfred protocol addition) ----------

class ReminderBody(BaseModel):
    title: str
    body: str
    fire_at: str
    session_id: Optional[str] = None


@app.get("/reminders")
def list_reminders(after: Optional[str] = Query(None), authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return {"reminders": db.list_reminders(after=after)}


@app.post("/reminders")
def create_reminder(body: ReminderBody, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    rid = new_id()
    return db.create_reminder(rid, body.title, body.body, body.fire_at, body.session_id)


@app.delete("/reminders/{rid}")
def delete_reminder(rid: str, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    db.delete_reminder(rid)
    return {"ok": True}


# ---------- notify / push status (Alfred protocol addition) ----------

class NotifyBody(BaseModel):
    title: str
    body: str
    session_id: Optional[str] = None


@app.post("/notify")
def notify(body: NotifyBody, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return push.notify(body.title, body.body, session_id=body.session_id)


@app.get("/push/status")
def push_status(authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return push.status()


# ---------- memory (Alfred protocol addition) ----------

class MemoryBody(BaseModel):
    text: str


class RememberBody(BaseModel):
    fact: str


@app.get("/memory")
def get_memory(authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return {"text": memory.read()}


@app.put("/memory")
def put_memory(body: MemoryBody, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return {"text": memory.write(body.text)}


@app.post("/memory/remember")
def remember_fact(body: RememberBody, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return {"text": memory.remember(body.fact)}


# ---------- outbox: outbound-email approval gate (Alfred protocol addition) ----------

class OutboxBody(BaseModel):
    kind: str = "email"
    to: str
    subject: str
    body: str
    attachments: Optional[list] = None


@app.post("/outbox")
def create_outbox(body: OutboxBody, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    if body.kind != "email":
        raise HTTPException(400, f"unsupported outbox kind {body.kind!r}")
    oid = new_id()
    item = db.create_outbox_item(oid, body.kind, body.to, body.subject, body.body, body.attachments)
    try:
        push.notify(f"Approval needed: {body.subject}", f"Draft email to {body.to}")
    except Exception:
        pass
    return item


@app.get("/outbox")
def list_outbox(status: Optional[str] = Query(None), authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return {"outbox": db.list_outbox(status=status)}


def _require_outbox_item(oid: str) -> dict:
    item = db.get_outbox_item(oid)
    if not item:
        raise HTTPException(404, "no such outbox item")
    return item


@app.post("/outbox/{oid}/approve")
def approve_outbox(oid: str, request: Request, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    outbox.check_approval_allowed(request)
    item = _require_outbox_item(oid)
    if item["status"] != "pending":
        raise HTTPException(409, f"outbox item is {item['status']}, not pending")
    try:
        outbox.send_email(item["recipient"], item["subject"], item["body"], item["attachments"])
    except Exception as e:
        return db.set_outbox_status(oid, "failed", error=str(e))
    return db.set_outbox_status(oid, "sent")


@app.post("/outbox/{oid}/reject")
def reject_outbox(oid: str, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    item = _require_outbox_item(oid)
    if item["status"] != "pending":
        raise HTTPException(409, f"outbox item is {item['status']}, not pending")
    return db.set_outbox_status(oid, "rejected")


# ---------- voice: fast spoken turns + TTS proxy (Alfred protocol addition) ----------

class VoiceTurnBody(BaseModel):
    session_id: str
    text: str
    voice: Optional[str] = None


def _record_voice_exchange(sid: str, user_text: str, reply: str, backend: str,
                           action: Optional[str]) -> None:
    """Appends the exchange as ordinary user/assistant events (tagged
    source:"voice") so the chat transcript and later voice turns see it. The
    owner already heard the reply, so the auto-push marker is advanced too,
    unless an earlier harness turn was still waiting to be pushed."""
    before = sessionio.read_meta(sid) or {}
    pending_push = before.get("last_seq", 0) > before.get("push_seq", 0)
    sessionio.append_event(sid, {"type": "user", "text": user_text, "attachments": [],
                                 "source": "voice"})
    ev = sessionio.append_event(sid, {"type": "assistant", "msg_id": f"voice-{int(time.time() * 1000)}",
                                      "text": reply, "source": "voice", "backend": backend,
                                      "action": action})
    if not pending_push:
        sessionio.update_meta(sid, push_seq=ev["seq"])


@app.post("/voice/turn")
async def voice_turn(body: VoiceTurnBody, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    sid = body.session_id
    _require_session(sid)
    user_text = body.text.strip()
    if not user_text:
        raise HTTPException(400, "empty text")
    messages = voice.build_messages(sid, user_text)

    async def gen():
        raw, backend, errors = "", None, []
        splitter = voice.SentenceSplitter()
        spoken = []
        try:
            async for name, tok in voice.stream_reply(messages, errors):
                backend = name
                raw += tok
                for s in splitter.feed(voice.visible_text(raw)):
                    spoken.append(s)
                    yield voice.sse("sentence", {"text": s})
        except voice.NoBackend as e:
            yield voice.sse("error", {"error": f"no voice backend answered: {e}"})
            return
        except Exception as e:
            # Failed mid-reply: keep what was already said, note the cut.
            errors.append(f"{backend}: stream broke: {e.__class__.__name__}: {e}"[:300])
        for s in splitter.flush(voice.visible_text(raw)):
            spoken.append(s)
            yield voice.sse("sentence", {"text": s})

        task = voice.find_action(raw)
        full = voice.tidy(" ".join(spoken))
        # Record before handing off, so the transcript reads voice question,
        # spoken acknowledgement, then the harness's own turn on the task.
        try:
            _record_voice_exchange(sid, user_text,
                                   voice.tidy(f"{full} {voice.ACK_SENTENCE}") if task else full,
                                   backend or "", task)
        except Exception:
            pass
        if task:
            queued = await _queue_message(sid, {"text": task})
            if queued:
                full = voice.tidy(f"{full} {voice.ACK_SENTENCE}")
                yield voice.sse("sentence", {"text": voice.ACK_SENTENCE})
            else:
                try:
                    sessionio.append_event(sid, {"type": "error",
                                                 "text": "voice hand-off failed: runner not accepting input"})
                except Exception:
                    pass
            yield voice.sse("action", {"task": task, "queued": queued})

        done = {"text": full, "backend": backend, "action": task}
        if errors and backend:
            done["warnings"] = errors
        yield voice.sse("done", done)

    return StreamingResponse(gen(), media_type="text/event-stream",
                             headers={"cache-control": "no-cache", "x-accel-buffering": "no"})


class TtsBody(BaseModel):
    text: str
    voice: Optional[str] = None
    engine: Optional[str] = None
    speed: Optional[float] = None


TTS_TIMEOUT = 20.0


def _tts_config() -> dict:
    p = config.TTS_CONFIG_FILE
    try:
        cfg = json.loads(p.read_text())
    except (OSError, ValueError):
        raise HTTPException(503, "tts not configured (~/.alfred/tts.json)")
    if not cfg.get("url"):
        raise HTTPException(503, "tts.json has no url")
    return cfg


def _tts_headers(cfg: dict) -> dict:
    return {"X-Alfred-Key": cfg["key"]} if cfg.get("key") else {}


def _upstream_error(what: str, e: Exception = None, r: httpx.Response = None) -> JSONResponse:
    if r is not None:
        detail = {"error": f"tts upstream {what} returned HTTP {r.status_code}",
                  "upstream": r.text[:300]}
    else:
        detail = {"error": f"tts upstream {what} unreachable: {e.__class__.__name__}: {e}"[:300]}
    return JSONResponse({"detail": detail}, status_code=502)


@app.post("/tts")
async def tts(body: TtsBody, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    if not body.text.strip():
        raise HTTPException(400, "empty text")
    cfg = _tts_config()
    payload = {"text": body.text,
               "voice": body.voice or cfg.get("default_voice"),
               "engine": body.engine or cfg.get("default_engine"),
               "speed": body.speed if body.speed is not None else 1.0,
               "format": "mp3"}
    try:
        async with voice.http_client(httpx.Timeout(TTS_TIMEOUT)) as c:
            r = await c.post(cfg["url"].rstrip("/") + "/tts", json=payload, headers=_tts_headers(cfg))
    except Exception as e:
        return _upstream_error("/tts", e=e)
    if r.status_code != 200:
        return _upstream_error("/tts", r=r)
    return Response(r.content, media_type="audio/mpeg")


@app.get("/tts/voices")
async def tts_voices(authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    cfg = _tts_config()
    try:
        async with voice.http_client(httpx.Timeout(TTS_TIMEOUT)) as c:
            r = await c.get(cfg["url"].rstrip("/") + "/voices", headers=_tts_headers(cfg))
        if r.status_code != 200:
            return _upstream_error("/voices", r=r)
        engines = r.json()
    except Exception as e:
        return _upstream_error("/voices", e=e)
    return {"engines": engines, "default_engine": cfg.get("default_engine"),
            "default_voice": cfg.get("default_voice")}


# ---------- WebSocket ----------

@app.websocket("/sessions/{sid}/stream")
async def stream(ws: WebSocket, sid: str):
    token = ws.headers.get("authorization")
    if token and token.startswith("Bearer "):
        token = token[7:]
    elif ws.headers.get("x-alfred-route") != "public":
        # Query-param fallback only on wg0; a public route would log URLs.
        token = ws.query_params.get("token")
    else:
        token = None
    try:
        expected = config.load_token()
    except Exception:
        expected = None
    if not token or not expected or not hmac.compare_digest(token.encode(), expected.encode()):
        await ws.close(code=4401)
        return
    meta = sessionio.read_meta(sid)
    if not meta:
        await ws.close(code=4404)
        return
    await ws.accept()
    after = int(ws.query_params.get("after", 0))
    ATTACHED_SESSIONS.add(sid)

    stop = asyncio.Event()

    async def sender():
        last_sent = after
        last_ping = time.time()
        while not stop.is_set():
            evs = sessionio.read_events(sid, after=last_sent, limit=1000)
            for ev in evs:
                await ws.send_text(json.dumps(ev))
                last_sent = ev["seq"]
            if time.time() - last_ping >= 20:
                await ws.send_text(json.dumps({"type": "ping"}))
                last_ping = time.time()
            await asyncio.sleep(0.2)

    async def receiver():
        try:
            while True:
                raw = await ws.receive_text()
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                if msg.get("type") == "message":
                    await asyncio.get_event_loop().run_in_executor(
                        None, sessionio.write_inbox, sid, _message_op(msg))
                elif msg.get("type") == "dequeue":
                    await asyncio.get_event_loop().run_in_executor(
                        None, sessionio.write_inbox, sid,
                        {"op": "dequeue", "queue_id": msg.get("queue_id")})
                elif msg.get("type") == "interrupt":
                    await asyncio.get_event_loop().run_in_executor(
                        None, sessionio.write_inbox, sid, {"op": "interrupt"})
        except WebSocketDisconnect:
            pass
        finally:
            stop.set()

    send_task = asyncio.create_task(sender())
    recv_task = asyncio.create_task(receiver())
    try:
        await asyncio.wait([send_task, recv_task], return_when=asyncio.FIRST_COMPLETED)
    finally:
        stop.set()
        send_task.cancel()
        recv_task.cancel()
        ATTACHED_SESSIONS.discard(sid)
