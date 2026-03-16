#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
cd "$REPO_ROOT"

if [[ -f ".venv/bin/activate" ]]; then
  # shellcheck disable=SC1091
  source ".venv/bin/activate"
else
  echo "ERROR: .venv not found. Run: bash scripts/benchmark/install_guidellm.sh"
  exit 1
fi

echo "[22] GuideLLM constant-rate benchmark"

TARGET="${TARGET:-http://localhost:8001/v1}"
MODEL="${MODEL:-facebook/opt-125m}"
TOKENIZER="${TOKENIZER:-facebook/opt-125m}"
PROMPT_TOKENS="${PROMPT_TOKENS:-128}"
GENERATED_TOKENS="${GENERATED_TOKENS:-128}"
MAX_SECONDS="${MAX_SECONDS:-60}"

# Default rates if none provided
RATES="${RATES:-1 2 4 8}"

OUTDIR="${OUTDIR:-results/guidellm}"
mkdir -p "$OUTDIR"
OUTPATH="${OUTPATH:-$OUTDIR/constant_$(date +%Y%m%d_%H%M%S).json}"

# Build repeated --rate flags
RATE_ARGS=()
for r in $RATES; do
  RATE_ARGS+=(--rate "$r")
done

guidellm \
  --target "$TARGET" \
  --backend openai_server \
  --model "$MODEL" \
  --tokenizer "$TOKENIZER" \
  --data "prompt_tokens=${PROMPT_TOKENS},generated_tokens=${GENERATED_TOKENS}" \
  --data-type emulated \
  --rate-type constant \
  "${RATE_ARGS[@]}" \
  --max-seconds "$MAX_SECONDS" \
  --output-path "$OUTPATH"

echo "[22] Results written to: $OUTPATH"