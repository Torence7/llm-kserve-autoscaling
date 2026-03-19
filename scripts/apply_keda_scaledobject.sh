#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/model.sh"

usage() {
  cat <<EOF
Usage:
  bash scripts/apply_keda_scaledobject.sh --model <key|path>
EOF
}

MODEL_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL_ARG="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$MODEL_ARG" ]] || { usage; exit 1; }
load_model_config "$MODEL_ARG"

kubectl get crd scaledobjects.keda.sh >/dev/null 2>&1 || {
  echo "ERROR: KEDA CRDs not found. Run scripts/install_keda.sh first."
  exit 1
}

kubectl get deploy -n "$NAMESPACE" "$WORKER_DEPLOYMENT_NAME" >/dev/null 2>&1 || {
  echo "Worker deployment ${WORKER_DEPLOYMENT_NAME} not found."
  kubectl get deploy -n "$NAMESPACE"
  exit 1
}

log "Deleting existing HPAs in ${NAMESPACE} to avoid HPA/KEDA conflicts"
kubectl delete hpa -n "$NAMESPACE" --all --ignore-not-found

log "Applying KEDA ScaledObject ${KEDA_SCALEDOBJECT_NAME}"
kubectl apply -f - <<EOF
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: ${KEDA_SCALEDOBJECT_NAME}
  namespace: ${NAMESPACE}
spec:
  scaleTargetRef:
    name: ${WORKER_DEPLOYMENT_NAME}
  minReplicaCount: ${MIN_REPLICAS}
  maxReplicaCount: ${MAX_REPLICAS}
  pollingInterval: ${POLLING_INTERVAL}
  cooldownPeriod: ${COOLDOWN_PERIOD}
  triggers:
    - type: cpu
      metricType: Utilization
      metadata:
        value: "${CPU_TARGET_UTILIZATION}"
EOF

kubectl get scaledobject -n "$NAMESPACE"