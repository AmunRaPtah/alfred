"""Runner robustness: broken-pipe restart, nonzero brain exit requeue, and the
turn watchdog. The runner script is loaded as a module; no tmux, no real brain."""
import importlib.machinery
import importlib.util
import time
from pathlib import Path

import pytest

from alfredd import config, sessionio

_RUNNER_PATH = Path(__file__).resolve().parent.parent / "alfred-runner"
_loader = importlib.machinery.SourceFileLoader("alfred_runner", str(_RUNNER_PATH))
_spec = importlib.util.spec_from_loader("alfred_runner", _loader)
runner_mod = importlib.util.module_from_spec(_spec)
_loader.exec_module(runner_mod)


class FakeStdin:
    def __init__(self, broken=False):
        self.broken = broken
        self.lines = []

    def write(self, s):
        if self.broken:
            raise BrokenPipeError("broken pipe")
        self.lines.append(s)

    def flush(self):
        pass


class FakeChild:
    """Stands in for the alfred-brain Popen. rc=None means still alive."""

    def __init__(self, broken=False, rc=None, out=()):
        self.stdin = FakeStdin(broken)
        self.stdout = iter(out)
        self.rc = rc
        self.pid = 4242

    def poll(self):
        return self.rc

    def wait(self):
        return self.rc if self.rc is not None else 0


@pytest.fixture
def sessions_dir(monkeypatch, tmp_path):
    monkeypatch.setattr(config, "SESSIONS_DIR", tmp_path)
    return tmp_path


def _make_runner(sid):
    config.session_dir(sid).mkdir(parents=True, exist_ok=True)
    config.events_path(sid).touch()
    sessionio.write_meta(sid, {
        "id": sid, "title": "t", "harness": "alfred", "permission": "bypass",
        "cwd": "/tmp", "state": "idle", "created": 0, "updated": 0,
        "last_seq": 0, "queue": []})
    return runner_mod.Runner(sid)


def _events(sid):
    return sessionio.read_events(sid, after=0, limit=1000)


def test_broken_pipe_restarts_brain_once_and_retries(sessions_dir, monkeypatch):
    r = _make_runner("rt-pipe")
    r.child = FakeChild(broken=True)
    starts = []

    def fake_start():
        starts.append(1)
        r.child = FakeChild()
    monkeypatch.setattr(r, "start_long_lived", fake_start)

    assert r.send_long_lived("hello", []) is True
    assert starts == [1]
    assert any("hello" in line for line in r.child.stdin.lines)
    assert any(e["type"] == "system" and "restarting brain" in e["text"] for e in _events("rt-pipe"))


def test_brain_never_comes_up_returns_false_with_error(sessions_dir, monkeypatch):
    r = _make_runner("rt-dead")
    r.child = FakeChild(broken=True)
    monkeypatch.setattr(r, "start_long_lived",
                        lambda: setattr(r, "child", FakeChild(broken=True)))

    assert r.send_long_lived("hello", []) is False
    assert any(e["type"] == "error" and "did not come up" in e["text"] for e in _events("rt-dead"))


def test_nonzero_brain_exit_requeues_message_with_output_tail(sessions_dir):
    r = _make_runner("rt-exit1")
    item = {"queue_id": "q-keep", "text": "hi", "attachments": [], "client_id": None}
    with r.cv:
        r.busy, r.current_item, r.turn_started = True, item, time.time()
    r.child = FakeChild(rc=1, out=["kaggle-glm: cold start failed\n"])

    r.reader_long_lived()

    meta = sessionio.read_meta("rt-exit1")
    assert meta["state"] == "exited"
    assert meta["queue"][0]["queue_id"] == "q-keep"  # message kept for a resumed runner
    errs = [e for e in _events("rt-exit1") if e["type"] == "error"]
    assert errs and "exited with code 1" in errs[0]["text"]
    assert "cold start failed" in errs[0]["text"]
    assert r.busy is False


def test_watchdog_fails_stalled_turn(sessions_dir):
    r = _make_runner("rt-stall")
    with r.cv:
        r.busy = True
        r.turn_started = time.time() - (runner_mod.TURN_TIMEOUT + 10)
    r.child = FakeChild(rc=None)  # alive but silent

    assert r.watchdog_check() is True
    assert r.busy is False
    assert sessionio.read_meta("rt-stall")["state"] == "idle"
    assert any(e["type"] == "error" and "watchdog" in e["text"] for e in _events("rt-stall"))


def test_watchdog_fails_turn_whose_brain_vanished(sessions_dir):
    r = _make_runner("rt-gone")
    with r.cv:
        r.busy = True
        r.turn_started = time.time() - (3 * runner_mod.WATCHDOG_INTERVAL)
    r.child = FakeChild(rc=0)  # exited mid-turn, reader never closed it out

    assert r.watchdog_check() is True
    assert any("gone mid-turn" in e["text"] for e in _events("rt-gone") if e["type"] == "error")


def test_watchdog_leaves_fresh_turn_alone(sessions_dir):
    r = _make_runner("rt-fresh")
    with r.cv:
        r.busy = True
        r.turn_started = time.time()
    r.child = FakeChild(rc=None)

    assert r.watchdog_check() is False
    assert r.busy is True
