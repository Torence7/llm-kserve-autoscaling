#!/usr/bin/env bash
set -euo pipefail

DEPLOY=$(kubectl get deploy -n llm-demo -o name | grep -E 'facebook-opt-125m.*kserve$' | head -n 1 | sed 's|deployment.apps/||')
if [[ -z "${DEPLOY}" ]]; then
  echo "Could not find OPT worker deployment."
  kubectl get deploy -n llm-demo
  exit 1
fi

echo "[10] Create HPA for ${DEPLOY}"
kubectl autoscale deployment "${DEPLOY}" -n llm-demo --cpu 50% --min=1 --max=5
kubectl get hpa -n llm-demo
