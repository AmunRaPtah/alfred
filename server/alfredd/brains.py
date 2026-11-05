"""Brain catalog and Kaggle session control (GET /brains, POST /brains/{id}/start|stop).

Each Alfred chat runs /root/.local/bin/alfred-brain, which picks its model from
ALFRED_BRAIN (meta["brain"], see adapters.claude_cmd). This module tells the app
which brains exist and whether their Kaggle sessions are up, and starts/stops
those sessions in the background:

  - T4 tier: `kaggle-glm` (llm-burst/kaggle) with KAGGLE_MODEL=<models.py key>.
    Every T4 model shares one tunnel (127.0.0.1:8190) and one GPU quota, so only
    one is up at a time; /v1/models on the tunnel names the loaded one.
  - TPU tier: llm-burst/kaggle-tpu/qwen122-tpu, tunnel 127.0.0.1:8193.

Status must stay cheap: the tunnel probes use 2 s timeouts and are cached for
STATUS_TTL seconds; the Kaggle kernel state (`kaggle kernels status`, ~15-20 s
per call) is only ever refreshed in a background thread, at most every
KERNEL_TTL seconds, and only while someone is polling /brains.

Start/stop jobs are `bash -c` scripts detached into their own session (they
survive an alfredd restart, the unit uses KillMode=process) and log to
~/.alfred/brains.log. Their argv[0] is a marker, `alfred-brain-job:<id>:<action>`,
so a /proc cmdline scan finds them again after a restart, along with any
`kaggle-glm start` an alfred-brain chat launched itself.
"""
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import httpx

from . import config

T4_URL = os.environ.get("ALFRED_T4_URL", "http://127.0.0.1:8190")
TPU_URL = config.ALFRED_TPU_URL or "http://127.0.0.1:8193"
KAGGLE_GLM = shutil.which("kaggle-glm") or "/root/.local/bin/kaggle-glm"
QWEN122_TPU = os.environ.get("ALFRED_QWEN122_TPU", "/root/projects/llm-burst/kaggle-tpu/qwen122-tpu")
KAGGLE_STATE = Path(os.environ.get("ALFRED_KAGGLE_STATE", "/var/lib/kaggle-glm"))
LOG_FILE = config.ALFRED_HOME / "brains.log"
JOB_MARK = "alfred-brain-job"

STATUS_TTL = 10.0
KERNEL_TTL = 180.0  # both scripts' status take ~50 s and ~14 s CPU together
PROBE_TIMEOUT = 2.0

DEFAULT = "sonnet"
T4_COLD = "Cold start ~4-10 min on Kaggle 2x T4 and it spends GPU quota; one T4 model runs at a time."

# Order is the order the app shows. kq122 (Qwen3.5-122B on T4) is left out:
# alfred-brain has no kq122 backend and it runs at ~0.8 tok/s on T4.
CATALOG = [
    {"id": "sonnet", "label": "Claude Sonnet 5", "short": "Sonnet", "tier": "proxy", "kaggle_model": None,
     "note": "Default. Best quality and fast, via the Kaggle Benchmarks proxy (daily dollar budget, no GPU quota). Always available."},
    {"id": "khermes", "label": "Qwen3.6-35B-A3B", "short": "khermes", "tier": "t4", "kaggle_model": "qwen36-35b-kaggle",
     "note": "Best T4 model (65/80 blind), uncensored, quick MoE. " + T4_COLD},
    {"id": "kqwen", "label": "Qwen3.8-27B", "short": "kqwen", "tier": "t4", "kaggle_model": "qwen38-kaggle",
     "note": "Dense 27B (40/80 blind), slower than khermes. " + T4_COLD},
    {"id": "kglm", "label": "GLM-4.7-Flash", "short": "kglm", "tier": "t4", "kaggle_model": "glm47-kaggle",
     "note": "Abliterated GLM (38/80 blind). " + T4_COLD},
    {"id": "tpu", "label": "Qwen3.5-122B (TPU)", "short": "TPU", "tier": "tpu", "kaggle_model": None,
     "note": "Largest model, on a Kaggle TPU v5e-8. Cold start 60-90 min and it often queues for TPU capacity. "
             "Chats on this brain use Sonnet until the TPU answers."},
]
BY_ID = {b["id"]: b for b in CATALOG}
IDS = [b["id"] for b in CATALOG]
T4_BY_MODEL = {b["kaggle_model"]: b["id"] for b in CATALOG if b["tier"] == "t4"}


