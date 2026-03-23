#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=./lib/model.sh
source "${SCRIPT_DIR}/lib/model.sh"

usage() {
  cat <<EOF
Usage:
  bash scripts/deploy_model.sh --model <key|path>

Examples:
  bash scripts/deploy_model.sh --model facebook-opt-125m
  bash scripts/deploy_model.sh --model configs/models/facebook-opt-125m.yaml
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
ensure_namespace "$NAMESPACE"

log "Deploying model profile: $MODEL_FILE"
log "Namespace: $NAMESPACE"
log "LLMInferenceService: $LLMISVC_NAME"
log "Served model name: $SERVED_MODEL_NAME"

kubectl apply -f - <<EOF
apiVersion: serving.kserve.io/v1alpha1
kind: LLMInferenceService
metadata:
  name: ${LLMISVC_NAME}
  namespace: ${NAMESPACE}
spec:
  model:
    uri: hf://${HF_MODEL_ID}
    name: ${SERVED_MODEL_NAME}
  template:
    containers:
      - name: main
        image: ${IMAGE}
        securityContext:
          runAsNonRoot: false
        env:
          - name: VLLM_LOGGING_LEVEL
            value: "${VLLM_LOGGING_LEVEL}"
        resources:
          requests:
            cpu: "${REQUESTS_CPU}"
            memory: "${REQUESTS_MEMORY}"
          limits:
            cpu: "${LIMITS_CPU}"
            memory: "${LIMITS_MEMORY}"
  router:
    gateway: {}
    route: {}
    scheduler: {}
EOF

sleep 60

log "Current LLMInferenceServices"
kubectl get llminferenceservice -n "$NAMESPACE"

log "Current deployments"
kubectl get deploy -n "$NAMESPACE"

log "Current pods"
kubectl get pods -n "$NAMESPACE"
