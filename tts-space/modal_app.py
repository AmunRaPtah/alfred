"""Alfred TTS on Modal: CPU-only, scale-to-zero web endpoint wrapping the
FastAPI app in app.py (Kokoro-82M + Kyutai Pocket-TTS).

Why Modal instead of Hugging Face: this was originally built as an HF Docker
Space, but HF now requires a PRO subscription to run Docker/Gradio Spaces on
the free `cpu-basic` tier (the deploy call returns HTTP 402). Modal's CPU
containers need no paid tier and scale to zero, so the same app.py moved here
almost unchanged.

Deploy:

    modal deploy modal_app.py

Cost discipline:
  * No GPU anywhere in this file; the image, the function, and both TTS
    engines run on CPU only.
  * `min_containers=0`: nothing stays warm, so idle cost is zero.
  * `scaledown_window=120`: short idle tail before the container is torn
    down, since Alfred's traffic is bursty voice requests, not a steady
    stream.
  * Model weights (Kokoro + both Kokoro voice packs used by the box, and the
    Pocket-TTS model + voice embeddings used in the A/B) are downloaded
    inside `_prefetch_models`, which runs once at image *build* time via
    `Image.run_function`. They land under `HF_HOME` inside the image layer,
    so a cold start loads from local disk instead of re-downloading from the
    Hub on every scale-from-zero.
"""

import os

import modal

TTS_DIR = os.path.dirname(os.path.abspath(__file__))

APP_NAME = "alfred-tts"
HF_HOME = "/opt/hf-cache"

# Kokoro voices actually exercised by this box's A/B (both genders/langs we
# use) plus Pocket voices for the A/B. Preloading these at build time avoids
# a Hub round-trip on cold start; any other voice still works, it just pays
# a one-time download the first time it's requested.
KOKORO_PREFETCH_VOICES = ["af_heart", "bm_george"]
POCKET_PREFETCH_VOICES = ["alba", "george", "juergen", "rafael"]


def _prefetch_models():
    """Runs once at image build time (CPU only) to bake model weights and
    voice embeddings into the image, so cold start never hits the network."""
    import torch

    from kokoro import KModel, KPipeline

    kokoro_model = KModel(repo_id="hexgrad/Kokoro-82M").to("cpu").eval()
    for voice in KOKORO_PREFETCH_VOICES:
        lang = "b" if voice.startswith("b") else "a"
        pipeline = KPipeline(
            lang_code=lang, repo_id="hexgrad/Kokoro-82M", model=kokoro_model
        )
        for _ in pipeline("Warming up.", voice=voice, speed=1.0):
            pass

    from pocket_tts import TTSModel

    pocket_model = TTSModel.load_model(language="english")
    for voice in POCKET_PREFETCH_VOICES:
        pocket_model.get_state_for_audio_prompt(voice)

    print("prefetch done: kokoro + pocket weights and voices cached")


image = (
    modal.Image.debian_slim(python_version="3.11")
    .apt_install("espeak-ng", "ffmpeg", "git")
    .env({"HF_HOME": HF_HOME, "PYTHONUNBUFFERED": "1"})
    .pip_install(
        "torch==2.5.1",
        "fastapi>=0.110",
        "uvicorn[standard]>=0.30",
        "pydantic>=2",
        "numpy>=2",
        "soundfile>=0.12",
        "huggingface_hub>=0.25",
        "loguru",
        "kokoro==0.9.4",
        "misaki[en]>=0.9.4",
        "pocket-tts",
        extra_index_url="https://download.pytorch.org/whl/cpu",
    )
    .run_function(_prefetch_models)
    .add_local_file(os.path.join(TTS_DIR, "app.py"), "/app/app.py", copy=True)
)

app = modal.App(APP_NAME, image=image)


@app.function(
    min_containers=0,
    scaledown_window=120,
    timeout=300,
    cpu=2,
    memory=4096,
    secrets=[modal.Secret.from_name("alfred-tts-key")],
)
@modal.concurrent(max_inputs=4)
@modal.asgi_app()
def web():
    import sys

    sys.path.insert(0, "/app")
    from app import app as fastapi_app  # noqa: E402  (app.py's FastAPI instance)

    return fastapi_app
