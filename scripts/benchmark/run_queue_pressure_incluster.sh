#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-llm-demo}"
POD="${POD:-bench-client}"
MODEL="${MODEL:-Qwen/Qwen2.5-0.5B-Instruct}"
MODEL_KEY="${MODEL_KEY:-qwen25-0.5b-instruct}"
DEPLOY="${DEPLOY:-qwen25-0-5b-instruct-kserve}"
TARGET="${TARGET:-http://qwen25-0-5b-instruct-kserve-workload-svc.llm-demo.svc.cluster.local:8000/v1}"

SCENARIO="${SCENARIO:-configs/scenarios/queue-pressure.yaml}"
RESULTS_ROOT="${RESULTS_ROOT:-results/incluster}"
MAX_IN_FLIGHT="${MAX_IN_FLIGHT:-32}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-45}"
DRAIN_TIMEOUT_SECONDS="${DRAIN_TIMEOUT_SECONDS:-30}"
COLLECT_DURATION_SECONDS="${COLLECT_DURATION_SECONDS:-330}"
COLLECT_INTERVAL_SECONDS="${COLLECT_INTERVAL_SECONDS:-5}"

PROM_PORT_FORWARD="${PROM_PORT_FORWARD:-1}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
PROM_NS="${PROM_NS:-monitoring}"
PROM_SVC="${PROM_SVC:-prometheus-kube-prometheus-prometheus}"

POLICIES=(
  "hpa-cpu-baseline"
  "keda-waiting-requests"
  "keda-token-aware"
  "keda-token-cache-composite"
)

log() {
  echo "[$(date +%H:%M:%S)] $*"
}

cleanup() {
  if [[ -n "${PF_PID:-}" ]]; then
    kill "${PF_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

ensure_prereqs() {
  command -v kubectl >/dev/null
  command -v python >/dev/null
  test -f scripts/metrics/collect_metrics.py
  test -f scripts/benchmark/run_benchmark.py
}

start_prometheus_port_forward() {
  if [[ "${PROM_PORT_FORWARD}" != "1" ]]; then
    return
  fi

  if curl -sf "${PROM_URL}/-/ready" >/dev/null 2>&1; then
    log "Prometheus already reachable at ${PROM_URL}"
    return
  fi

  log "Starting Prometheus port-forward on ${PROM_URL}"
  kubectl -n "${PROM_NS}" port-forward "svc/${PROM_SVC}" 9090:9090 >/tmp/prom_port_forward.log 2>&1 &
  PF_PID=$!

  for _ in $(seq 1 20); do
    if curl -sf "${PROM_URL}/-/ready" >/dev/null 2>&1; then
      log "Prometheus port-forward ready"
      return
    fi
    sleep 1
  done

  log "Prometheus port-forward failed"
  cat /tmp/prom_port_forward.log || true
  exit 1
}

apply_monitoring() {
  log "Applying monitoring"
  bash scripts/apply_monitoring.sh --model "${MODEL_KEY}"
}

clear_autoscalers() {
  log "Clearing HPAs and ScaledObjects"
  kubectl delete hpa --all -n "${NS}" >/dev/null 2>&1 || true
  kubectl delete scaledobject --all -n "${NS}" >/dev/null 2>&1 || true
}

apply_policy() {
  local policy="$1"
  log "Applying policy: ${policy}"

  if [[ "${policy}" == hpa-* ]]; then
    bash scripts/create_hpa.sh --model "${MODEL_KEY}" --policy "${policy}"
  else
    bash scripts/apply_keda_scaledobject.sh --model "${MODEL_KEY}" --policy "${policy}"
  fi
}

reset_to_one_replica() {
  log "Resetting deployment to 1 replica"
  kubectl scale deploy "${DEPLOY}" -n "${NS}" --replicas=1
  kubectl rollout status "deploy/${DEPLOY}" -n "${NS}" --timeout=300s

  for _ in $(seq 1 30); do
    local ready
    ready="$(kubectl get deploy "${DEPLOY}" -n "${NS}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    ready="${ready:-0}"
    if [[ "${ready}" == "1" ]]; then
      log "Deployment is at 1 ready replica"
      return
    fi
    sleep 2
  done

  log "Deployment did not settle at 1 ready replica"
  kubectl get deploy "${DEPLOY}" -n "${NS}"
  exit 1
}

run_one_policy() {
  local policy="$1"
  local run_name="${policy}-queue-pressure"
  local local_dir="${RESULTS_ROOT}/${run_name}"
  local pod_dir="/work/out/${run_name}"

  mkdir -p "${local_dir}"

  clear_autoscalers
  apply_policy "${policy}"
  reset_to_one_replica

  log "Starting metrics collector for ${run_name}"
  python scripts/metrics/collect_metrics.py \
    --prom-url "${PROM_URL}" \
    --duration-seconds "${COLLECT_DURATION_SECONDS}" \
    --interval-seconds "${COLLECT_INTERVAL_SECONDS}" \
    --deployment-name "${DEPLOY}" \
    --model-name "${MODEL}" \
    --namespace "${NS}" \
    --outcsv "${local_dir}/system_metrics.csv" &
  local collector_pid=$!

  sleep 2

  log "Running benchmark for ${run_name}"
  kubectl -n "${NS}" exec "${POD}" -- bash -lc "
cd /work
mkdir -p '${pod_dir}'
PYTHONPATH=. python scripts/benchmark/run_benchmark.py \
  --target '${TARGET}' \
  --model-name '${MODEL}' \
  --scenario '${SCENARIO}' \
  --outdir '${pod_dir}' \
  --max-in-flight ${MAX_IN_FLIGHT} \
  --timeout-seconds ${TIMEOUT_SECONDS} \
  --drain-timeout-seconds ${DRAIN_TIMEOUT_SECONDS}
"

  log "Copying benchmark results for ${run_name}"
  kubectl -n "${NS}" cp "${POD}:${pod_dir}" "${local_dir}"

  log "Waiting for metrics collector to finish"
  wait "${collector_pid}"

  log "Finished ${run_name}"
  ls -1 "${local_dir}/${run_name}" || true
  echo
}

main() {
  ensure_prereqs
  start_prometheus_port_forward
  apply_monitoring

  for policy in "${POLICIES[@]}"; do
    run_one_policy "${policy}"
  done

  log "All runs complete"
}

main "$@"