class BrainError(Exception):
    def __init__(self, code: int, detail: str):
        super().__init__(detail)
        self.code = code
        self.detail = detail


# ---------- probes (patched in tests) ----------

# One shared client: building an httpx client per probe costs ~0.4 s here.
_http = httpx.Client(timeout=PROBE_TIMEOUT)
_pool = ThreadPoolExecutor(max_workers=3, thread_name_prefix="brains-probe")

def probe_t4():
    """Model id the T4 tunnel is serving, or None if it doesn't answer."""
    try:
        r = _http.get(f"{T4_URL.rstrip('/')}/v1/models", timeout=PROBE_TIMEOUT)
        if r.status_code == 200:
            return (r.json().get("data") or [{}])[0].get("id") or None
    except Exception:  # noqa: BLE001
        pass
    return None


def probe_tpu() -> bool:
    try:
        return _http.get(f"{TPU_URL.rstrip('/')}/health", timeout=PROBE_TIMEOUT).status_code == 200
    except Exception:  # noqa: BLE001
        return False


def scan_processes():
    """Start/stop work in flight, from /proc: {"t4": {...}, "tpu": {...}}.

    Each entry is {"pid", "brain", "action"}; "brain" is None when it can't be
    told which T4 model a bare `kaggle-glm start` is for."""
    found = {}
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            argv = (p / "cmdline").read_bytes().split(b"\0")
        except OSError:
            continue
        argv = [a.decode(errors="replace") for a in argv if a]
        if not argv:
            continue
        pid = int(p.name)
        # Our jobs are `bash -c SCRIPT MARK`, so the mark is $0 (argv[3]).
        mark = argv[3] if len(argv) >= 4 and argv[1] == "-c" and argv[3].startswith(JOB_MARK + ":") else None
        if mark:
            _, bid, action = (mark.split(":") + ["", ""])[:3]
            tier = BY_ID.get(bid, {}).get("tier")
            if tier in ("t4", "tpu"):
                # Marked jobs win over the bare kaggle-glm/qwen122-tpu child they spawn.
                found[tier] = {"pid": pid, "brain": bid, "action": action, "ours": True}
            continue
        names = [os.path.basename(a) for a in argv[:2]]
        if "kaggle-glm" in names and "start" in argv:
            model = None
            try:
                env = (p / "environ").read_bytes().split(b"\0")
                for e in env:
                    if e.startswith(b"KAGGLE_MODEL="):
                        model = e.split(b"=", 1)[1].decode()
            except OSError:
                pass
            if not found.get("t4", {}).get("ours"):
                found["t4"] = {"pid": pid, "brain": T4_BY_MODEL.get(model or "qwen36-35b-kaggle"),
                               "action": "start", "ours": False}
        elif "qwen122-tpu" in names and "start" in argv:
            if not found.get("tpu", {}).get("ours"):
                found["tpu"] = {"pid": pid, "brain": "tpu", "action": "start", "ours": False}
    return found


def _run_status(cmd):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
        return r.stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def fetch_kernels():
    """Kaggle kernel states via the scripts' own `status` (slow; background only)."""
    out = {}
    m = re.search(r"serve kernel:\s*(\w*)", _run_status([KAGGLE_GLM, "status"]))
    out["t4"] = (m.group(1) if m else "") or None
    m = re.search(r"kernel \S+:\s*(\S+)", _run_status([QWEN122_TPU, "status"]))
    out["tpu"] = None if not m or m.group(1) == "?" else m.group(1)
    return out


def _popen(argv):
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    log = open(LOG_FILE, "ab")
    try:
        return subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                start_new_session=True, env=dict(os.environ))
    finally:
        log.close()


# ---------- state ----------

