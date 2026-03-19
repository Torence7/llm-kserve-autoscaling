#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/model.sh"

usage() {
  cat <<EOF
Usage:
  bash scripts/portforward_model.sh --model <key|path>
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

kubectl get svc -n "$NAMESPACE" "$WORKLOAD_SERVICE_NAME" >/dev/null 2>&1 || {
  echo "Service ${WORKLOAD_SERVICE_NAME} not found in namespace ${NAMESPACE}."
  kubectl get svc -n "$NAMESPACE"
  exit 1
}

log "Port-forward svc/${WORKLOAD_SERVICE_NAME} -> localhost:${LOCAL_PORT}"
kubectl port-forward -n "$NAMESPACE" "svc/${WORKLOAD_SERVICE_NAME}" "${LOCAL_PORT}:${REMOTE_PORT}"