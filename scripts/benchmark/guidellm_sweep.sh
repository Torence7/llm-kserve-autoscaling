#!/usr/bin/env bash
set -euo pipefail

# Ensure we're in repo root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# Activate venv if present
if [[ -f ".venv/bin/activate" ]]; then
  # shellcheck disable=SC1091
  source ".venv/bin/activate"
fi

GUIDELLM="python -m guidellm"

# Ensure we're in repo root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# Activate venv if present
if [[ -f ".venv/bin/activate" ]]; then
  # shellcheck disable=SC1091
  source ".venv/bin/activate"
fi

GUIDELLM="python -m guidellm"

echo "GuideLLM sweep benchmark"

# shellcheck disable=SC1091
source .venv/bin/activate

TARGET="${TARGET:-http://localhost:8001}"
OUTDIR="${OUTDIR:-results/guidellm/sweep_$(date +%Y%m%d_%H%M%S)}"

mkdir -p "$OUTDIR"

guidellm benchmark \
  --target "$TARGET" \
  --profile sweep \
  --max-seconds 60 \
  --data "prompt_tokens=128,output_tokens=128" \
  --output-dir "$OUTDIR"

echo "[21] Results written to: $OUTDIR"