_lock = threading.Lock()
_cache = {"at": 0.0, "value": None}
_kernels = {"at": 0.0, "value": {}, "refreshing": False}


def invalidate():
    with _lock:
        _cache["at"] = 0.0


def _kick_kernel_refresh():
    with _lock:
        if _kernels["refreshing"] or time.time() - _kernels["at"] < KERNEL_TTL:
            return
        _kernels["refreshing"] = True

    def run():
        try:
            v = fetch_kernels()
            with _lock:
                _kernels["value"] = v
                _kernels["at"] = time.time()
                _cache["at"] = 0.0
        finally:
            with _lock:
                _kernels["refreshing"] = False

    threading.Thread(target=run, daemon=True, name="brains-kernels").start()


def _flag(name: str) -> bool:
    return (KAGGLE_STATE / name).exists()


def _t4_config_model():
    try:
        return (KAGGLE_STATE / "config-model").read_text().split()[0]
    except (OSError, IndexError):
        return None


MIN_GPU_LEFT_H = 0.5
QUOTA_NAME = "quota.json"  # written by kaggle-quota (cron every 15 min), under KAGGLE_STATE


def quota():
    """Weekly Kaggle accelerator quota in hours, or None if never fetched."""
    try:
        f = KAGGLE_STATE / QUOTA_NAME
        q = json.loads(f.read_text())
        q["checked"] = f.stat().st_mtime
        return q
    except Exception:
        return None


def compute():
    # In parallel, so a slow tunnel costs at most one PROBE_TIMEOUT.
    f_t4, f_tpu, f_procs = _pool.submit(probe_t4), _pool.submit(probe_tpu), _pool.submit(scan_processes)
    loaded, tpu_up, procs = f_t4.result(), f_tpu.result(), f_procs.result()
    with _lock:
        kern = dict(_kernels["value"])
        kern_at = _kernels["at"]
    t4_stop, tpu_stop = _flag("stop"), _flag("stop-qwen122")
    t4_job, tpu_job = procs.get("t4"), procs.get("tpu")

    brains = []
    for b in CATALOG:
        status, detail = "down", None
        if b["tier"] == "proxy":
            status, detail = "up", "always available"
        elif b["tier"] == "t4":
            km = b["kaggle_model"]
            if loaded == km:
                status = "up"
                if t4_stop or (t4_job and t4_job["action"] == "stop"):
                    status, detail = "stopping", "stop requested"
                elif t4_job and t4_job["action"] == "replace" and t4_job["brain"] != b["id"]:
                    status, detail = "stopping", f"being replaced by {t4_job['brain']}"
            elif t4_job and t4_job["brain"] == b["id"] and t4_job["action"] in ("start", "replace"):
                status = "starting"
                detail = "waiting for the Kaggle T4 session" if t4_job["action"] == "start" else \
                    "stopping the other T4 model first"
            elif loaded is None and kern.get("t4") in ("queued", "running") and _t4_config_model() == km \
                    and not t4_stop:
                status, detail = "starting", f"kernel {kern['t4']}, tunnel not up yet"
        else:  # tpu
            if tpu_up:
                status = "stopping" if tpu_stop else "up"
                detail = "stop requested" if tpu_stop else None
            elif tpu_job and tpu_job["action"] == "start":
                status, detail = "starting", "kernel pushed, waiting for the TPU (60-90 min)"
            elif kern.get("tpu") in ("queued", "running") and not tpu_stop:
                status = "starting"
                detail = "queued for TPU capacity" if kern["tpu"] == "queued" else "kernel running, loading weights"
        entry = {k: b[k] for k in ("id", "label", "short", "tier", "note")}
        entry.update({"status": status, "detail": detail, "controllable": b["tier"] in ("t4", "tpu"),
                      "kernel": kern.get(b["tier"]) if b["tier"] in ("t4", "tpu") else None,
                      "default": b["id"] == DEFAULT})
        brains.append(entry)
    return {
        "default": DEFAULT,
        "t4_loaded": T4_BY_MODEL.get(loaded, loaded) if loaded else None,
        "t4_loaded_model": loaded,
        "kernels_checked": kern_at or None,
        "checked": time.time(),
        "brains": brains,
        "quota": quota(),
    }


