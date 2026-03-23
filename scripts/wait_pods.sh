#!/usr/bin/env bash
set -euo pipefail
echo "[06] Watch llm-demo pods"
kubectl rollout status deployment/qwen25-0-5b-instruct-kserve \
  --namespace llm-demo \
  --timeout=300s || true
