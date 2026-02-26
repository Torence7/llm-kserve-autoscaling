#!/usr/bin/env bash
set -euo pipefail
NS="llm-demo"
kubectl create namespace "${NS}" 2>/dev/null || true
kubectl apply -n "${NS}" -f manifests/llm/facebook-opt-125m.yaml
kubectl get llminferenceservice -n "${NS}"
kubectl get pods -n "${NS}" || true