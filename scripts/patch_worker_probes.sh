#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-llm-demo}"
DEPLOY="${DEPLOY:-}"

if [[ -z "${DEPLOY}" ]]; then
  DEPLOY="$(kubectl get deploy -n "${NS}" -o name | grep -E 'kserve$' | head -n 1 | sed 's|deployment.apps/||')"
fi

if [[ -z "${DEPLOY}" ]]; then
  echo "Could not find KServe worker deployment in namespace ${NS}."
  kubectl get deploy -n "${NS}"
  exit 1
fi

echo "Patching probes for ${DEPLOY} in namespace ${NS}"

kubectl -n "${NS}" patch deployment "${DEPLOY}" --type='json' -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/startupProbe/timeoutSeconds","value":5},
  {"op":"replace","path":"/spec/template/spec/containers/0/startupProbe/failureThreshold","value":180},
  {"op":"replace","path":"/spec/template/spec/containers/0/startupProbe/periodSeconds","value":10},
  {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/timeoutSeconds","value":5},
  {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/failureThreshold","value":12},
  {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/initialDelaySeconds","value":900}
]'

kubectl rollout status deploy/"${DEPLOY}" -n "${NS}" --timeout=900s
kubectl describe deploy "${DEPLOY}" -n "${NS}" | sed -n "/Liveness:/,/Environment:/p"