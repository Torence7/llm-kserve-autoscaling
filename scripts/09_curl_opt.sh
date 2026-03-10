#!/usr/bin/env bash
set -euo pipefail
echo "[09] curl completion"
curl -sS -X POST http://localhost:8001/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"facebook/opt-125m","prompt":"Who are you?","max_tokens":40}'
echo
