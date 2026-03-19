#!/usr/bin/env bash
set -euo pipefail

DEPLOY=$(kubectl get deploy -n llm-demo -o name | grep -E 'facebook-opt-125m.*kserve$' | head -n 1 | sed 's|deployment.apps/||')
if [[ -z "${DEPLOY}" ]]; then
  echo "Could not find OPT worker deployment. Run deploy script first."
  kubectl get deploy -n llm-demo
  exit 1
fi

echo "[07] Patching probes for ${DEPLOY}"
kubectl -n llm-demo patch deployment "${DEPLOY}" --type='json' -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/startupProbe/initialDelaySeconds","value":600},
  {"op":"replace","path":"/spec/template/spec/containers/0/startupProbe/timeoutSeconds","value":5},
  {"op":"replace","path":"/spec/template/spec/containers/0/startupProbe/failureThreshold","value":120},
  {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/initialDelaySeconds","value":60},
  {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/initialDelaySeconds","value":600}
]'
kubectl rollout restart deployment "${DEPLOY}" -n llm-demo
