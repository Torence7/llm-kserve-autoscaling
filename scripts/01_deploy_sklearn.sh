#!/usr/bin/env bash
set -euo pipefail
NS="kserve-test"

kubectl create namespace "${NS}" 2>/dev/null || true
kubectl apply -n "${NS}" -f manifests/kserve/sklearn-iris.yaml
kubectl get inferenceservice -n "${NS}"
kubectl get svc -n "${NS}" || true
kubectl get pods -n "${NS}" || true