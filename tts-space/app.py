"""Alfred TTS Space: Kokoro-82M + Kyutai Pocket-TTS behind one FastAPI app.

Endpoints:
  GET  /health                 -> {"ok": true}            (no auth)
  GET  /voices                 -> {"kokoro": [...], "pocket": [...]}  (no auth)
  POST /tts                    -> audio bytes              (requires app secret)

Auth for POST /tts: header `X-Alfred-Key: <ALFRED_TTS_KEY>`. We use a
dedicated header rather than `Authorization: Bearer` because this Space is
private: HF's own proxy already consumes `Authorization: Bearer <hf_token>`
to authorize the caller onto the private Space in the first place, so a
second, app-level secret cannot also live in that header. See README.md.
"""
import io
import logging
import os
import subprocess
import time

import numpy as np
import soundfile as sf
import torch
from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel, Field

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("alfred-tts")

APP_SECRET = os.environ.get("ALFRED_TTS_KEY")

app = FastAPI(title="Alfred TTS")

# ----------------------------------------------------------------------------
# Kokoro-82M
# ----------------------------------------------------------------------------
from kokoro import KModel, KPipeline  # noqa: E402

KOKORO_REPO = "hexgrad/Kokoro-82M"
DEFAULT_KOKORO_VOICE = "af_heart"

_kokoro_model: "KModel | None" = None
_kokoro_pipelines: dict[str, "KPipeline"] = {}  # lang_code -> pipeline
KOKORO_VOICES: list[str] = []


def _kokoro_lang_for_voice(voice: str) -> str:
    # Kokoro voice ids are "<lang><sex>_<name>", e.g. af_heart (American
    # Female), bm_george (British Male). First letter selects the G2P lang.
    return "b" if voice.startswith("b") else "a"


def _get_kokoro_pipeline(voice: str) -> "KPipeline":
    lang = _kokoro_lang_for_voice(voice)
    if lang not in _kokoro_pipelines:
        _kokoro_pipelines[lang] = KPipeline(
            lang_code=lang, repo_id=KOKORO_REPO, model=_kokoro_model
        )
    return _kokoro_pipelines[lang]


def synth_kokoro(text: str, voice: str, speed: float) -> tuple[np.ndarray, int]:
    pipeline = _get_kokoro_pipeline(voice)
    chunks = []
    for result in pipeline(text, voice=voice, speed=speed):
        if result.audio is not None:
            chunks.append(result.audio)
    if not chunks:
        raise RuntimeError("kokoro produced no audio")
    audio = chunks[0] if len(chunks) == 1 else torch.cat(chunks, dim=0)
    return audio.numpy(), 24000


# ----------------------------------------------------------------------------
# Kyutai Pocket-TTS
# ----------------------------------------------------------------------------
from pocket_tts import TTSModel  # noqa: E402

DEFAULT_POCKET_VOICE = "alba"

# Authoritative list taken from pocket_tts.utils.utils._ORIGINS_OF_PREDEFINED_VOICES
# (English config) at the installed package version, not from memory.
POCKET_VOICES: list[str] = [
    "alba", "giovanni", "lola", "juergen", "rafael", "estelle", "anna",
    "azelma", "bill_boerst", "caro_davy", "charles", "cosette", "eponine",
    "eve", "fantine", "george", "jane", "jean", "javert", "marius", "mary",
    "michael", "paul", "peter_yearsley", "stuart_bell", "vera", "daan",
]

_pocket_model: "TTSModel | None" = None
_pocket_states: dict = {}


def _get_pocket_state(voice: str):
    if voice not in _pocket_states:
        _pocket_states[voice] = _pocket_model.get_state_for_audio_prompt(voice)
    return _pocket_states[voice]


def synth_pocket(text: str, voice: str, speed: float) -> tuple[np.ndarray, int]:
    if speed != 1.0:
        log.warning("pocket-tts has no speed control; ignoring speed=%s", speed)
    state = _get_pocket_state(voice)
    audio = _pocket_model.generate_audio(state, text)
    arr = audio.squeeze().cpu().numpy()
    return arr, _pocket_model.sample_rate


