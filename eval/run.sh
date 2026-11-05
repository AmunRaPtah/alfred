#!/bin/bash
# Entry point for the Alfred eval suite. Starts the backend's Kaggle session
# (if the backend uses one), runs run_eval.py against it, and ALWAYS stops
# the session on exit (success, failure, or Ctrl-C) so GPU quota is not
# left burning. Direct kaggle-glm start/stop belongs here, not in
# run_eval.py, so one session is reused across all 20 tasks.
#
# Usage:
#   ./run.sh                      # backend=kqwen (default)
#   ALFRED_BACKEND=kglm ./run.sh
#   ./run.sh --backend kq122 --only tool_create_files,instr_exact_format
#   ./run.sh --backend qwen122-tpu   # TPU session must already be up
#
# Non-Kaggle backends (anything not in kqwen/kglm/kq122) skip the
# kaggle-glm start/stop entirely, e.g. a future TPU tier or the always-on
# Modal burst tier (./run.sh --backend burst-qwen38-27b).
#
# Frontier models via the Kaggle Benchmarks Model Proxy ($10/day, $100/mo
# quota; check with `kaggle benchmarks quota`): ./run.sh --backend
# kbench-<slug>, e.g. kbench-claude-sonnet-5, kbench-gemini-flash,
# kbench-gemini-flash-lite, kbench-gpt-oss-120b, kbench-gpt-nano,
# kbench-deepseek-r1, kbench-qwen3-next, kbench-granite. These are plain
# BURST_MODEL passthroughs (no Kaggle session start/stop here); claude-burst
# recognizes the kbench-* prefix and skips the llm-burst GPU-registry
# validation/context-window override for them. The model_list entries live
# in /root/projects/pardalos/deploy/litellm-free.yaml, pointed at
# MODEL_PROXY_OPENAPI_URL/MODEL_PROXY_API_KEY in .env.local. That proxy
# token is short-lived (~1-2h): refresh with
# `kaggle benchmarks auth -y --env-file /root/.config/kbench/proxy.env` then
# `systemctl restart pardalos-freeproxy.service` before a run that might
# outlast it. The restricted default-local token only reaches the 8 models
# above (see LLMS_AVAILABLE in proxy.env), not the full
# `kaggle benchmarks tasks models` catalog.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

BACKEND="${ALFRED_BACKEND:-kqwen}"
# allow --backend NAME to override the env var
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --backend) BACKEND="$2"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

case "$BACKEND" in
  kqwen) KAGGLE_MODEL=qwen38-kaggle; USES_KAGGLE=1 ;;
  kglm) KAGGLE_MODEL=glm47-kaggle; USES_KAGGLE=1 ;;
  kq122) KAGGLE_MODEL=qwen35-122b-kaggle; USES_KAGGLE=1 ;;
  *) KAGGLE_MODEL=""; USES_KAGGLE=0 ;;
esac

# The TPU tier has its own launcher (qwen122-tpu); never start or stop it here.
if [ "$BACKEND" = qwen122-tpu ] && ! curl -sf -m 5 http://127.0.0.1:8193/health >/dev/null; then
  echo "run.sh: qwen122-tpu is not serving on 127.0.0.1:8193; start it with 'qwen122-tpu' first" >&2
  exit 1
fi

STOPPED=0
stop_session() {
  [ "$USES_KAGGLE" = 1 ] || return 0
  [ "$STOPPED" = 1 ] && return 0
  STOPPED=1
  echo "run.sh: stopping Kaggle session ($BACKEND / $KAGGLE_MODEL)" >&2
  KAGGLE_MODEL="$KAGGLE_MODEL" kaggle-glm stop >&2 || true
}
trap stop_session EXIT INT TERM

if [ "$USES_KAGGLE" = 1 ]; then
  echo "run.sh: starting Kaggle session for $BACKEND ($KAGGLE_MODEL), waiting up to 15 min" >&2
  t0=$SECONDS
  if ! timeout 900 env KAGGLE_MODEL="$KAGGLE_MODEL" kaggle-glm start --wait; then
    echo "run.sh: session did not come up within 15 min ($((SECONDS - t0))s elapsed); see 'kaggle-glm status' / 'kaggle-glm logs'" >&2
    exit 1
  fi
  echo "run.sh: session up after $((SECONDS - t0))s" >&2
fi

# Overall budget for the task loop itself (default 40 min), separate from
# the 15-min session-start wait above, so a run can't blow past the ~60 min
# Kaggle quota ceiling even if several tasks hit their own timeouts.
BUDGET="${ALFRED_EVAL_BUDGET_S:-2400}"
timeout "$BUDGET" python3 "$HERE/run_eval.py" --backend "$BACKEND" "${ARGS[@]}"
rc=$?
if [ $rc = 124 ]; then
  echo "run.sh: hit overall budget (${BUDGET}s); stopping remaining tasks" >&2
fi

stop_session
exit $rc
