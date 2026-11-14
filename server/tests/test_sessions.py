"""Session creation hardening."""
from alfredd import config, main


def test_create_session_tmux_failure_cleans_up(client, auth_headers, monkeypatch):
    def boom(sid, cwd):
        raise RuntimeError("tmux: command not found")
    monkeypatch.setattr(main, "tmux_start_runner", boom)

    before = {d.name for d in config.SESSIONS_DIR.iterdir()} if config.SESSIONS_DIR.exists() else set()
    r = client.post("/sessions", json={"harness": "alfred", "cwd": "/tmp"}, headers=auth_headers)
    assert r.status_code == 500
    assert "failed to start session runner" in r.json()["detail"]
    # No runnerless session left behind, on disk or in the listing.
    after = {d.name for d in config.SESSIONS_DIR.iterdir()} if config.SESSIONS_DIR.exists() else set()
    assert after == before
