#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-llm-demo}"
POD="${POD:-bench-client}"
MODEL="${MODEL:-Qwen/Qwen2.5-0.5B-Instruct}"
MODEL_KEY="${MODEL_KEY:-qwen25_05b_instruct}"
DEPLOY="${DEPLOY:-qwen25-0-5b-instruct-kserve}"
TARGET="${TARGET:-http://qwen25-0-5b-instruct-kserve-workload-svc.llm-demo.svc.cluster.local:8000/v1}"

SCENARIO="${SCENARIO:-configs/scenarios/queue-pressure.yaml}"
RESULTS_ROOT="${RESULTS_ROOT:-results/incluster}"
MAX_IN_FLIGHT="${MAX_IN_FLIGHT:-4}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-420}"
DRAIN_TIMEOUT_SECONDS="${DRAIN_TIMEOUT_SECONDS:-600}"
COLLECT_DURATION_SECONDS="${COLLECT_DURATION_SECONDS:-720}"
COLLECT_INTERVAL_SECONDS="${COLLECT_INTERVAL_SECONDS:-5}"

PROM_PORT_FORWARD="${PROM_PORT_FORWARD:-1}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
PROM_NS="${PROM_NS:-monitoring}"
PROM_SVC="${PROM_SVC:-prometheus-kube-prometheus-prometheus}"

REPO_ROOT="${REPO_ROOT:-$PWD}"

DEFAULT_POLICIES=(
  "hpa-cpu-baseline"
  "keda-token-aware"
  "keda-token-cache-composite"
  "keda-waiting-requests"
)

if [[ -n "${POLICY_LIST:-}" ]]; then
  read -r -a POLICIES <<< "${POLICY_LIST}"
else
  POLICIES=("${DEFAULT_POLICIES[@]}")
fi

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

ensure_bench_pod_ready() {
  if ! kubectl get pod "${POD}" -n "${NS}" >/dev/null 2>&1; then
    log "bench pod ${POD} not found in ${NS}"
    exit 1
  fi

  local phase
  phase="$(kubectl get pod "${POD}" -n "${NS}" -o jsonpath='{.status.phase}')"

  if [[ "${phase}" != "Running" ]]; then
    log "bench pod ${POD} is in phase ${phase}, not Running"
    kubectl get pod "${POD}" -n "${NS}" -o wide || true
    exit 1
  fi

  kubectl exec -n "${NS}" "${POD}" -- python --version >/dev/null
}

sync_repo_to_bench_pod() {
  log "Syncing repo into ${POD}:/work"
  kubectl exec -n "${NS}" "${POD}" -- rm -rf /work
  kubectl exec -n "${NS}" "${POD}" -- mkdir -p /work
  kubectl cp "${REPO_ROOT}/." "${NS}/${POD}:/work"

  kubectl exec -n "${NS}" "${POD}" -- bash -lc "
set -e
test -f /work/scripts/benchmark/run_benchmark.py
test -f /work/${SCENARIO}
python /work/scripts/benchmark/run_benchmark.py --help >/dev/null
echo 'Scenario inside pod:'
sed -n '1,80p' /work/${SCENARIO}
"
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
  sleep 5
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
  kubectl get deploy "${DEPLOY}" -n "${NS}" -o wide || true
  kubectl get pods -n "${NS}" -o wide || true
  exit 1
}

