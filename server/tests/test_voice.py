"""POST /voice/turn, POST /tts, GET /tts/voices. All HTTP backends are mocked
with httpx.MockTransport; nothing touches the network or a real runner."""
import json
import time

import httpx
import pytest

from alfredd import config, sessionio, voice
from alfredd.idgen import new_id


# ---------- helpers ----------

def _make_session(events=()):
    sid = new_id()
    config.session_dir(sid).mkdir(parents=True, exist_ok=True)
    now = time.time()
    sessionio.write_meta(sid, {"id": sid, "title": "t", "harness": "alfred", "cwd": "/tmp",
                               "permission": "bypass", "state": "idle", "created": now,
                               "updated": now, "last_seq": 0})
    config.events_path(sid).touch()
    for ev in events:
        sessionio.append_event(sid, ev)
    return sid


def _sse_body(pieces):
    out = ""
    for p in pieces:
        out += "data: " + json.dumps({"choices": [{"delta": {"content": p}}]}) + "\n\n"
    return (out + "data: [DONE]\n\n").encode()


def _parse_sse(text):
    events = []
    for block in text.strip().split("\n\n"):
        lines = block.split("\n")
        assert lines[0].startswith("event: ") and lines[1].startswith("data: "), block
        events.append((lines[0][7:], json.loads(lines[1][6:])))
    return events


@pytest.fixture
def mock_http(monkeypatch):
    """Install a handler: mock_http(fn) where fn(request) -> httpx.Response.
    Returns the list of requests seen."""
    seen = []

    def install(handler):
        def wrapped(request):
            seen.append(request)
            return handler(request)
        transport = httpx.MockTransport(wrapped)
        monkeypatch.setattr(voice, "http_client",
                            lambda timeout=None: httpx.AsyncClient(transport=transport))
        return seen
    return install


@pytest.fixture
def inbox(monkeypatch):
    written = []

    def fake_write(sid, obj, timeout=12.0):
        written.append((sid, obj))
        return True
    monkeypatch.setattr(sessionio, "write_inbox", fake_write)
    return written


def _voice_cfg(backends):
    config.VOICE_CONFIG_FILE.write_text(json.dumps({"backends": backends}))


TPU = {"name": "tpu", "url": "http://tpu.test/v1", "model": "q", "key": "k1",
       "health": "http://tpu.test/health"}
LITE = {"name": "lite", "url": "http://lite.test/v1", "model": "deepseek-v4-flash", "key": "k2"}


# ---------- voice/turn ----------

def test_voice_turn_streams_sentences(client, auth_headers, mock_http, inbox):
    _voice_cfg([LITE])
    sid = _make_session([{"type": "user", "text": "earlier question"},
                         {"type": "assistant", "text": "<think>hmm</think>earlier answer"}])
    seen = mock_http(lambda req: httpx.Response(200, content=_sse_body(
        ["Good eve", "ning, sir. Mr. Wayne", " is out! Shall I", " wait?"])))
    r = client.post("/voice/turn", json={"session_id": sid, "text": "Where is he?"},
                    headers=auth_headers)
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("text/event-stream")
    evs = _parse_sse(r.text)
    assert evs == [
        ("sentence", {"text": "Good evening, sir."}),
        ("sentence", {"text": "Mr. Wayne is out!"}),
        ("sentence", {"text": "Shall I wait?"}),
        ("done", {"text": "Good evening, sir. Mr. Wayne is out! Shall I wait?",
                  "backend": "lite", "action": None}),
    ]
    assert inbox == []
    req = json.loads(seen[0].content)
    assert seen[0].url == "http://lite.test/v1/chat/completions"
    assert seen[0].headers["authorization"] == "Bearer k2"
    assert req["stream"] is True and req["model"] == "deepseek-v4-flash"
    assert req["messages"][0]["role"] == "system"
    assert req["messages"][1:] == [{"role": "user", "content": "earlier question"},
                                   {"role": "assistant", "content": "earlier answer"},
                                   {"role": "user", "content": "Where is he?"}]
    # The exchange lands in the transcript, tagged as voice.
    tail = sessionio.read_events(sid)[-2:]
    assert [e["type"] for e in tail] == ["user", "assistant"]
    assert tail[1]["source"] == "voice" and tail[1]["text"].startswith("Good evening")


