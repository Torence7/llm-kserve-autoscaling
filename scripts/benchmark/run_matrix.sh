#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"
# shellcheck source=../lib/model.sh
source "${REPO_ROOT}/scripts/lib/model.sh"

usage() {
  cat <<EOF
Usage:
  bash scripts/benchmark/run_matrix.sh --model <key|path>

Examples:
  bash scripts/benchmark/run_matrix.sh --model qwen25-0.5b-instruct
  bash scripts/benchmark/run_matrix.sh --model configs/models/qwen25-0.5b-instruct.yaml

Optional environment variables:
  REPLICA_LIST="1 2 3"
  SCENARIO_LIST="short-bursts long-context"
  RESULTS_ROOT="results/benchmark"
  PROM_URL="http://localhost:9090"
  METRIC_INTERVAL=5
  COOLDOWN_SECONDS=10
  BENCH_TIMEOUT_SECONDS=15
  DRAIN_TIMEOUT_SECONDS=5
  MAX_IN_FLIGHT=1
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

[[ -n "${MODEL_ARG}" ]] || { usage; exit 1; }

need_model_tools
need_cmd python
load_model_config "${MODEL_ARG}"

REPLICA_LIST="${REPLICA_LIST:-1 2 3}"
SCENARIO_LIST="${SCENARIO_LIST:-short-bursts long-context}"
RESULTS_ROOT="${RESULTS_ROOT:-${REPO_ROOT}/results/benchmark}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
METRIC_INTERVAL="${METRIC_INTERVAL:-5}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-10}"
BENCH_TIMEOUT_SECONDS="${BENCH_TIMEOUT_SECONDS:-15}"
DRAIN_TIMEOUT_SECONDS="${DRAIN_TIMEOUT_SECONDS:-5}"
MAX_IN_FLIGHT="${MAX_IN_FLIGHT:-1}"

TARGET="${TARGET:-http://localhost:${LOCAL_PORT}/v1}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-${WORKER_DEPLOYMENT_NAME}}"

timestamp="$(date +%Y%m%d_%H%M%S)"
run_root="${RESULTS_ROOT}/${MODEL_KEY}_${timestamp}"
mkdir -p "${run_root}"

log "Model file: ${MODEL_FILE}"
log "Model key: ${MODEL_KEY}"
log "Deployment name: ${DEPLOYMENT_NAME}"
log "Namespace: ${NAMESPACE}"
log "Target endpoint: ${TARGET}"
log "Scenarios: ${SCENARIO_LIST}"
log "Replicas: ${REPLICA_LIST}"
log "Results root: ${run_root}"

for scenario_name in ${SCENARIO_LIST}; do
  scenario_path="${REPO_ROOT}/configs/scenarios/${scenario_name}.yaml"
  [[ -f "${scenario_path}" ]] || die "Scenario file not found: ${scenario_path}"

  duration_seconds="$(python - <<PY
import yaml
with open("${scenario_path}", "r", encoding="utf-8") as f:
    cfg = yaml.safe_load(f)
print(int(cfg["duration_seconds"]))
PY
)"

  metric_duration_seconds=$(( duration_seconds + DRAIN_TIMEOUT_SECONDS + 5 ))

  for replica_count in ${REPLICA_LIST}; do
    run_dir="${run_root}/${scenario_name}/replicas_${replica_count}"
    mkdir -p "${run_dir}"

    log "--------------------------------------------------"
    log "Scenario: ${scenario_name}"
    log "Replicas: ${replica_count}"
    log "Run dir: ${run_dir}"
    log "--------------------------------------------------"

    log "Scaling deployment ${DEPLOYMENT_NAME} to ${replica_count} replicas"
    kubectl scale deployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" --replicas="${replica_count}"

    log "Waiting for rollout to complete..."
    kubectl rollout status deployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" --timeout=600s

    log "Starting Prometheus metric collection..."
    python -u "${REPO_ROOT}/scripts/metrics/collect_metrics.py" \
      --prom-url "${PROM_URL}" \
      --duration-seconds "${metric_duration_seconds}" \
      --interval-seconds "${METRIC_INTERVAL}" \
      --deployment-name "${DEPLOYMENT_NAME}" \
      --namespace "${NAMESPACE}" \
      --outcsv "${run_dir}/system_metrics.csv" &
    METRICS_PID=$!

    log "Running benchmark traffic..."
    python -u "${REPO_ROOT}/scripts/benchmark/run_benchmark.py" \
      --target "${TARGET}" \
      --model-name "${SERVED_MODEL_NAME}" \
      --scenario "${scenario_path}" \
      --outdir "${run_dir}" \
      --max-in-flight "${MAX_IN_FLIGHT}" \
      --timeout-seconds "${BENCH_TIMEOUT_SECONDS}" \
      --drain-timeout-seconds "${DRAIN_TIMEOUT_SECONDS}"

    log "Waiting for metrics collector to finish..."
    wait "${METRICS_PID}"

    cat > "${run_dir}/metadata.json" <<EOF
{
  "model_file": "${MODEL_FILE}",
  "model_key": "${MODEL_KEY}",
  "served_model_name": "${SERVED_MODEL_NAME}",
  "namespace": "${NAMESPACE}",
  "deployment_name": "${DEPLOYMENT_NAME}",
  "scenario": "${scenario_name}",
  "scenario_path": "${scenario_path}",
  "replicas": ${replica_count},
  "target": "${TARGET}",
  "prom_url": "${PROM_URL}",
  "metric_interval_seconds": ${METRIC_INTERVAL},
  "benchmark_timeout_seconds": ${BENCH_TIMEOUT_SECONDS},
  "drain_timeout_seconds": ${DRAIN_TIMEOUT_SECONDS},
  "max_in_flight": ${MAX_IN_FLIGHT}
}
EOF

    log "Cooling down for ${COOLDOWN_SECONDS}s..."
    sleep "${COOLDOWN_SECONDS}"
  done
done

log "Benchmark matrix complete."
log "Results saved under: ${run_root}"