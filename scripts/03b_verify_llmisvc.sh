#!/usr/bin/env bash
set -euo pipefail

echo "[03b] Verifying LLMISvc install..."

kubectl get crd llminferenceservices.serving.kserve.io
kubectl get crd llminferenceserviceconfigs.serving.kserve.io

echo
kubectl get pods -n kserve | egrep 'kserve-controller-manager|llmisvc-controller-manager' || true

echo
echo "[03b] Looks good."