def test_voice_turn_strips_reasoning(client, auth_headers, mock_http, inbox):
    _voice_cfg([LITE])
    sid = _make_session()
    mock_http(lambda req: httpx.Response(200, content=_sse_body(
        ["<think>Let me plan. Okay.", "</think>", "Certainly, sir."])))
    evs = _parse_sse(client.post("/voice/turn", json={"session_id": sid, "text": "hi"},
                                 headers=auth_headers).text)
    assert evs[0] == ("sentence", {"text": "Certainly, sir."})
    assert evs[-1][1]["text"] == "Certainly, sir."


def test_voice_turn_falls_through_when_health_fails(client, auth_headers, mock_http, inbox):
    _voice_cfg([TPU, LITE])
    sid = _make_session()

    def handler(req):
        if req.url.host == "tpu.test":
            return httpx.Response(503)
        return httpx.Response(200, content=_sse_body(["Here, sir."]))
    seen = mock_http(handler)
    evs = _parse_sse(client.post("/voice/turn", json={"session_id": sid, "text": "hi"},
                                 headers=auth_headers).text)
    assert evs[-1] == ("done", {"text": "Here, sir.", "backend": "lite", "action": None,
                                "warnings": ["tpu: health check failed"]})
    # Only the health probe hit the TPU; no completion request was sent there.
    assert [str(r.url) for r in seen if r.url.host == "tpu.test"] == ["http://tpu.test/health"]


def test_voice_turn_falls_through_on_backend_error(client, auth_headers, mock_http, inbox):
    _voice_cfg([TPU, LITE])
    sid = _make_session()

    def handler(req):
        if req.url.path == "/health":
            return httpx.Response(200)
        if req.url.host == "tpu.test":
            return httpx.Response(500, text="boom")
        return httpx.Response(200, content=_sse_body(["Fine."]))
    mock_http(handler)
    evs = _parse_sse(client.post("/voice/turn", json={"session_id": sid, "text": "hi"},
                                 headers=auth_headers).text)
    assert evs[-1][1]["backend"] == "lite"


def test_voice_turn_reads_key_file(client, auth_headers, mock_http, inbox, tmp_path):
    kf = tmp_path / "k.key"
    kf.write_text("secret-from-file\n")
    _voice_cfg([{"name": "kf", "url": "http://kf.test/v1", "model": "m", "key_file": str(kf)}])
    sid = _make_session()
    seen = mock_http(lambda req: httpx.Response(200, content=_sse_body(["Yes."])))
    client.post("/voice/turn", json={"session_id": sid, "text": "hi"}, headers=auth_headers)
    assert seen[0].headers["authorization"] == "Bearer secret-from-file"


def test_voice_turn_act_tag_queues_message(client, auth_headers, mock_http, inbox):
    _voice_cfg([LITE])
    sid = _make_session()
    mock_http(lambda req: httpx.Response(200, content=_sse_body(
        ["Right away, sir. [[AC", "T: draft an email to Lucius about the board meeting]]"])))
    evs = _parse_sse(client.post("/voice/turn", json={"session_id": sid, "text": "email Lucius"},
                                 headers=auth_headers).text)
    task = "draft an email to Lucius about the board meeting"
    assert evs == [
        ("sentence", {"text": "Right away, sir."}),
        ("sentence", {"text": voice.ACK_SENTENCE}),
        ("action", {"task": task, "queued": True}),
        ("done", {"text": f"Right away, sir. {voice.ACK_SENTENCE}", "backend": "lite",
                  "action": task}),
    ]
    assert inbox == [(sid, {"op": "message", "text": task, "attachments": [], "client_id": None})]
    assert all("[[" not in e[1].get("text", "") for e in evs)


