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
  bash scripts/benchmark/run_matrix.sh --model phi3-mini-4k-instruct
  bash scripts/benchmark/run_matrix.sh --model configs/models/phi3-mini-4k-instruct.yaml

Optional environment overrides:
  REPLICAS="1 2 3 4 5"
  SCENARIOS="short-bursts sustained-mixed long-context conversation"
  RESULTS_ROOT=results/benchmark
  PROM_URL=http://localhost:9090
  METRIC_INTERVAL=15
  TIMEOUT_SECONDS=180
  MAX_IN_FLIGHT=32
  COOLDOWN_SECONDS=20
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

load_model_config "$MODEL_ARG"

REPLICAS="${REPLICAS:-1 2 3 4 5}"
SCENARIOS="${SCENARIOS:-short-bursts sustained-mixed long-context conversation}"
RESULTS_ROOT="${RESULTS_ROOT:-${REPO_ROOT}/results/benchmark}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
METRIC_INTERVAL="${METRIC_INTERVAL:-15}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-180}"
MAX_IN_FLIGHT="${MAX_IN_FLIGHT:-32}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-20}"

TARGET="${TARGET:-http://localhost:${LOCAL_PORT}/v1}"

timestamp="$(date +%Y%m%d_%H%M%S)"
run_root="${RESULTS_ROOT}/${MODEL_KEY}_${timestamp}"
mkdir -p "${run_root}"

log "Model key: ${MODEL_KEY}"
log "Target: ${TARGET}"
log "Results root: ${run_root}"

# You may need to adjust this deployment name depending on how your KServe stack names the underlying deployment.
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-${LLMISVC_NAME}-predictor}"

for scenario_name in ${SCENARIOS}; do
  scenario_path="${REPO_ROOT}/configs/scenarios/${scenario_name}.yaml"
  [[ -f "${scenario_path}" ]] || die "Scenario file not found: ${scenario_path}"

  duration_seconds="$(python3 - <<PY
import yaml
with open("${scenario_path}", "r", encoding="utf-8") as f:
    cfg = yaml.safe_load(f)
print(int(cfg["duration_seconds"]))
PY
)"

  for replica_count in ${REPLICAS}; do
    run_dir="${run_root}/${scenario_name}/replicas_${replica_count}"
    mkdir -p "${run_dir}"

    log "========================================"
    log "Scenario: ${scenario_name}"
    log "Replicas: ${replica_count}"
    log "Run dir: ${run_dir}"
    log "========================================"

    # Turn autoscaling off if you have a helper for that.
    # If not, this manual scale step is enough for a first version.
    kubectl scale deployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" --replicas="${replica_count}"

    log "Waiting for deployment rollout..."
    kubectl rollout status deployment "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" --timeout=300s

    log "Starting Prometheus metrics collection..."
    python3 "${REPO_ROOT}/scripts/metrics/collect_metrics.py" \
      --prom-url "${PROM_URL}" \
      --duration-seconds "${duration_seconds}" \
      --interval-seconds "${METRIC_INTERVAL}" \
      --deployment-name "${DEPLOYMENT_NAME}" \
      --outcsv "${run_dir}/system_metrics.csv" &
    METRICS_PID=$!

    log "Running benchmark traffic..."
    python3 "${REPO_ROOT}/scripts/benchmark/run_benchmark.py" \
      --target "${TARGET}" \
      --model-name "${SERVED_MODEL_NAME}" \
      --scenario "${scenario_path}" \
      --outdir "${run_dir}" \
      --timeout-seconds "${TIMEOUT_SECONDS}" \
      --max-in-flight "${MAX_IN_FLIGHT}"

    wait "${METRICS_PID}" || true

    cat > "${run_dir}/metadata.json" <<EOF
{
  "model_key": "${MODEL_KEY}",
  "served_model_name": "${SERVED_MODEL_NAME}",
  "namespace": "${NAMESPACE}",
  "llmisvc_name": "${LLMISVC_NAME}",
  "deployment_name": "${DEPLOYMENT_NAME}",
  "local_port": ${LOCAL_PORT},
  "remote_port": ${REMOTE_PORT},
  "target": "${TARGET}",
  "scenario": "${scenario_name}",
  "replicas": ${replica_count},
  "metric_interval_seconds": ${METRIC_INTERVAL}
}
EOF

    log "Cooling down for ${COOLDOWN_SECONDS}s..."
    sleep "${COOLDOWN_SECONDS}"
  done
done

log "Benchmark matrix complete."
log "Results saved in: ${run_root}"