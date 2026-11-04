"""Serve Alfred TTS (Kokoro-82M + Kyutai Pocket-TTS) on a free Kaggle CPU session.

Runs as a Kaggle script kernel (pushed by `alfred-tts-kaggle start`). No
accelerator is requested: both engines are CPU-only. The app is reached from
the box over a reverse SSH tunnel, so nothing listens publicly:

    box 127.0.0.1:8195  <-ssh -R-  Kaggle 127.0.0.1:8099 (uvicorn/app.py)

Shares the kagglefwd tunnel login and key dataset used by the T4/TPU tiers
(see /root/projects/llm-burst/kaggle/box-setup.sh), box port 8195, forced
command argument "alfred-tts" -> its own stop file
/var/lib/kaggle-glm/stop-alfred-tts. That file not existing is the normal
running state; `alfred-tts-kaggle stop` creates it.

app.py's full source is embedded below (APP_SRC) so this kernel is a single
self-contained script: Kaggle's script-kernel push only uploads one code
file, and the FastAPI app itself lives in the project repo, not in a Kaggle
dataset, so the launcher inlines it at push time.
"""
import os
import subprocess
import sys
import threading
import time
import urllib.request

T0 = time.monotonic()


def log(msg: str) -> None:
    print(f"[{time.monotonic() - T0:7.1f}s] {msg}", flush=True)


CFG = None  # __LAUNCHER_CONFIG__ substituted by alfred-tts-kaggle at push time
APP_SRC = ""  # __APP_SRC__ substituted by alfred-tts-kaggle at push time

KEY = CFG["api_key"]
IDLE_MIN = float(CFG.get("idle_min", 60))
TUN = CFG["ssh_tunnel"]
PORT = 8099  # local uvicorn port inside the Kaggle session

# --- write app.py + install deps --------------------------------------------
APP_DIR = "/tmp/alfred-tts-app"
os.makedirs(APP_DIR, exist_ok=True)
with open(os.path.join(APP_DIR, "app.py"), "w") as f:
    f.write(APP_SRC)

log("apt-get espeak-ng + ffmpeg (best effort, Kaggle images usually ship ffmpeg)")
subprocess.run("apt-get update -qq && apt-get install -y -qq espeak-ng ffmpeg", shell=True)

log("pip install missing packages (torch/soundfile/huggingface_hub usually preinstalled)")
# No hard version pin on kokoro/misaki: the box's requirements.txt pins
# kokoro==0.9.4, but that release requires Python <3.13 and Kaggle's base
# image ships Python 3.13, so let pip resolve the newest compatible release.
#
# `pip install spacy` on its own installs fine from a wheel in ~5s (verified
# in kernel v4's log). The failure only appears once kokoro is in the same
# resolve: kokoro's metadata hard-requires "misaki[en]>=0.9.4" (not optional
# on kokoro's side), and misaki's "en" extra pulls in
# spacy-curated-transformers, which needs thinc>=9.0.0.dev4 -- incompatible
# with the thinc 8.x line current spacy actually runs on. To satisfy both
# constraints at once, pip's resolver backtracks spacy to some old/dev
# release with no built wheel at all, and building THAT from source is what
# fails ("installing build dependencies for spacy did not run successfully").
# misaki/en.py only ever does `import spacy` (confirmed: no "curated"/
# "transformers" string in its source) -- spacy-curated-transformers is
# genuinely unused here. Fix: install kokoro with --no-deps so pip never
# sees the misaki[en] constraint, then install kokoro's and misaki's real
# runtime deps ourselves (plain "spacy", not the "[en]" extra).
pip_kokoro = subprocess.run(
    [sys.executable, "-m", "pip", "install", "-q", "--no-deps", "kokoro"],
    capture_output=True, text=True,
)
if pip_kokoro.returncode != 0:
    log(f"kokoro --no-deps install failed:\n{pip_kokoro.stdout[-4000:]}\n{pip_kokoro.stderr[-2000:]}")
    sys.exit(1)

pip = subprocess.run(
    [sys.executable, "-m", "pip", "install", "-q", "--prefer-binary",
     "fastapi>=0.110", "uvicorn[standard]>=0.30", "pydantic>=2", "soundfile>=0.12",
     "huggingface_hub>=0.25", "loguru", "numpy", "torch", "transformers",
     "misaki", "spacy", "num2words", "espeakng-loader", "phonemizer-fork",
     "pocket-tts"],
    capture_output=True, text=True,
)
if pip.returncode != 0:
    log(f"pip install failed:\n{pip.stdout[-4000:]}\n{pip.stderr[-2000:]}")
    sys.exit(1)
