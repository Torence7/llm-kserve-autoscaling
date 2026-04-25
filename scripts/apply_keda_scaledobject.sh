#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/model.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/apply_keda_scaledobject.sh --model <model-name|path> [--policy <policy-name|path>]

Description:
  Loads the model config, optionally overrides the scaling policy,
  and applies the corresponding KEDA ScaledObject for that policy.

Supported policy types:
  - keda-prometheus
  - keda-composite
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

[[ -n "$MODEL_ARG" ]] || {
  usage
  exit 1
}

load_model_config "$MODEL_ARG"

if [[ -n "$POLICY_ARG" ]]; then
  load_policy_config "$POLICY_ARG"
fi

KEDA_SCALEDOBJECT_NAME="$(yaml_get_or_default '.keda_scaledobject_name' "$MODEL_FILE" "$(sanitize_name "${MODEL_KEY}")-${POLICY_KEY}")"

kubectl get crd scaledobjects.keda.sh >/dev/null 2>&1 || {
  echo "ERROR: KEDA CRDs not found."
  echo "Run scripts/install_keda.sh first."
  exit 1
}

kubectl get deploy -n "$NAMESPACE" "$WORKER_DEPLOYMENT_NAME" >/dev/null 2>&1 || {
  echo "Worker deployment ${WORKER_DEPLOYMENT_NAME} not found in namespace ${NAMESPACE}."
  kubectl get deploy -n "$NAMESPACE"
  exit 1
}

case "$POLICY_TYPE" in
  keda-prometheus|keda-composite)
    ;;
  *)
    die "Policy '${POLICY_KEY}' is not a KEDA policy. Found policy_type='${POLICY_TYPE}'"
    ;;
esac

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

log "Model: ${MODEL_KEY}"
log "Policy: ${POLICY_KEY} (${POLICY_TYPE})"
log "Target deployment: ${WORKER_DEPLOYMENT_NAME}"

log "Deleting existing HPA ${WORKER_DEPLOYMENT_NAME} in ${NAMESPACE} to avoid HPA/KEDA conflicts"
kubectl delete hpa -n "$NAMESPACE" "${WORKER_DEPLOYMENT_NAME}" --ignore-not-found >/dev/null 2>&1 || true

delete_scaledobjects_for_target

render_prometheus_trigger() {
  local name="$1"
  local metric_name="$2"
  local query="$3"
  local threshold="$4"
  local activation_threshold="${5:-}"
  local timeout="${6:-}"
  local ignore_null_values="${7:-}"

  cat <<EOF
  - type: prometheus
    name: "${name}"
    metadata:
      serverAddress: "${PROMETHEUS_SERVER_ADDRESS}"
      metricName: "${metric_name}"
      query: |
$(printf '%s\n' "$query" | sed 's/^/        /')
      threshold: "${threshold}"
EOF

  if [[ -n "$activation_threshold" ]]; then
    cat <<EOF
      activationThreshold: "${activation_threshold}"
EOF
  fi

  if [[ -n "$timeout" ]]; then
    cat <<EOF
      timeout: "${timeout}"
EOF
  fi

  if [[ -n "$ignore_null_values" ]]; then
    cat <<EOF
      ignoreNullValues: "${ignore_null_values}"
EOF
  fi
}

apply_single_prometheus_scaledobject() {
  [[ -n "$PROMETHEUS_METRIC_NAME" ]] || die "prometheus.metric_name missing in ${POLICY_FILE}"
  [[ -n "$PROMETHEUS_QUERY" ]] || die "prometheus.query missing in ${POLICY_FILE}"
  [[ -n "$THRESHOLD" ]] || die "prometheus.threshold missing in ${POLICY_FILE}"

  log "Applying KEDA ScaledObject ${KEDA_SCALEDOBJECT_NAME}"

  local tmp_file
  tmp_file="$(mktemp /tmp/keda_scaledobject.XXXXXX.yaml)"

  cat > "$tmp_file" <<EOF
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
  advanced:
    restoreToOriginalReplicaCount: true
    horizontalPodAutoscalerConfig:
      name: ${KEDA_SCALEDOBJECT_NAME}-hpa
      behavior:
        scaleUp:
          stabilizationWindowSeconds: 0
          selectPolicy: Max
          policies:
            - type: Pods
              value: 2
              periodSeconds: 15
            - type: Percent
              value: 100
              periodSeconds: 15
        scaleDown:
          stabilizationWindowSeconds: 300
          selectPolicy: Max
          policies:
            - type: Percent
              value: 50
              periodSeconds: 30
  triggers:
$(render_prometheus_trigger \
  "${PROMETHEUS_METRIC_NAME}" \
  "${PROMETHEUS_METRIC_NAME}" \
  "${PROMETHEUS_QUERY}" \
  "${THRESHOLD}" \
  "${ACTIVATION_THRESHOLD}" \
  "${PROMETHEUS_TIMEOUT}" \
  "${PROMETHEUS_IGNORE_NULL_VALUES}")
EOF

  echo "Generated ScaledObject YAML:"
  cat "$tmp_file"
  echo

  kubectl apply -f "$tmp_file"
  rm -f "$tmp_file"
}

