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

GUIDE_HELP="$(guidellm --help 2>&1 || true)"

MODEL_FLAG=()
if grep -q -- '--processor' <<<"$GUIDE_HELP"; then
  MODEL_FLAG=(--processor "$SERVED_MODEL_NAME")
elif grep -q -- '--model' <<<"$GUIDE_HELP"; then
  MODEL_FLAG=(--model "$SERVED_MODEL_NAME")
fi

OUTPUT_FLAG=()
if grep -q -- '--output-dir' <<<"$GUIDE_HELP" && grep -q -- '--outputs' <<<"$GUIDE_HELP"; then
  OUTPUT_DIR="$(dirname "$OUTFILE")"
  OUTPUT_NAME="$(basename "$OUTFILE")"
  OUTPUT_FLAG=(--output-dir "$OUTPUT_DIR" --outputs "$OUTPUT_NAME")
elif grep -q -- '--output-path' <<<"$GUIDE_HELP"; then
  OUTPUT_FLAG=(--output-path "$OUTFILE")
elif grep -q -- '--output ' <<<"$GUIDE_HELP" || grep -q -- '--output$' <<<"$GUIDE_HELP"; then
  OUTPUT_FLAG=(--output "$OUTFILE")
else
  OUTPUT_FLAG=()
fi

RATE_FLAG=()
if grep -q -- '--profile' <<<"$GUIDE_HELP"; then
  RATE_FLAG=(--profile constant)
else
  RATE_FLAG=(--rate-type constant)
fi

DATA_TYPE_FLAG=()
if grep -q -- '--data-type' <<<"$GUIDE_HELP"; then
  DATA_TYPE_FLAG=(--data-type emulated)
fi

log "GuideLLM constant-rate benchmark"
log "target=${TARGET} model=${SERVED_MODEL_NAME} rate=${RATE}"
log "outfile=${OUTFILE}"

guidellm \
  --target "$TARGET" \
  "${MODEL_FLAG[@]}" \
  "${DATA_TYPE_FLAG[@]}" \
  --data "prompt_tokens=${PROMPT_TOKENS},generated_tokens=${OUTPUT_TOKENS}" \
  "${RATE_FLAG[@]}" \
  --rate "$RATE" \
  --max-seconds "$MAX_SECONDS" \
  "${OUTPUT_FLAG[@]}"

log "Saved results to ${OUTFILE}"