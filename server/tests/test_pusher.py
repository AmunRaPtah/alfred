"""The background pusher: exited sessions with a failed turn notify too, and
the restart reconcile's bare exited status never causes a push storm."""
import pytest

from alfredd import config, main, push, sessionio


@pytest.fixture
def sessions_dir(monkeypatch, tmp_path):
    monkeypatch.setattr(config, "SESSIONS_DIR", tmp_path)
    return tmp_path


@pytest.fixture
def pushed(monkeypatch):
    calls = []
    monkeypatch.setattr(push, "notify_turn_finished",
                        lambda title, line, sid: calls.append((title, line, sid)))
    return calls


def _session(sid, state, events=()):
    config.session_dir(sid).mkdir(parents=True, exist_ok=True)
    config.events_path(sid).touch()
    sessionio.write_meta(sid, {"id": sid, "title": f"T {sid}", "state": state,
                               "last_seq": 0, "push_seq": 0})
    for ev in events:
        sessionio.append_event(sid, ev)


def test_exited_session_with_error_pushes_the_error(sessions_dir, pushed):
    _session("pu-err", "exited",
             [{"type": "error", "text": "brain exited with code 1"},
              {"type": "status", "state": "exited", "detail": "process exited code 1"}])
    main._scan_for_finished_turns()
    assert any(c[2] == "pu-err" and c[1].startswith("brain exited") for c in pushed)
    meta = sessionio.read_meta("pu-err")
    assert meta["push_seq"] == meta["last_seq"] == 2


def test_bare_exited_status_is_skipped_silently(sessions_dir, pushed):
    # What the startup reconcile writes to every stale session: no push storm.
    _session("pu-bare", "exited",
             [{"type": "status", "state": "exited", "detail": "alfredd restart: runner/tmux not found"}])
    main._scan_for_finished_turns()
    assert not any(c[2] == "pu-bare" for c in pushed)
    meta = sessionio.read_meta("pu-bare")
    assert meta["push_seq"] == meta["last_seq"] == 1


def test_idle_session_pushes_first_assistant_line(sessions_dir, pushed):
    _session("pu-idle", "idle",
             [{"type": "assistant", "text": "Done.\nDetails below."},
              {"type": "status", "state": "idle", "detail": None}])
    main._scan_for_finished_turns()
    assert any(c[2] == "pu-idle" and c[1] == "Done." for c in pushed)
