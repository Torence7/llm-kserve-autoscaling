#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

DASHBOARD_FILE="${SCRIPT_DIR}/../manifests/monitoring/grafana-dashboard-vllm.json"
NAMESPACE="monitoring"
CONFIGMAP_NAME="grafana-dashboard-vllm"

need_cmd kubectl

log "Deploying Grafana dashboard ConfigMap to namespace ${NAMESPACE}"

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${CONFIGMAP_NAME}
  namespace: ${NAMESPACE}
  labels:
    grafana_dashboard: "1"
data:
  vllm-kserve-autoscaling.json: |
$(sed 's/^/    /' "${DASHBOARD_FILE}")
EOF

log "Dashboard deployed. Grafana will pick it up within ~30s."
log ""
log "To access Grafana, run:"
log "  kubectl port-forward svc/prometheus-grafana 3000:80 -n ${NAMESPACE}"
log ""
log "Then open: http://localhost:3000"
log "Default credentials: admin / prom-operator"