# ----------------------------------------------------------------------------
# Startup: preload models + one default voice per engine. Everything else
# (other voices, the other language pipeline) warms lazily on first use.
# ----------------------------------------------------------------------------
@app.on_event("startup")
def _startup():
    global _kokoro_model, _pocket_model, KOKORO_VOICES

    log.info("loading Kokoro-82M model...")
    t0 = time.time()
    _kokoro_model = KModel(repo_id=KOKORO_REPO).to("cpu").eval()
    _get_kokoro_pipeline(DEFAULT_KOKORO_VOICE)
    # Warm the default voice so first real request doesn't pay the
    # voice-pack download + first-inference cost.
    try:
        next(iter(_get_kokoro_pipeline(DEFAULT_KOKORO_VOICE)("Hello.", voice=DEFAULT_KOKORO_VOICE)))
    except StopIteration:
        pass
    log.info("Kokoro ready in %.1fs", time.time() - t0)

    try:
        from huggingface_hub import list_repo_files

        files = list_repo_files(KOKORO_REPO)
        KOKORO_VOICES = sorted(
            f.split("/")[-1][: -len(".pt")]
            for f in files
            if f.startswith("voices/") and f.endswith(".pt")
        )
    except Exception as e:  # pragma: no cover - network best effort
        log.warning("could not list kokoro voices from hub (%s), using fallback list", e)
        KOKORO_VOICES = [
            "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica",
            "af_kore", "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky",
            "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam",
            "am_michael", "am_onyx", "am_puck", "am_santa",
            "bf_alice", "bf_emma", "bf_isabella", "bf_lily",
            "bm_daniel", "bm_fable", "bm_george", "bm_lewis",
        ]

    log.info("loading Pocket-TTS model...")
    t0 = time.time()
    _pocket_model = TTSModel.load_model(language="english")
    _get_pocket_state(DEFAULT_POCKET_VOICE)
    log.info("Pocket-TTS ready in %.1fs", time.time() - t0)


# ----------------------------------------------------------------------------
# API
# ----------------------------------------------------------------------------
class TTSRequest(BaseModel):
    text: str = Field(..., max_length=1000)
    voice: str = DEFAULT_KOKORO_VOICE
    engine: str = "kokoro"
    speed: float = 1.0
    format: str = "mp3"


def require_app_key(x_alfred_key: str | None = Header(None, alias="X-Alfred-Key")):
    if not APP_SECRET:
        raise HTTPException(500, "server misconfigured: ALFRED_TTS_KEY not set")
    if x_alfred_key != APP_SECRET:
        raise HTTPException(401, "unauthorized")


@app.get("/health")
def health():
    return {"ok": True}


@app.get("/voices")
def voices():
    return {"kokoro": KOKORO_VOICES, "pocket": POCKET_VOICES}


def _encode(audio: np.ndarray, sr: int, fmt: str) -> tuple[bytes, str]:
    wav_buf = io.BytesIO()
    sf.write(wav_buf, audio, sr, format="WAV")
    if fmt == "wav":
        return wav_buf.getvalue(), "audio/wav"
    if fmt == "mp3":
        proc = subprocess.run(
            ["ffmpeg", "-loglevel", "error", "-i", "-", "-ar", "24000", "-ac", "1", "-f", "mp3", "-"],
            input=wav_buf.getvalue(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if proc.returncode != 0:
            raise HTTPException(500, f"ffmpeg encode failed: {proc.stderr.decode(errors='ignore')[:500]}")
        return proc.stdout, "audio/mpeg"
    raise HTTPException(400, "format must be 'mp3' or 'wav'")


@app.post("/tts", dependencies=[Depends(require_app_key)])
def tts(req: TTSRequest):
    if not req.text.strip():
        raise HTTPException(400, "text is empty")
    if req.engine == "kokoro":
        if req.voice not in KOKORO_VOICES:
            raise HTTPException(400, f"unknown kokoro voice {req.voice!r}")
        audio, sr = synth_kokoro(req.text, req.voice, req.speed)
    elif req.engine == "pocket":
        if req.voice not in POCKET_VOICES:
            raise HTTPException(400, f"unknown pocket voice {req.voice!r}")
        audio, sr = synth_pocket(req.text, req.voice, req.speed)
    else:
        raise HTTPException(400, f"unknown engine {req.engine!r}, expected 'kokoro' or 'pocket'")

    data, media_type = _encode(audio, sr, req.format)
    return Response(content=data, media_type=media_type)