wait_for_autoscaler_ready() {
  local policy="$1"

  if [[ "${policy}" == hpa-* ]]; then
    log "Waiting for HPA ${DEPLOY} to appear"
    for _ in $(seq 1 30); do
      if kubectl get hpa -n "${NS}" "${DEPLOY}" >/dev/null 2>&1; then
        log "HPA ${DEPLOY} is present"
        return
      fi
      sleep 2
    done

    log "Timed out waiting for HPA ${DEPLOY}"
    kubectl get hpa -n "${NS}" || true
    exit 1
  fi

  local so_name="${MODEL_KEY//_/-}-${policy}"
  log "Waiting for ScaledObject ${so_name} and its generated HPA"

  for _ in $(seq 1 60); do
    local so_ready hpa_count
    so_ready="$(kubectl get scaledobject -n "${NS}" "${so_name}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    hpa_count="$(kubectl get hpa -n "${NS}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"

    if [[ "${so_ready}" == "True" && "${hpa_count}" -ge 1 ]]; then
      log "ScaledObject ${so_name} is Ready and an HPA exists"
      return
    fi
    sleep 2
  done

  log "Timed out waiting for KEDA autoscaler readiness"
  kubectl get scaledobject -n "${NS}" || true
  kubectl get hpa -n "${NS}" || true
  exit 1
}

capture_autoscaler_state() {
  local local_dir="$1"
  local prefix="$2"

  {
    echo "# timestamp"
    date
    echo
    echo "# scaledobjects"
    kubectl get scaledobject -n "${NS}" -o wide || true
    echo
    echo "# hpa"
    kubectl get hpa -n "${NS}" -o wide || true
    echo
    echo "# deployment"
    kubectl get deploy "${DEPLOY}" -n "${NS}" -o wide || true
    echo
    echo "# pods"
    kubectl get pods -n "${NS}" -o wide || true
  } > "${local_dir}/${prefix}_autoscaler_overview.txt"

  if kubectl get scaledobject -n "${NS}" >/dev/null 2>&1; then
    kubectl describe scaledobject -n "${NS}" > "${local_dir}/${prefix}_scaledobject_describe.txt" 2>&1 || true
  fi

  if kubectl get hpa -n "${NS}" >/dev/null 2>&1; then
    kubectl describe hpa -n "${NS}" > "${local_dir}/${prefix}_hpa_describe.txt" 2>&1 || true
  fi

  kubectl describe deploy "${DEPLOY}" -n "${NS}" > "${local_dir}/${prefix}_deploy_describe.txt" 2>&1 || true
  kubectl get events -n "${NS}" --sort-by=.metadata.creationTimestamp > "${local_dir}/${prefix}_events.txt" 2>&1 || true
  kubectl logs -n keda deploy/keda-operator --tail=200 > "${local_dir}/${prefix}_keda_operator.log" 2>&1 || true
}

run_one_policy() {
  local policy="$1"
  local run_name="${policy}-queue-pressure"
  local local_dir="${RESULTS_ROOT}/${run_name}"
  local benchmark_dir="${local_dir}/benchmark"
  local pod_dir="/work/out/${run_name}"

  mkdir -p "${local_dir}"
  mkdir -p "${benchmark_dir}"

  clear_autoscalers
  apply_policy "${policy}"
  wait_for_autoscaler_ready "${policy}"
  reset_to_one_replica

  log "Capturing autoscaler state before benchmark"
  capture_autoscaler_state "${local_dir}" "before"

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

  sleep 10

  log "Running benchmark for ${run_name}"
  if ! kubectl -n "${NS}" exec "${POD}" -- bash -lc "
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
"; then
    log "Benchmark exec failed; stopping metrics collector"
    kill "${collector_pid}" >/dev/null 2>&1 || true
    wait "${collector_pid}" 2>/dev/null || true
    exit 1
  fi

  log "Copying benchmark results for ${run_name}"
  kubectl -n "${NS}" cp "${POD}:${pod_dir}/." "${benchmark_dir}"

  log "Waiting for metrics collector to finish"
  wait "${collector_pid}"

  log "Capturing autoscaler state after benchmark"
  capture_autoscaler_state "${local_dir}" "after"

  log "Finished ${run_name}"
  ls -1 "${benchmark_dir}" || true
  echo
}

main() {
  ensure_prereqs
  ensure_bench_pod_ready
  sync_repo_to_bench_pod
  start_prometheus_port_forward
  apply_monitoring

  for policy in "${POLICIES[@]}"; do
    run_one_policy "${policy}"
  done

  log "All runs complete"
}

main "$@"