def status(force: bool = False) -> dict:
    _kick_kernel_refresh()
    with _lock:
        if not force and _cache["value"] is not None and time.time() - _cache["at"] < STATUS_TTL:
            return _cache["value"]
    v = compute()
    with _lock:
        _cache.update(at=time.time(), value=v)
    return v


def _entry(snapshot, bid):
    return next(b for b in snapshot["brains"] if b["id"] == bid)


def _launch(bid: str, action: str, script: str):
    proc = _popen(["bash", "-c", f"echo \"== $(date -Is) {bid} {action}\"; {script}",
                   f"{JOB_MARK}:{bid}:{action}"])
    invalidate()
    return {"ok": True, "id": bid, "action": action, "pid": proc.pid, "log": str(LOG_FILE)}


def _require(bid: str) -> dict:
    b = BY_ID.get(bid)
    if not b:
        raise BrainError(404, f"unknown brain {bid!r}")
    if b["tier"] == "proxy":
        raise BrainError(400, f"{bid} is always available; nothing to start or stop")
    return b


def start(bid: str, replace: bool = False) -> dict:
    b = _require(bid)
    snap = status(force=True)
    me = _entry(snap, bid)
    if me["status"] in ("up", "starting"):
        return {"ok": True, "id": bid, "action": "none", "status": me["status"], "detail": f"already {me['status']}"}
    if b["tier"] == "tpu":
        return _launch(bid, "start", f"{shlex.quote(QWEN122_TPU)} start --wait")

    q = quota()
    left = (q or {}).get("gpu", {}).get("left_h")
    if left is not None and left < MIN_GPU_LEFT_H:
        raise BrainError(429, f"Kaggle GPU quota is used up for this week ({left}h left); "
                              f"it resets {q.get('refresh')}. Use Sonnet or the TPU meanwhile.")
    km = b["kaggle_model"]
    start_cmd = f"KAGGLE_MODEL={shlex.quote(km)} {shlex.quote(KAGGLE_GLM)} start --wait"
    others = [x for x in snap["brains"] if x["tier"] == "t4" and x["id"] != bid
              and x["status"] in ("up", "starting", "stopping")]
    if not others and snap["t4_loaded_model"] and snap["t4_loaded_model"] not in T4_BY_MODEL:
        others = [{"id": snap["t4_loaded_model"], "status": "up"}]  # e.g. kq122 started by hand
    if not others:
        return _launch(bid, "start", start_cmd)
    busy = ", ".join(f"{x['id']} ({x['status']})" for x in others)
    if not replace:
        raise BrainError(409, f"another T4 model is active: {busy}. Only one T4 model runs at a time; "
                              f"pass replace=1 to stop it and start {bid}.")
    # Stop, wait for the tunnel to drop and the kernel to end (kaggle-glm start
    # refuses to switch model while the old kernel is queued/running), then start.
    kg = shlex.quote(KAGGLE_GLM)
    script = (
        f"{kg} stop; "
        f"for i in $(seq 60); do curl -sf -m 3 {shlex.quote(T4_URL)}/health >/dev/null || break; sleep 5; done; "
        f"for i in $(seq 40); do {kg} status | grep -qE 'serve kernel: (queued|running)' || break; sleep 15; done; "
        f"{start_cmd}"
    )
    return _launch(bid, "replace", script)


def stop(bid: str) -> dict:
    b = _require(bid)
    snap = status(force=True)
    me = _entry(snap, bid)
    if me["status"] == "down":
        raise BrainError(409, f"{bid} is not running")
    procs = scan_processes()
    job = procs.get(b["tier"])
    if job and job.get("ours") and job["brain"] == bid and job["action"] in ("start", "replace"):
        # Our own detached start job: end its process group (and only it).
        try:
            os.killpg(job["pid"], signal.SIGTERM)
        except OSError:
            pass
    cmd = QWEN122_TPU if b["tier"] == "tpu" else KAGGLE_GLM
    return _launch(bid, "stop", f"{shlex.quote(cmd)} stop")
