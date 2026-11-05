"""GET /brains and POST /brains/{id}/start|stop with every probe and the
subprocess launcher mocked: these tests never touch Kaggle or the tunnels."""
import pytest

from alfredd import brains, sessionio


class World:
    """Fake tunnel/process/kernel state plus a record of launched jobs."""

    def __init__(self):
        self.t4 = None          # model id served on the T4 tunnel
        self.tpu = False
        self.procs = {}
        self.kernels = {}
        self.launched = []

    def popen(self, argv):
        self.launched.append(argv)

        class P:
            pid = 4242
        return P()


@pytest.fixture
def world(monkeypatch, tmp_path):
    w = World()
    monkeypatch.setattr(brains, "probe_t4", lambda: w.t4)
    monkeypatch.setattr(brains, "probe_tpu", lambda: w.tpu)
    monkeypatch.setattr(brains, "scan_processes", lambda: dict(w.procs))
    monkeypatch.setattr(brains, "_popen", w.popen)
    monkeypatch.setattr(brains, "_kick_kernel_refresh", lambda: None)
    monkeypatch.setattr(brains, "KAGGLE_STATE", tmp_path)
    monkeypatch.setitem(brains._kernels, "value", w.kernels)
    brains.invalidate()
    yield w
    brains.invalidate()


def _by_id(body):
    return {b["id"]: b for b in body["brains"]}


def test_brains_requires_auth(client, world):
    assert client.get("/brains").status_code == 401


def test_brains_lists_catalog_and_reports_loaded_t4(client, auth_headers, world):
    world.t4 = "qwen36-35b-kaggle"
    r = client.get("/brains", headers=auth_headers)
    assert r.status_code == 200
    body = r.json()
    assert [b["id"] for b in body["brains"]] == ["sonnet", "khermes", "kqwen", "kglm", "tpu"]
    assert body["default"] == "sonnet"
    assert body["t4_loaded"] == "khermes"
    b = _by_id(body)
    assert b["sonnet"]["status"] == "up" and not b["sonnet"]["controllable"]
    assert b["khermes"]["status"] == "up"
    assert b["kqwen"]["status"] == "down" and b["kglm"]["status"] == "down"
    assert b["tpu"]["status"] == "down"
    for x in body["brains"]:
        assert x["label"] and x["note"] and x["tier"] in ("proxy", "t4", "tpu")


def test_status_is_cached(client, auth_headers, world):
    assert _by_id(client.get("/brains", headers=auth_headers).json())["kglm"]["status"] == "down"
    world.t4 = "glm47-kaggle"
    assert _by_id(client.get("/brains", headers=auth_headers).json())["kglm"]["status"] == "down"
    brains.invalidate()
    assert _by_id(client.get("/brains", headers=auth_headers).json())["kglm"]["status"] == "up"


def test_starting_from_process_and_from_queued_kernel(client, auth_headers, world, tmp_path):
    world.procs = {"t4": {"pid": 1, "brain": "kqwen", "action": "start", "ours": False}}
    world.kernels.update({"tpu": "queued"})
    b = _by_id(client.get("/brains", headers=auth_headers).json())
    assert b["kqwen"]["status"] == "starting"
    assert b["tpu"]["status"] == "starting" and "capacity" in b["tpu"]["detail"]

    world.procs = {}
    world.kernels.update({"t4": "running"})
    (tmp_path / "config-model").write_text("glm47-kaggle abc123\n")
    brains.invalidate()
    assert _by_id(client.get("/brains", headers=auth_headers).json())["kglm"]["status"] == "starting"


def test_stop_flag_shows_stopping(client, auth_headers, world, tmp_path):
    world.t4 = "qwen36-35b-kaggle"
    (tmp_path / "stop").touch()
    assert _by_id(client.get("/brains", headers=auth_headers).json())["khermes"]["status"] == "stopping"


