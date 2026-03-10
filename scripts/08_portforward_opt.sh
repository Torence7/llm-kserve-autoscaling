#!/usr/bin/env bash
set -euo pipefail

SVC=$(kubectl get svc -n llm-demo | awk '/workload-svc/ {print $1; exit}')
if [[ -z "${SVC}" ]]; then
  echo "No workload service found."
  kubectl get svc -n llm-demo
  exit 1
fi

echo "[08] Port-forward svc/${SVC} -> localhost:8001"
kubectl port-forward -n llm-demo "svc/${SVC}" 8001:8000
