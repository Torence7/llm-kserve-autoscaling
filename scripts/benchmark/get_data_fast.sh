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
  bash scripts/benchmark/get_data_fast.sh --model <key|path>

Description:
  Runs a compact policy-eval matrix and builds a training CSV immediately.

Defaults:
  POLICY_LIST="hpa-cpu-baseline keda-waiting-requests keda-token-cache-composite"
  SCENARIO_LIST="short-bursts conversation sustained-mixed"
  REPEATS=1
  PROM_URL="http://localhost:9090"
  MAX_IN_FLIGHT=2
  BENCH_TIMEOUT_SECONDS=60
  DRAIN_TIMEOUT_SECONDS=120
  POLICY_SETTLE_SECONDS=15
  RESULTS_ROOT="results/policy_eval"
  TRAINING_OUTPUT="data/ml_training_fast.csv"

Examples:
  bash scripts/benchmark/get_data_fast.sh --model qwen25-0.5b-instruct
  POLICY_LIST="hpa-cpu-baseline keda-waiting-requests keda-token-cache-composite" \
  SCENARIO_LIST="short-bursts sustained-mixed" \
  bash scripts/benchmark/get_data_fast.sh --model qwen25-0.5b-instruct
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

# Resolve model details and derive the model-key used by collect_training_data.py.
load_model_config "${MODEL_ARG}"

POLICY_LIST="${POLICY_LIST:-hpa-cpu-baseline keda-waiting-requests keda-token-cache-composite}"
SCENARIO_LIST="${SCENARIO_LIST:-short-bursts conversation sustained-mixed}"
REPEATS="${REPEATS:-1}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
MAX_IN_FLIGHT="${MAX_IN_FLIGHT:-2}"
BENCH_TIMEOUT_SECONDS="${BENCH_TIMEOUT_SECONDS:-60}"
DRAIN_TIMEOUT_SECONDS="${DRAIN_TIMEOUT_SECONDS:-120}"
POLICY_SETTLE_SECONDS="${POLICY_SETTLE_SECONDS:-15}"
RESULTS_ROOT="${RESULTS_ROOT:-results/policy_eval}"
TRAINING_OUTPUT="${TRAINING_OUTPUT:-data/ml_training_fast.csv}"
MIN_REPLICAS="${MIN_REPLICAS:-1}"
MAX_REPLICAS="${MAX_REPLICAS:-5}"

log "Starting fast data collection"
log "Model arg: ${MODEL_ARG}"
log "Resolved model key: ${MODEL_KEY}"
log "Policies: ${POLICY_LIST}"
log "Scenarios: ${SCENARIO_LIST}"
log "Repeats: ${REPEATS}"
log "Prometheus URL: ${PROM_URL}"

POLICY_LIST="${POLICY_LIST}" \
SCENARIO_LIST="${SCENARIO_LIST}" \
REPEATS="${REPEATS}" \
PROM_URL="${PROM_URL}" \
MAX_IN_FLIGHT="${MAX_IN_FLIGHT}" \
BENCH_TIMEOUT_SECONDS="${BENCH_TIMEOUT_SECONDS}" \
DRAIN_TIMEOUT_SECONDS="${DRAIN_TIMEOUT_SECONDS}" \
POLICY_SETTLE_SECONDS="${POLICY_SETTLE_SECONDS}" \
bash "${REPO_ROOT}/scripts/benchmark/run_fast_matrix.sh" --model "${MODEL_ARG}"

log "Building training CSV from fresh runs"
python "${REPO_ROOT}/scripts/ml_autoscaler/collect_training_data.py" \
  --results-root "${RESULTS_ROOT}" \
  --model-key "${MODEL_KEY}" \
  --output "${TRAINING_OUTPUT}" \
  --min-replicas "${MIN_REPLICAS}" \
  --max-replicas "${MAX_REPLICAS}"

if [[ -f "${TRAINING_OUTPUT}" ]]; then
  sample_count=$(( $(wc -l < "${TRAINING_OUTPUT}") - 1 ))
  if (( sample_count < 0 )); then
    sample_count=0
  fi
  log "Fast data pipeline complete"
  log "Training CSV: ${TRAINING_OUTPUT}"
  log "Samples: ${sample_count}"
else
  die "Training CSV was not created: ${TRAINING_OUTPUT}"
fi
