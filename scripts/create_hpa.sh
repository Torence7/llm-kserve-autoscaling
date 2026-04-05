#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/model.sh"

usage() {
  cat <<EOF
Usage:
  bash scripts/create_hpa.sh --model <key|path> [--policy <key|path>]
EOF
}

MODEL_ARG=""
POLICY_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      MODEL_ARG="${2:-}"
      shift 2
      ;;
    --policy)
      POLICY_ARG="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$MODEL_ARG" ]] || { usage; exit 1; }

load_model_config "$MODEL_ARG"

if [[ -n "$POLICY_ARG" ]]; then
  load_policy_config "$POLICY_ARG"
fi

KEDA_SCALEDOBJECT_NAME="$(yaml_get_or_default '.keda_scaledobject_name' "$MODEL_FILE" "$(sanitize_name "${MODEL_KEY}")-${POLICY_KEY}")"

case "$POLICY_TYPE" in
  hpa|hpa-cpu)
    ;;
  *)
    die "Policy '${POLICY_KEY}' is not an HPA policy. Found policy_type='${POLICY_TYPE}'"
    ;;
esac

kubectl get deploy -n "$NAMESPACE" "$WORKER_DEPLOYMENT_NAME" >/dev/null 2>&1 || {
  echo "Could not find worker deployment: ${WORKER_DEPLOYMENT_NAME}"
  kubectl get deploy -n "$NAMESPACE"
  exit 1
}

delete_scaledobjects_for_target() {
  local so_names
  so_names="$(
    kubectl get scaledobject -n "$NAMESPACE" \
      -o jsonpath="{range .items[?(@.spec.scaleTargetRef.name==\"${WORKER_DEPLOYMENT_NAME}\")]}{.metadata.name}{'\n'}{end}" \
      2>/dev/null || true
  )"

  if [[ -n "$so_names" ]]; then
    while IFS= read -r so_name; do
      [[ -n "$so_name" ]] || continue
      log "Deleting existing ScaledObject ${so_name} targeting ${WORKER_DEPLOYMENT_NAME}"
      kubectl delete scaledobject -n "$NAMESPACE" "$so_name" --ignore-not-found >/dev/null 2>&1 || true
    done <<< "$so_names"
  fi
}

delete_scaledobjects_for_target

log "Deleting any existing HPA named ${WORKER_DEPLOYMENT_NAME} in ${NAMESPACE}"
kubectl delete hpa -n "$NAMESPACE" "$WORKER_DEPLOYMENT_NAME" --ignore-not-found >/dev/null 2>&1 || true

log "Creating HPA for ${WORKER_DEPLOYMENT_NAME}"
kubectl autoscale deployment "${WORKER_DEPLOYMENT_NAME}" \
  -n "$NAMESPACE" \
  --cpu-percent="${CPU_TARGET_UTILIZATION}" \
  --min="${MIN_REPLICAS}" \
  --max="${MAX_REPLICAS}"

kubectl get hpa -n "$NAMESPACE"