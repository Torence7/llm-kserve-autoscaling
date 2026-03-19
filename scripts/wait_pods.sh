#!/usr/bin/env bash
set -euo pipefail
echo "[06] Watch llm-demo pods"
kubectl get pods -n llm-demo -w
