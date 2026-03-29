#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/model.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/apply_keda_scaledobject.sh --model <model-name|path>

Description:
  Loads the model config, resolves its referenced scaling policy from
  configs/policies/, and applies the corresponding KEDA ScaledObject.

Supported policy types:
  - hpa-cpu-baseline
  - keda-prometheus
  - keda-composite
EOF
}

MODEL_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      MODEL_ARG="${2:-}"
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

log "Model: ${MODEL_KEY}"
log "Policy: ${POLICY_KEY} (${POLICY_TYPE})"
log "Target deployment: ${WORKER_DEPLOYMENT_NAME}"

log "Deleting existing HPAs in ${NAMESPACE} to avoid HPA/KEDA conflicts"
kubectl delete hpa -n "$NAMESPACE" --all --ignore-not-found

render_prometheus_trigger() {
  local name="$1"
  local metric_name="$2"
  local query="$3"
  local threshold="$4"
  local activation_threshold="${5:-}"

  cat <<EOF
    - type: prometheus
      name: ${name}
      metadata:
        serverAddress: ${PROMETHEUS_SERVER_ADDRESS}
        metricName: ${metric_name}
        query: |
$(echo "${query}" | sed 's/^/          /')
        threshold: "${threshold}"
EOF

  if [[ -n "$activation_threshold" ]]; then
    cat <<EOF
        activationThreshold: "${activation_threshold}"
EOF
  fi
}

apply_single_prometheus_scaledobject() {
  [[ -n "$PROMETHEUS_METRIC_NAME" ]] || die "prometheus.metric_name missing in ${POLICY_FILE}"
  [[ -n "$PROMETHEUS_QUERY" ]] || die "prometheus.query missing in ${POLICY_FILE}"
  [[ -n "$THRESHOLD" ]] || die "prometheus.threshold missing in ${POLICY_FILE}"

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
$(render_prometheus_trigger \
  "${PROMETHEUS_METRIC_NAME}" \
  "${PROMETHEUS_METRIC_NAME}" \
  "${PROMETHEUS_QUERY}" \
  "${THRESHOLD}" \
  "${ACTIVATION_THRESHOLD}")
EOF
}

apply_cpu_baseline_scaledobject() {
  local metric_name="cpu_utilization"
  local query="avg(
  100 *
  (
    sum by (pod) (
      rate(container_cpu_usage_seconds_total{
        namespace=\"${NAMESPACE}\",
        pod=~\"${WORKER_DEPLOYMENT_NAME}.*\",
        container!=\"POD\",
        container!=\"\"
      }[2m])
    )
    /
    sum by (pod) (
      kube_pod_container_resource_requests{
        namespace=\"${NAMESPACE}\",
        pod=~\"${WORKER_DEPLOYMENT_NAME}.*\",
        resource=\"cpu\"
      }
    )
  )
)"

  PROMETHEUS_METRIC_NAME="${PROMETHEUS_METRIC_NAME:-$metric_name}"
  # shellcheck disable=SC2016
  PROMETHEUS_QUERY="${PROMETHEUS_QUERY:-$query}"
  THRESHOLD="${THRESHOLD:-$CPU_TARGET_UTILIZATION}"

  apply_single_prometheus_scaledobject
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
        "$activation_threshold"
    )"$'\n'
  done

  log "Applying composite KEDA ScaledObject ${KEDA_SCALEDOBJECT_NAME}"

  if [[ -n "$SCALING_MODIFIER_ACTIVATION_TARGET" ]]; then
    cat <<EOF | kubectl apply -f -
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
    scalingModifiers:
      formula: "${SCALING_MODIFIER_FORMULA}"
      target: "${SCALING_MODIFIER_TARGET}"
      activationTarget: "${SCALING_MODIFIER_ACTIVATION_TARGET}"
  triggers:
${triggers_yaml}
EOF
  else
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
  advanced:
    scalingModifiers:
      formula: "${SCALING_MODIFIER_FORMULA}"
      target: "${SCALING_MODIFIER_TARGET}"
  triggers:
${triggers_yaml}
EOF
  fi
}

case "$POLICY_TYPE" in
  hpa-cpu-baseline)
    apply_cpu_baseline_scaledobject
    ;;
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