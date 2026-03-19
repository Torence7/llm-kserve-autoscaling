#!/usr/bin/env bash
set -euo pipefail

echo "[15] Watch scaling (Ctrl+C to stop)"
while true; do
  date
  echo "--- Deploy replicas:"
  kubectl get deploy -n llm-demo | egrep 'facebook-opt-125m|NAME' || true
  echo "--- HPA:"
  kubectl get hpa -n llm-demo || true
  echo "--- ScaledObject:"
  kubectl get scaledobject -n llm-demo || true
  echo
  sleep 5
done