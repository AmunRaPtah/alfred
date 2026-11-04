# Alfred TTS

CPU-only, scale-to-zero web endpoint on **Modal** serving two TTS engines
behind one FastAPI app for the Alfred assistant.

This was originally built as a private Hugging Face Docker Space (see
`Dockerfile`, kept for reference / local docker runs). It moved to Modal
because HF now requires a **PRO** subscription to deploy Docker/Gradio
Spaces on the free `cpu-basic` tier: the Space creation call returns
HTTP 402 without it. Modal's CPU containers need no paid tier, bill only
while a request is being served, and scale to zero when idle, so the same
`app.py` runs there almost unchanged.

The two engines:

- **Kokoro** - `hexgrad/Kokoro-82M` via the `kokoro` pip package (`KPipeline`).
  Needs the `espeak-ng` apt package (installed in the Dockerfile) as a G2P
  fallback for English.
- **Pocket** - Kyutai's `pocket-tts` (`kyutai-labs/pocket-tts`), a ~100M-param
  CPU-native TTS model.

Both run on CPU; no GPU hardware is requested.

## API

- `GET /health` -> `{"ok": true}` (no auth)
- `GET /voices` -> `{"kokoro": [...], "pocket": [...]}` (no auth)
- `POST /tts` (requires `X-Alfred-Key` header, see Auth below)
  ```json
  {"text": "...", "voice": "af_heart", "engine": "kokoro", "speed": 1.0, "format": "mp3"}
  ```
  `text` <= 1000 chars. `engine` is `"kokoro"` (default) or `"pocket"`.
  `format` is `"mp3"` (default, via ffmpeg, 24kHz mono - small enough for
  phone bandwidth) or `"wav"`. `speed` only affects Kokoro; Pocket-TTS has no
  speed knob and the parameter is ignored (logged) for that engine.

  Voice ids:
  - Kokoro: `af_*`/`am_*` (American English), `bf_*`/`bm_*` (British English),
    e.g. `af_heart`, `am_michael`, `bf_emma`, `bm_george`. Full list served
    live from `/voices` (read from the model repo's `voices/` listing at
    startup, with a hardcoded fallback if that hub call fails).
  - Pocket: `alba`, `giovanni`, `lola`, `juergen`, `rafael`, `estelle`,
    `anna`, `azelma`, `bill_boerst`, `caro_davy`, `charles`, `cosette`,
    `eponine`, `eve`, `fantine`, `george`, `jane`, `jean`, `javert`,
    `marius`, `mary`, `michael`, `paul`, `peter_yearsley`, `stuart_bell`,
    `vera`, `daan`. Taken directly from
    `pocket_tts.utils.utils._ORIGINS_OF_PREDEFINED_VOICES` in the installed
    package, not from memory.

## Auth: `X-Alfred-Key`

The Modal endpoint has no built-in private-Space-style proxy auth, so there
is a single app-level secret: `ALFRED_TTS_KEY`, a random token stored as a
Modal Secret (`alfred-tts-key`) and checked by `app.py` on every `POST /tts`
via the `X-Alfred-Key` header. `/health` and `/voices` do not check it.

```
X-Alfred-Key: <ALFRED_TTS_KEY>        # app-level auth, checked by app.py on POST /tts
```

The old HF-era design additionally needed `Authorization: Bearer <hf_token>`
because that Space was private and HF's own proxy consumed that header
before the request ever reached `app.py`. Modal has no equivalent second
hop, so that header is gone; `alfred-tts` (the CLI wrapper) only sends it if
`/root/.alfred/tts.json` still has an `hf_token_item` key, kept for backward
compatibility with any other host of this same app.

The config is recorded in `/root/.alfred/tts.json` (chmod 600):
```json
{
  "url": "https://<workspace>--alfred-tts-web.modal.run",
  "key": "<ALFRED_TTS_KEY>",
  "engines": ["kokoro", "pocket"],
  "default_engine": "kokoro",
  "default_voice": "bm_george"
}
```

## Deploy (Modal)

```
cd /root/projects/alfred/tts-space
modal secret create alfred-tts-key ALFRED_TTS_KEY="$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')"
modal deploy modal_app.py
```

`modal_app.py` builds one image: `debian_slim` + `espeak-ng`/`ffmpeg` (apt)
+ the same pinned CPU-torch/kokoro/pocket-tts stack as `requirements.txt`,
then runs `_prefetch_models()` as an `Image.run_function` build step so the
Kokoro and Pocket-TTS weights and the voices used in the box's A/B are
downloaded once at build time and baked into the image layer under
`HF_HOME=/opt/hf-cache`. `app.py` is added unmodified via
`add_local_file`. The function is `min_containers=0` with
`scaledown_window=120` (CPU only, no GPU anywhere), so it costs nothing
while idle and tears down ~2 minutes after the last request.

