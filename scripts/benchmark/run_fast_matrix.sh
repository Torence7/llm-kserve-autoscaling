#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"

usage() {
  cat <<EOF
Usage:
  bash scripts/benchmark/run_fast_matrix.sh --model <key|path>

Examples:
  bash scripts/benchmark/run_fast_matrix.sh --model qwen25-0.5b-instruct
  bash scripts/benchmark/run_fast_matrix.sh --model configs/models/qwen25-0.5b-instruct.yaml

Optional environment variables:
  POLICY_LIST="hpa-cpu-baseline keda-waiting-requests keda-token-cache-composite"
  SCENARIO_LIST="short-bursts"
  REPEATS=1
  PROM_URL="http://localhost:9090"
  MAX_IN_FLIGHT=2
  BENCH_TIMEOUT_SECONDS=45
  DRAIN_TIMEOUT_SECONDS=60
  POLICY_SETTLE_SECONDS=15
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

POLICY_LIST="${POLICY_LIST:-hpa-cpu-baseline keda-waiting-requests keda-token-cache-composite}"
SCENARIO_LIST="${SCENARIO_LIST:-short-bursts}"
REPEATS="${REPEATS:-1}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
MAX_IN_FLIGHT="${MAX_IN_FLIGHT:-2}"
BENCH_TIMEOUT_SECONDS="${BENCH_TIMEOUT_SECONDS:-45}"
DRAIN_TIMEOUT_SECONDS="${DRAIN_TIMEOUT_SECONDS:-60}"
POLICY_SETTLE_SECONDS="${POLICY_SETTLE_SECONDS:-15}"

log "Running fast matrix"
log "Model: ${MODEL_ARG}"
log "Policies: ${POLICY_LIST}"
log "Scenarios: ${SCENARIO_LIST}"
log "Repeats: ${REPEATS}"
log "PROM_URL: ${PROM_URL}"

for policy in ${POLICY_LIST}; do
  for scenario in ${SCENARIO_LIST}; do
    for repeat in $(seq 1 "${REPEATS}"); do
      log "--------------------------------------------------"
      log "Run: policy=${policy} scenario=${scenario} repeat=${repeat}/${REPEATS}"
      log "--------------------------------------------------"

      PROM_URL="${PROM_URL}" \
      MAX_IN_FLIGHT="${MAX_IN_FLIGHT}" \
      BENCH_TIMEOUT_SECONDS="${BENCH_TIMEOUT_SECONDS}" \
      DRAIN_TIMEOUT_SECONDS="${DRAIN_TIMEOUT_SECONDS}" \
      POLICY_SETTLE_SECONDS="${POLICY_SETTLE_SECONDS}" \
      bash "${REPO_ROOT}/scripts/benchmark/run_policy_eval.sh" \
        --model "${MODEL_ARG}" \
        --policy "${policy}" \
        --scenario "${scenario}"
    done
  done
done

log "Fast matrix complete."
