\#!/usr/bin/env bash
set -euo pipefail

# GuideLLM "sweep" = automatically explores increasing load/rates to find limits.
# Uses OpenAI *completions* endpoint to avoid chat-template issues for OPT.

NS="${NS:-llm-demo}"
SVC="${SVC:-facebook-opt-125m-kserve-workload-svc}"
REMOTE_PORT="${REMOTE_PORT:-8000}"

MODEL="${MODEL:-facebook/opt-125m}"

# Benchmark knobs
PROMPT_TOKENS="${PROMPT_TOKENS:-128}"
OUTPUT_TOKENS="${OUTPUT_TOKENS:-128}"
MAX_SECONDS="${MAX_SECONDS:-30}"
OUTDIR_BASE="${OUTDIR_BASE:-results/guidellm}"

pick_port() {
  for p in 8001 8002 8003 18001 18002 18003; do
    if ! lsof -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
      echo "$p"
      return 0
    fi
  done
  # last resort: random high port
  python3 - <<'PY'
import random
print(random.randint(20000, 40000))
PY
}

LOCAL_PORT="$(pick_port)"
BASE_URL="http://localhost:${LOCAL_PORT}"

echo "[21] Port-forward svc/${SVC} (${NS}) -> ${BASE_URL}"
kubectl -n "${NS}" port-forward "svc/${SVC}" "${LOCAL_PORT}:${REMOTE_PORT}" >/tmp/portforward_guidellm.log 2>&1 &
PF_PID=$!

cleanup() {
  echo "[21] Cleaning up port-forward (pid=${PF_PID})"
  kill "${PF_PID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# give port-forward a moment
sleep 2

# quick sanity check (should return model list or 200/404 depending on server routing)
curl -s "${BASE_URL}/v1/models" >/dev/null || true

TS="$(date +%Y%m%d_%H%M%S)"
OUTDIR="${OUTDIR_BASE}/sweep_${TS}"
mkdir -p "${OUTDIR}"

echo "[21] Running GuideLLM sweep:"
echo "     target=${BASE_URL}/v1"
echo "     request-type=completions"
echo "     model=${MODEL}"
echo "     data=prompt_tokens=${PROMPT_TOKENS},output_tokens=${OUTPUT_TOKENS}"
echo "     max-seconds=${MAX_SECONDS}"
echo "     outdir=${OUTDIR}"
echo

# NOTE: GuideLLM accepts --profile sweep and synthetic data as key=value pairs (README).
guidellm benchmark run \
  --target "${BASE_URL}/v1" \
  --request-type completions \
  --profile sweep \
  --max-seconds "${MAX_SECONDS}" \
  --data "prompt_tokens=${PROMPT_TOKENS},output_tokens=${OUTPUT_TOKENS}" \
  --model "${MODEL}" \
  --outputs json,csv,html \
  --output-dir "${OUTDIR}"

echo
echo "[21] Done. Outputs in: ${OUTDIR}"