def test_start_t4_when_idle_launches_kaggle_glm(client, auth_headers, world):
    r = client.post("/brains/kglm/start", headers=auth_headers)
    assert r.status_code == 200, r.text
    assert r.json()["action"] == "start"
    (argv,) = world.launched
    assert argv[0:2] == ["bash", "-c"] and argv[3] == "alfred-brain-job:kglm:start"
    assert "KAGGLE_MODEL=glm47-kaggle" in argv[2] and "start --wait" in argv[2]


def test_start_already_up_is_noop(client, auth_headers, world):
    world.t4 = "qwen36-35b-kaggle"
    r = client.post("/brains/khermes/start", headers=auth_headers)
    assert r.status_code == 200 and r.json()["action"] == "none"
    assert world.launched == []


def test_start_other_t4_refused_without_replace(client, auth_headers, world):
    world.t4 = "qwen36-35b-kaggle"
    r = client.post("/brains/kqwen/start", headers=auth_headers)
    assert r.status_code == 409
    assert "khermes" in r.json()["detail"] and "replace=1" in r.json()["detail"]
    assert world.launched == []


def test_start_other_t4_refused_while_one_is_starting(client, auth_headers, world):
    world.procs = {"t4": {"pid": 1, "brain": "khermes", "action": "start", "ours": False}}
    assert client.post("/brains/kglm/start", headers=auth_headers).status_code == 409


def test_replace_stops_waits_then_starts(client, auth_headers, world):
    world.t4 = "qwen36-35b-kaggle"
    r = client.post("/brains/kqwen/start?replace=1", headers=auth_headers)
    assert r.status_code == 200 and r.json()["action"] == "replace"
    (argv,) = world.launched
    script = argv[2]
    assert argv[3] == "alfred-brain-job:kqwen:replace"
    stop_at, start_at = script.index("kaggle-glm stop"), script.index("KAGGLE_MODEL=qwen38-kaggle")
    assert stop_at < script.index("/health") < start_at


def test_start_tpu_and_proxy_and_unknown(client, auth_headers, world):
    r = client.post("/brains/tpu/start", headers=auth_headers)
    assert r.status_code == 200
    assert "qwen122-tpu start --wait" in world.launched[-1][2]
    assert client.post("/brains/sonnet/start", headers=auth_headers).status_code == 400
    assert client.post("/brains/nope/start", headers=auth_headers).status_code == 404


def test_stop(client, auth_headers, world):
    assert client.post("/brains/kglm/stop", headers=auth_headers).status_code == 409
    world.t4 = "glm47-kaggle"
    r = client.post("/brains/kglm/stop", headers=auth_headers)
    assert r.status_code == 200
    assert world.launched[-1][2].endswith("kaggle-glm stop")
    assert world.launched[-1][3] == "alfred-brain-job:kglm:stop"


def test_session_meta_carries_brain(client, auth_headers, world, monkeypatch):
    from alfredd import main
    monkeypatch.setattr(main, "tmux_start_runner", lambda sid, cwd: None)
    r = client.post("/sessions", json={"harness": "alfred", "brain": "khermes", "cwd": "/tmp"},
                    headers=auth_headers)
    assert r.status_code == 200, r.text
    meta = r.json()
    assert meta["brain"] == "khermes"
    assert client.get(f"/sessions/{meta['id']}", headers=auth_headers).json()["brain"] == "khermes"

    r = client.post("/sessions", json={"harness": "alfred", "cwd": "/tmp"}, headers=auth_headers)
    assert r.json()["brain"] is None
    r = client.post("/sessions", json={"harness": "alfred", "brain": "gpt9", "cwd": "/tmp"}, headers=auth_headers)
    assert r.status_code == 400


def test_adapter_keeps_kaggle_session_on_exit():
    from alfredd import adapters
    _, env = adapters.claude_cmd({"harness": "alfred", "permission": "bypass", "brain": "khermes"})
    assert env["ALFRED_BRAIN"] == "khermes" and env["ALFRED_BRAIN_KEEP"] == "1"
    _, env = adapters.claude_cmd({"harness": "alfred", "permission": "bypass"})
    assert "ALFRED_BRAIN" not in env
