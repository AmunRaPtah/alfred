"""autocapture.py: the LLM call is mocked with httpx.MockTransport for the
unit tests below. One real call to kbench-gemini-flash-lite via the local
LiteLLM proxy is exercised manually (see verification notes), not in CI."""
import json
import time

import httpx
import pytest

from alfredd import config, memory, sessionio, autocapture
from alfredd.idgen import new_id


def _make_session(events=(), updated=None):
    sid = new_id()
    config.session_dir(sid).mkdir(parents=True, exist_ok=True)
    now = updated if updated is not None else time.time()
    sessionio.write_meta(sid, {"id": sid, "title": "t", "harness": "alfred", "cwd": "/tmp",
                               "permission": "bypass", "state": "idle", "created": now,
                               "updated": now, "last_seq": 0})
    config.events_path(sid).touch()
    for ev in events:
        sessionio.append_event(sid, ev)
    return sid


def _mock_client(facts):
    def handler(request):
        body = json.dumps({"choices": [{"message": {"content": json.dumps(facts)}}]})
        return httpx.Response(200, content=body)
    return httpx.Client(transport=httpx.MockTransport(handler))


def test_extract_facts_parses_json_array():
    client = _mock_client(["owner prefers tea over coffee"])
    facts = autocapture.extract_facts("User: I prefer tea.", client=client)
    assert facts == ["owner prefers tea over coffee"]


def test_extract_facts_handles_markdown_fenced_json():
    def handler(request):
        body = json.dumps({"choices": [{"message": {"content": "```json\n[\"fact one\"]\n```"}}]})
        return httpx.Response(200, content=body)
    client = httpx.Client(transport=httpx.MockTransport(handler))
    assert autocapture.extract_facts("hi", client=client) == ["fact one"]


def test_extract_facts_raises_on_bad_status():
    def handler(request):
        return httpx.Response(500, content=b"boom")
    client = httpx.Client(transport=httpx.MockTransport(handler))
    with pytest.raises(Exception):
        autocapture.extract_facts("hi", client=client)


def test_process_session_appends_new_facts_and_advances_cursor():
    sid = _make_session(events=[
        {"type": "user", "text": "My deadline is Nov 20"},
        {"type": "assistant", "text": "Noted, I will remind you."},
    ])
    meta = sessionio.read_meta(sid)
    client = _mock_client(["owner has a deadline on Nov 20"])
    added = autocapture.process_session(sid, meta, client=client)
    assert added == ["owner has a deadline on Nov 20"]
    assert "owner has a deadline on Nov 20" in memory.read()
    new_meta = sessionio.read_meta(sid)
    assert new_meta["memory_seq"] == new_meta["last_seq"]


def test_process_session_skips_when_nothing_new():
    sid = _make_session(events=[{"type": "user", "text": "hi"}])
    meta = sessionio.read_meta(sid)
    sessionio.update_meta(sid, memory_seq=meta["last_seq"])
    meta = sessionio.read_meta(sid)
    calls = []

    def handler(request):
        calls.append(request)
        return httpx.Response(200, content=b'{"choices":[{"message":{"content":"[]"}}]}')
    client = httpx.Client(transport=httpx.MockTransport(handler))
    added = autocapture.process_session(sid, meta, client=client)
    assert added == []
    assert calls == []


def test_capture_new_facts_dedupes_against_existing_memory():
    memory.remember("owner's timezone is Lagos WAT")
    added = autocapture.capture_new_facts([
        "owner's timezone is Lagos WAT",
        "owner is learning lockpicking",
    ])
    assert added == ["owner is learning lockpicking"]


def test_process_session_logs_and_returns_empty_on_extraction_failure():
    sid = _make_session(events=[{"type": "user", "text": "hi"}])
    meta = sessionio.read_meta(sid)

    def handler(request):
        return httpx.Response(500, content=b"boom")
    client = httpx.Client(transport=httpx.MockTransport(handler))
    added = autocapture.process_session(sid, meta, client=client)
    assert added == []
    # Cursor is not advanced on failure, so the next sweep retries.
    assert sessionio.read_meta(sid).get("memory_seq", 0) == meta.get("memory_seq", 0)


def test_sweep_once_skips_non_idle_sessions():
    sid = _make_session(events=[{"type": "user", "text": "hi"}], updated=time.time())

    def handler(request):
        raise AssertionError("should not be called for a fresh session")
    import alfredd.autocapture as ac
    orig = ac._http_client
    ac._http_client = lambda: httpx.Client(transport=httpx.MockTransport(handler))
    try:
        results = autocapture.sweep_once()
    finally:
        ac._http_client = orig
    assert results == []
