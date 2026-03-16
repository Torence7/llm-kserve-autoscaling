#!/usr/bin/env bash
set -euo pipefail
echo "[22] GuideLLM constant-rate benchmark"

# shellcheck disable=SC1091
source .venv/bin/activate

TARGET="${TARGET:-http://localhost:8001}"
RATE="${RATE:-2}"              # requests/sec
DURATION="${DURATION:-120}"    # seconds
OUTDIR="${OUTDIR:-results/guidellm/constant_r${RATE}_$(date +%Y%m%d_%H%M%S)}"

mkdir -p "$OUTDIR"

guidellm benchmark \
  --target "$TARGET" \
  --profile constant \
  --rate "$RATE" \
  --max-seconds "$DURATION" \
  --data "prompt_tokens=128,output_tokens=128" \
  --output-dir "$OUTDIR"

echo "[22] Results written to: $OUTDIR"