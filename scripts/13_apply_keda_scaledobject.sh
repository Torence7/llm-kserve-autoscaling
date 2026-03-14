#!/usr/bin/env bash
set -euo pipefail

echo "[12] Apply KEDA ScaledObject (CPU)"

# Ensure KEDA CRDs exist
kubectl get crd scaledobjects.keda.sh >/dev/null 2>&1 || {
  echo "ERROR: KEDA CRDs not found. Run scripts/11_install_keda.sh first."
  exit 1
}

# Optional: avoid "two autoscalers fighting"
echo "[13] Deleting any existing HPA in llm-demo (recommended when using KEDA CPU trigger)"
kubectl delete hpa -n llm-demo --all --ignore-not-found

kubectl apply -f manifests/keda/scaledobject-cpu.yaml

echo "[12] Applied. Current ScaledObjects:"
kubectl get scaledobject -n llm-demo