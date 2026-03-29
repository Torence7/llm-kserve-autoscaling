#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"
# shellcheck source=../lib/model.sh
source "${REPO_ROOT}/scripts/lib/model.sh"

usage() {
  cat <<EOF
Usage:
  bash scripts/benchmark/guidellm_constant_rate.sh --model <key|path>

Optional overrides:
  TARGET=http://localhost:8001/v1
  RATE=1
  PROMPT_TOKENS=128
  OUTPUT_TOKENS=128
  MAX_SECONDS=30
  OUTFILE=results/guidellm/constant.json
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

cd "$REPO_ROOT"
[[ -f ".venv/bin/activate" ]] || die "Missing .venv. Run: bash scripts/benchmark/install_guidellm.sh"
# shellcheck disable=SC1091
source ".venv/bin/activate"

need_cmd guidellm

TARGET="${TARGET:-http://localhost:${LOCAL_PORT}/v1}"
RATE="${RATE:-1}"
PROMPT_TOKENS="${PROMPT_TOKENS:-$BENCHMARK_PROMPT_TOKENS}"
OUTPUT_TOKENS="${OUTPUT_TOKENS:-$BENCHMARK_OUTPUT_TOKENS}"
MAX_SECONDS="${MAX_SECONDS:-$BENCHMARK_MAX_SECONDS}"
OUTFILE="${OUTFILE:-results/guidellm/${MODEL_KEY}_constant.json}"

mkdir -p "$(dirname "$OUTFILE")"

OUTPUT_DIR="$(dirname "$OUTFILE")"
OUTPUT_NAME="$(basename "$OUTFILE")"

log "GuideLLM constant-rate benchmark"
log "target=${TARGET} model=${SERVED_MODEL_NAME} rate=${RATE}"
log "outfile=${OUTFILE}"

guidellm benchmark run \
  --target "$TARGET" \
  --model "$SERVED_MODEL_NAME" \
  --data "prompt_tokens=${PROMPT_TOKENS},output_tokens=${OUTPUT_TOKENS}" \
  --profile constant \
  --rate "$RATE" \
  --max-seconds "$MAX_SECONDS" \
  --output-dir "$OUTPUT_DIR" \
  --outputs "$OUTPUT_NAME"

log "Saved results to ${OUTFILE}"