def test_voice_turn_all_backends_down(client, auth_headers, mock_http, inbox):
    _voice_cfg([TPU, LITE])
    sid = _make_session()
    mock_http(lambda req: httpx.Response(502))
    evs = _parse_sse(client.post("/voice/turn", json={"session_id": sid, "text": "hi"},
                                 headers=auth_headers).text)
    assert len(evs) == 1 and evs[0][0] == "error"
    assert "tpu" in evs[0][1]["error"] and "lite" in evs[0][1]["error"]


def test_voice_turn_unknown_session_404(client, auth_headers, mock_http, inbox):
    _voice_cfg([LITE])
    r = client.post("/voice/turn", json={"session_id": "nope", "text": "hi"}, headers=auth_headers)
    assert r.status_code == 404


def test_voice_turn_requires_auth(client):
    r = client.post("/voice/turn", json={"session_id": "x", "text": "hi"})
    assert r.status_code == 401


def test_sentence_splitter_abbreviations():
    sp = voice.SentenceSplitter()
    text = "Dr. Thompkins said e.g. rest. It costs 3.50 dollars. Done"
    assert sp.feed(text) == ["Dr. Thompkins said e.g. rest.", "It costs 3.50 dollars."]
    assert sp.flush(text) == ["Done"]


# ---------- tts ----------

def _tts_cfg():
    config.TTS_CONFIG_FILE.write_text(json.dumps({
        "url": "http://tts.test", "key": "ttskey", "default_engine": "kokoro",
        "default_voice": "bm_george"}))


def test_tts_proxy_success(client, auth_headers, mock_http):
    _tts_cfg()
    seen = mock_http(lambda req: httpx.Response(200, content=b"ID3fake-mp3"))
    r = client.post("/tts", json={"text": "Good evening."}, headers=auth_headers)
    assert r.status_code == 200
    assert r.headers["content-type"] == "audio/mpeg"
    assert r.content == b"ID3fake-mp3"
    assert str(seen[0].url) == "http://tts.test/tts"
    assert seen[0].headers["x-alfred-key"] == "ttskey"
    assert json.loads(seen[0].content) == {"text": "Good evening.", "voice": "bm_george",
                                           "engine": "kokoro", "speed": 1.0, "format": "mp3"}


def test_tts_proxy_upstream_down_502(client, auth_headers, mock_http):
    _tts_cfg()

    def handler(req):
        raise httpx.ConnectError("refused", request=req)
    mock_http(handler)
    r = client.post("/tts", json={"text": "hi", "engine": "pocket"}, headers=auth_headers)
    assert r.status_code == 502
    assert "unreachable" in r.json()["detail"]["error"]


def test_tts_proxy_upstream_error_502(client, auth_headers, mock_http):
    _tts_cfg()
    mock_http(lambda req: httpx.Response(500, text="engine crashed"))
    r = client.post("/tts", json={"text": "hi"}, headers=auth_headers)
    assert r.status_code == 502
    assert r.json()["detail"]["upstream"] == "engine crashed"


def test_tts_voices(client, auth_headers, mock_http):
    _tts_cfg()
    mock_http(lambda req: httpx.Response(200, json={"kokoro": ["bm_george", "af_heart"],
                                                    "pocket": ["alba"]}))
    r = client.get("/tts/voices", headers=auth_headers)
    assert r.status_code == 200
    assert r.json() == {"engines": {"kokoro": ["bm_george", "af_heart"], "pocket": ["alba"]},
                        "default_engine": "kokoro", "default_voice": "bm_george"}


def test_tts_voices_upstream_down_502(client, auth_headers, mock_http):
    _tts_cfg()
    mock_http(lambda req: httpx.Response(503))
    r = client.get("/tts/voices", headers=auth_headers)
    assert r.status_code == 502