log("deps ready")

log("compat shim: the only kokoro build that installs on Kaggle's Python 3.13")
log("image is 0.7.16 (0.8.1-0.9.4 all require <3.13); 0.7.16 predates the")
log("repo_id= kwarg that app.py passes to KModel/KPipeline, so wrap both")
log("constructors to accept and drop it (0.7.16 hardcodes the same repo via")
log("KModel.REPO_ID, so dropping repo_id changes no behavior).")
import kokoro as _kokoro  # noqa: E402

_OrigKModel = _kokoro.KModel
_OrigKPipeline = _kokoro.KPipeline


class _KModelCompat(_OrigKModel):
    def __init__(self, *args, repo_id=None, **kwargs):
        super().__init__(*args, **kwargs)


class _KPipelineCompat(_OrigKPipeline):
    def __init__(self, *args, repo_id=None, **kwargs):
        super().__init__(*args, **kwargs)


_kokoro.KModel = _KModelCompat
_kokoro.KPipeline = _KPipelineCompat

os.environ["ALFRED_TTS_KEY"] = KEY
sys.path.insert(0, APP_DIR)
import app as alfred_app  # noqa: E402

fastapi_app = alfred_app.app

# --- activity tracking (drives the idle watchdog, no app.py changes needed) -
_last_activity = {"t": time.monotonic()}


@fastapi_app.middleware("http")
async def _track_activity(request, call_next):
    _last_activity["t"] = time.monotonic()
    return await call_next(request)


# --- run the app in a background thread -------------------------------------
import uvicorn  # noqa: E402

config = uvicorn.Config(fastapi_app, host="127.0.0.1", port=PORT, log_level="info")
server = uvicorn.Server(config)
server_thread = threading.Thread(target=server.run, daemon=True)
server_thread.start()

t0 = time.monotonic()
while True:
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health", timeout=3)
        break
    except Exception:
        if time.monotonic() - t0 > 600:
            sys.exit("app never came up locally (model load failed?)")
        time.sleep(3)
log(f"app ready after {time.monotonic() - t0:.1f}s (model load + startup warm)")

# --- tunnel credentials ------------------------------------------------------
import glob  # noqa: E402
import shutil  # noqa: E402


def find_one(pattern: str) -> str:
    hits = sorted(glob.glob(f"/kaggle/input/**/{pattern}", recursive=True))
    if not hits:
        sys.exit(f"missing input: no {pattern} under /kaggle/input")
    return hits[0]


ssh_dir = "/tmp/alfred-tts-ssh"
os.makedirs(ssh_dir, mode=0o700, exist_ok=True)
key_path = os.path.join(ssh_dir, "id")
shutil.copy(find_one("kaggle-glm-key"), key_path)
os.chmod(key_path, 0o600)
known_hosts = os.path.join(ssh_dir, "known_hosts")
shutil.copy(find_one("kaggle-glm-known-hosts"), known_hosts)

stop = threading.Event()


def tunnel() -> None:
    while not stop.is_set():
        t = subprocess.Popen(
            [
                "ssh", "-i", key_path, "-T",
                "-o", f"UserKnownHostsFile={known_hosts}",
                "-o", "StrictHostKeyChecking=yes",
                "-o", "ExitOnForwardFailure=yes",
                "-o", "ServerAliveInterval=20",
                "-o", "ServerAliveCountMax=3",
                "-R", f"127.0.0.1:{TUN['remote_port']}:127.0.0.1:{PORT}",
                f"{TUN['user']}@{TUN['box']}", TUN["command"],
            ],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        log("tunnel connecting")
        for line in t.stdout:
            line = line.strip()
            if line == "STOP":
                log("box requested stop")
                stop.set()
            elif line:
                log(f"ssh: {line}")
        t.wait()
        if not stop.is_set():
            log(f"tunnel dropped (rc={t.returncode}), reconnecting in 10s")
            stop.wait(10)


threading.Thread(target=tunnel, daemon=True).start()

# --- idle watchdog ------------------------------------------------------------
while not stop.is_set():
    stop.wait(30)
    if not server_thread.is_alive():
        log("uvicorn thread died")
        break
    idle_s = time.monotonic() - _last_activity["t"]
    if idle_s > IDLE_MIN * 60:
        log(f"idle {IDLE_MIN:.0f} min, shutting down")
        break

stop.set()
log("done")
os._exit(0)
