#!/usr/bin/env bash
set -euo pipefail

echo "[12] Install KEDA"

# Helm must exist
command -v helm >/dev/null 2>&1 || { echo "ERROR: helm not found"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found"; exit 1; }

# Make sure cluster is reachable
kubectl get nodes >/dev/null 2>&1 || { echo "ERROR: kubectl cannot reach cluster"; exit 1; }

# Add repo + install
helm repo add kedacore https://kedacore.github.io/charts >/dev/null
helm repo update >/dev/null

helm upgrade --install keda kedacore/keda \
  --namespace keda --create-namespace

# Wait for readiness
kubectl rollout status deployment/keda-operator -n keda --timeout=180s
kubectl rollout status deployment/keda-metrics-apiserver -n keda --timeout=180s

echo "[11] KEDA installed."
kubectl get pods -n keda