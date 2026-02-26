#!/usr/bin/env bash
set -euo pipefail

NS="kserve-test"
SVC="sklearn-iris-predictor"

echo "[port-forward] Forwarding localhost:8080 -> ${SVC}:80 in namespace ${NS}"
echo "Leave this running. Press Ctrl+C to stop."
kubectl port-forward -n "${NS}" "svc/${SVC}" 8080:80
