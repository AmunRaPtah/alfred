"""Stale tmux session reaper.

Kills tmux sessions that have been idle longer than `idle_hours`, so finished
chats stop holding a live harness (and its RAM) on the box. Alfred sessions are
marked exited, so the app can resume them later; files on the box are kept.

Idle time for an ax-<sid> session is the newest of its tmux window activity and
the mtime of its events/meta/inbox files. tmux's own session_activity only moves
on keyboard input, which alfred-runner never gets, so it is not used alone.
"""
import json
import threading
import time

from . import box, config, sessionio

REAPER_FILE = config.ALFRED_HOME / "reaper.json"
INTERVAL_SECONDS = 900

DEFAULTS = {"enabled": True, "idle_hours": 24.0, "include_non_helm": False}
# Never touched, even with include_non_helm on.
PROTECTED = {"main"}

_lock = threading.Lock()
_last_run = {"at": None, "killed": []}


def load() -> dict:
    cfg = dict(DEFAULTS)
    try:
        cfg.update(json.loads(REAPER_FILE.read_text()))
    except Exception:
        pass
    return cfg


def save(**fields) -> dict:
    cfg = load()
    if "enabled" in fields:
        cfg["enabled"] = bool(fields["enabled"])
    if "idle_hours" in fields:
        cfg["idle_hours"] = max(1.0, min(float(fields["idle_hours"]), 24.0 * 14))
    if "include_non_helm" in fields:
        cfg["include_non_helm"] = bool(fields["include_non_helm"])
    REAPER_FILE.write_text(json.dumps(cfg, indent=2))
    return cfg


def _window_activity() -> dict:
    out = box._run(["tmux", "list-windows", "-a", "-F", "#{session_name}\t#{window_activity}"])
    latest = {}
    for line in out.splitlines():
        name, _, ts = line.partition("\t")
        if ts.isdigit():
            latest[name] = max(latest.get(name, 0), int(ts))
    return latest


def _last_active(name: str, created, window_act: dict) -> float:
    t = float(window_act.get(name) or created or 0)
    if name.startswith("ax-"):
        sid = name[3:]
        for p in (config.events_path(sid), config.meta_path(sid), config.inbox_path(sid)):
            try:
                t = max(t, p.stat().st_mtime)
            except OSError:
                pass
    return t


def sessions_with_idle() -> list:
    now = time.time()
    window_act = _window_activity()
    out = []
    for s in box.tmux_sessions():
        last = _last_active(s["name"], s.get("created"), window_act)
        out.append({**s, "last_active": last or None,
                    "idle_hours": round((now - last) / 3600, 1) if last else None})
    return out


def candidates(cfg: dict = None) -> list:
    cfg = cfg or load()
    picked = []
    for s in sessions_with_idle():
        if s["attached"] or s["name"] in PROTECTED:
            continue
        if not s["is_helm"] and not cfg["include_non_helm"]:
            continue
        if s["idle_hours"] is not None and s["idle_hours"] >= cfg["idle_hours"]:
            picked.append(s)
    return picked


def run_once(cfg: dict = None) -> list:
    with _lock:
        killed = []
        for s in candidates(cfg):
            if not box.tmux_kill(s["name"]):
                continue
            killed.append({"name": s["name"], "idle_hours": s["idle_hours"]})
            if s["is_helm"]:
                sid = s["name"][3:]
                if sessionio.read_meta(sid):
                    sessionio.update_meta(sid, state="exited")
                    sessionio.append_event(sid, {"type": "status", "state": "exited",
                                                 "detail": f"reaped: idle {s['idle_hours']}h"})
        _last_run.update(at=time.time(), killed=killed)
        return killed


def status() -> dict:
    cfg = load()
    return {"config": cfg, "candidates": candidates(cfg), "last_run": dict(_last_run),
            "interval_seconds": INTERVAL_SECONDS}


def loop_forever():
    while True:
        try:
            if load()["enabled"]:
                run_once()
        except Exception:
            pass
        time.sleep(INTERVAL_SECONDS)


def start_background():
    threading.Thread(target=loop_forever, name="alfred-reaper", daemon=True).start()