After `modal deploy`, grab the printed `*.modal.run` URL and write it (plus
the secret's value, fetched once from the Modal secret, never echoed) into
`/root/.alfred/tts.json`.

## Scale-to-zero cold start

With `min_containers=0`, the first request after an idle period pays full
container start plus both models loading from the baked-in cache (no
network, since weights are already in the image). See the latency numbers
recorded the last time this was measured for the actual cold vs. warm
figures on this deploy. Subsequent requests inside the `scaledown_window`
are warm.

## Kaggle CPU host (fallback when Modal/HF are unavailable)

Modal and HF Spaces are both currently blocked (Modal over its spend limit,
HF Spaces returning 402 without a PRO subscription), so there is a second
host: a free Kaggle CPU **script kernel**, reached over the same reverse-SSH
tunnel pattern used by the `llm-burst` project's Kaggle hosts
(`/root/projects/llm-burst/kaggle/`, `kaggle-tpu/`). Launcher:
`/root/projects/alfred/tts-space/kaggle/alfred-tts-kaggle` (`start [--wait]`,
`stop`, `status`, `output`, `dry-run`). It embeds this directory's `app.py`
verbatim into a generated kernel script (`serve_tts.py`) at push time, so
`app.py` itself stays unmodified and remains the single cross-host source of
truth.

No accelerator is requested (CPU script kernel). Reached on the box at
`http://127.0.0.1:8195` (port 8195) via the existing `kagglefwd` reverse
tunnel; `/root/.alfred/tts.json` is written automatically on a successful
`start`, with `"host": "kaggle-cpu"`.

**Python-3.13 dependency note**: Kaggle's base image runs Python 3.13.
`kokoro`'s own PyPI metadata unconditionally requires `misaki[en]>=0.9.4`,
and misaki's `en` extra pulls in `spacy-curated-transformers`, which
conflicts with the `thinc` version plain `spacy` needs - this forces pip to
backtrack `spacy` itself to a wheel-less release and fail building it from
source. Worse, `kokoro` 0.8.1-0.9.4 all require Python `<3.13`, so an
unpinned install on Kaggle resolves to `kokoro==0.7.16`, whose `KModel`/
`KPipeline` constructors predate the `repo_id=` keyword `app.py` passes.
`serve_tts.py` works around both: it installs `kokoro` with `--no-deps` plus
the real runtime deps listed explicitly (plain `misaki`/`spacy`, not the
`[en]`/`en` extras), then monkeypatches `kokoro.KModel`/`kokoro.KPipeline`
to accept and drop a `repo_id` kwarg before importing `app.py` - `app.py`
itself needs no changes.

**12-hour session limit**: Kaggle kills any kernel after 12 hours regardless
of activity. When that happens (or after any other interruption), restart
with:

```
cd /root/projects/alfred/tts-space/kaggle
python3 alfred-tts-kaggle start --wait   # run as a background task; usually
                                          # takes 1-3 min for the tunnel to
                                          # come up, can exceed a 2 min
                                          # foreground timeout
python3 alfred-tts-kaggle status         # confirms "tunnel: UP 127.0.0.1:8195"
python3 alfred-tts-kaggle output          # kernel log, if something fails
```

`stop` tears down the kernel/tunnel cleanly; `dry-run` builds the kernel
script without pushing, for inspecting what would be sent.

This CPU kernel has been confirmed to run concurrently with the other
Kaggle kernels used on this box (the GPU `alfred-voice-ab` kernel and the
TPU `llm-burst-qwen122-tpu` kernel) without any conflict - Kaggle allows
multiple kernels of different accelerator types to run at once.

## Files

- `Dockerfile` - kept for reference / local docker runs; not used by the
  Modal deploy (`modal_app.py` builds its own image from the same package
  list).
- `modal_app.py` - Modal App: image build (incl. baked-in model weights),
  `@modal.asgi_app` wrapping `app.py`'s FastAPI instance, `alfred-tts-key`
  Modal Secret for `ALFRED_TTS_KEY`.
- `app.py` - FastAPI app, both engines, startup preload.
- `requirements.txt` - pinned CPU torch via `--extra-index-url
  https://download.pytorch.org/whl/cpu`, kokoro, misaki[en], pocket-tts
  (reference for `modal_app.py`'s image build and for local docker runs).