apply_composite_scaledobject() {
  [[ "$TRIGGERS_COUNT" -gt 0 ]] || die "No triggers defined in ${POLICY_FILE}"
  [[ -n "$SCALING_MODIFIER_FORMULA" ]] || die "advanced.scaling_modifiers.formula missing in ${POLICY_FILE}"
  [[ -n "$SCALING_MODIFIER_TARGET" ]] || die "advanced.scaling_modifiers.target missing in ${POLICY_FILE}"

  local triggers_yaml=""
  local i
  for ((i=0; i<TRIGGERS_COUNT; i++)); do
    local name metric_name query threshold activation_threshold

    name="$(yaml_get_or_default ".triggers[$i].name" "$POLICY_FILE" "")"
    metric_name="$(yaml_get_or_default ".triggers[$i].metric_name" "$POLICY_FILE" "")"
    query="$(yaml_get_or_default ".triggers[$i].query" "$POLICY_FILE" "")"
    threshold="$(yaml_get_or_default ".triggers[$i].threshold" "$POLICY_FILE" "")"
    activation_threshold="$(yaml_get_or_default ".triggers[$i].activation_threshold" "$POLICY_FILE" "")"

    [[ -n "$name" ]] || die "triggers[$i].name missing in ${POLICY_FILE}"
    [[ -n "$metric_name" ]] || die "triggers[$i].metric_name missing in ${POLICY_FILE}"
    [[ -n "$query" ]] || die "triggers[$i].query missing in ${POLICY_FILE}"
    [[ -n "$threshold" ]] || die "triggers[$i].threshold missing in ${POLICY_FILE}"

    triggers_yaml+="$(
      render_prometheus_trigger \
        "$name" \
        "$metric_name" \
        "$query" \
        "$threshold" \
        "$activation_threshold" \
        "$PROMETHEUS_TIMEOUT" \
        "$PROMETHEUS_IGNORE_NULL_VALUES"
    )"$'\n'
  done

  log "Applying composite KEDA ScaledObject ${KEDA_SCALEDOBJECT_NAME}"

  local tmp_file
  tmp_file="$(mktemp /tmp/keda_scaledobject_composite.XXXXXX.yaml)"

  cat > "$tmp_file" <<EOF
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
  advanced:
    restoreToOriginalReplicaCount: true
    horizontalPodAutoscalerConfig:
      name: ${KEDA_SCALEDOBJECT_NAME}-hpa
      behavior:
        scaleUp:
          stabilizationWindowSeconds: 0
          selectPolicy: Max
          policies:
            - type: Pods
              value: 2
              periodSeconds: 15
            - type: Percent
              value: 100
              periodSeconds: 15
        scaleDown:
          stabilizationWindowSeconds: 300
          selectPolicy: Max
          policies:
            - type: Percent
              value: 50
              periodSeconds: 30
    scalingModifiers:
      formula: "${SCALING_MODIFIER_FORMULA}"
      target: "${SCALING_MODIFIER_TARGET}"
EOF

  if [[ -n "${SCALING_MODIFIER_ACTIVATION_TARGET:-}" ]]; then
    cat >> "$tmp_file" <<EOF
      activationTarget: "${SCALING_MODIFIER_ACTIVATION_TARGET}"
EOF
  fi

  cat >> "$tmp_file" <<EOF
  triggers:
${triggers_yaml}
EOF

  echo "Generated ScaledObject YAML:"
  cat "$tmp_file"
  echo

  kubectl apply -f "$tmp_file"
  rm -f "$tmp_file"
}

case "$POLICY_TYPE" in
  keda-prometheus)
    apply_single_prometheus_scaledobject
    ;;
  keda-composite)
    apply_composite_scaledobject
    ;;
  *)
    die "Unsupported policy_type '${POLICY_TYPE}' in ${POLICY_FILE}"
    ;;
esac

log "Done."
kubectl get scaledobject -n "$NAMESPACE" "$KEDA_SCALEDOBJECT_NAME"