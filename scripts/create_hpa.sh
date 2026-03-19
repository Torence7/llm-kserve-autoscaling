#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/model.sh"

usage() {
  cat <<EOF
Usage:
  bash scripts/create_hpa.sh --model <key|path>
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

kubectl get deploy -n "$NAMESPACE" "$WORKER_DEPLOYMENT_NAME" >/dev/null 2>&1 || {
  echo "Could not find worker deployment: ${WORKER_DEPLOYMENT_NAME}"
  kubectl get deploy -n "$NAMESPACE"
  exit 1
}

log "Deleting any existing HPA named ${WORKER_DEPLOYMENT_NAME} in ${NAMESPACE}"
kubectl delete hpa -n "$NAMESPACE" "$WORKER_DEPLOYMENT_NAME" --ignore-not-found >/dev/null 2>&1 || true

log "Creating HPA for ${WORKER_DEPLOYMENT_NAME}"
kubectl autoscale deployment "${WORKER_DEPLOYMENT_NAME}" \
  -n "$NAMESPACE" \
  --cpu-percent="${CPU_TARGET_UTILIZATION}" \
  --min="${MIN_REPLICAS}" \
  --max="${MAX_REPLICAS}"

kubectl get hpa -n "$NAMESPACE"