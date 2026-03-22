#!/usr/bin/env bash
set -euo pipefail
echo "[06] Watch llm-demo pods"
kubectl wait pod \
  --namespace llm-demo \
  --all \
  --for=condition=Ready \
  --timeout=300s
