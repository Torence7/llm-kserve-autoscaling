#!/usr/bin/env bash
set -euo pipefail

echo "[13] Verify KEDA"

kubectl get pods -n keda
kubectl get scaledobject -n llm-demo || true
kubectl get hpa -n llm-demo || true

echo
echo "[14] Describe ScaledObject (if present):"
kubectl describe scaledobject -n llm-demo opt125m-cpu 2>/dev/null || true

echo
echo "[14] KEDA operator logs (last 50 lines):"
kubectl logs -n keda deploy/keda-operator --tail=50 || true