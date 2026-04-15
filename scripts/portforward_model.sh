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
DETACH=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL_ARG="${2:-}"; shift 2 ;;
    --detach) DETACH=1; shift ;;
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

PF_LOG="/tmp/portforward_${MODEL_KEY}.log"
PF_PID_FILE="/tmp/portforward_${MODEL_KEY}.pid"

if [[ "$DETACH" -eq 1 ]]; then
  # Kill any existing port-forward for this model
  if [[ -f "$PF_PID_FILE" ]]; then
    OLD_PID="$(cat "$PF_PID_FILE")"
    kill "$OLD_PID" 2>/dev/null || true
    rm -f "$PF_PID_FILE"
  fi

  nohup kubectl port-forward -n "$NAMESPACE" "svc/${WORKLOAD_SERVICE_NAME}" "${LOCAL_PORT}:${REMOTE_PORT}" \
    >"$PF_LOG" 2>&1 &
  echo $! > "$PF_PID_FILE"
  log "Port-forward running in background (PID $(cat "$PF_PID_FILE")) -> localhost:${LOCAL_PORT}"
  log "Logs: $PF_LOG"
  log "To stop: kill \$(cat $PF_PID_FILE)"
else
  log "Port-forward svc/${WORKLOAD_SERVICE_NAME} -> localhost:${LOCAL_PORT}"
  kubectl port-forward -n "$NAMESPACE" "svc/${WORKLOAD_SERVICE_NAME}" "${LOCAL_PORT}:${REMOTE_PORT}"
fi