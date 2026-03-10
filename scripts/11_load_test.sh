#!/usr/bin/env bash
set -euo pipefail
echo "[11] Load loop (Ctrl+C to stop)"
while true; do
  curl -s -X POST http://localhost:8001/v1/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"facebook/opt-125m","prompt":"Write a short paragraph about systems.","max_tokens":120}' >/dev/null
done
