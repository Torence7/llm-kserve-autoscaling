#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/model.sh"

usage() {
  cat <<EOF
Usage:
  bash scripts/smoke_test.sh --model <key|path>

Optional overrides:
  TARGET=http://localhost:8001/v1
  PROMPT="Who are you?"
  MAX_TOKENS=40
EOF
}

MODEL_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL_ARG="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$MODEL_ARG" ]] || { usage; exit 1; }
load_model_config "$MODEL_ARG"

TARGET="${TARGET:-http://localhost:${LOCAL_PORT}/v1}"
PROMPT="${PROMPT:-$SMOKE_PROMPT}"
MAX_TOKENS="${MAX_TOKENS:-$SMOKE_MAX_TOKENS}"

log "Smoke test -> ${TARGET}/completions"
curl -sS -X POST "${TARGET}/completions" \
  -H 'Content-Type: application/json' \
  -d "$(cat <<EOF
{"model":"${SERVED_MODEL_NAME}","prompt":"${PROMPT}","max_tokens":${MAX_TOKENS}}
EOF
)"
echo