#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/model.sh"

MODEL_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      MODEL_ARG="${2:-}"
      shift 2
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$MODEL_ARG" ]] || die "Usage: scripts/apply_monitoring.sh --model <model-name|path>"

load_model_config "$MODEL_ARG"

log "Applying monitoring resources for ${MODEL_KEY}"

kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${METRICS_SERVICE_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${METRICS_SERVICE_NAME}
spec:
  selector:
    app.kubernetes.io/name: ${WORKLOAD_LABEL_NAME}
    kserve.io/component: workload
  ports:
    - name: metrics
      port: ${METRICS_PORT}
      targetPort: ${METRICS_PORT}
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: ${SERVICE_MONITOR_NAME}
  namespace: ${NAMESPACE}
spec:
  selector:
    matchLabels:
      app: ${METRICS_SERVICE_NAME}
  endpoints:
    - port: metrics
      path: ${METRICS_PATH}
      interval: ${METRICS_SCRAPE_INTERVAL}
EOF