#!/usr/bin/env bash
set -euo pipefail

echo "[05] Deploy OPT-125M"
kubectl create namespace llm-demo 2>/dev/null || true
kubectl apply -f manifests/llm/opt-125m.yaml

kubectl get llminferenceservice -n llm-demo
kubectl get deploy -n llm-demo
kubectl get pods -n llm-demo
