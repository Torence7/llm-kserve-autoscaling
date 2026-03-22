#!/usr/bin/env bash
set -euo pipefail
echo "[20] Install GuideLLM"

# Create venv in repo (keeps things reproducible)
python3 -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate

python -m pip install -U pip wheel
python -m pip install "guidellm[recommended]"

echo "Done. Activate later with: source .venv/bin/activate"