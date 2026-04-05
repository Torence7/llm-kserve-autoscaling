#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"
# shellcheck source=../lib/model.sh
source "${REPO_ROOT}/scripts/lib/model.sh"

usage() {
  cat <<'USAGE'
Usage:
  bash scripts/benchmark/run_policy_study.sh --model <key|path>

Optional environment variables:
  POLICY_LIST="hpa-cpu-baseline keda-waiting-requests keda-token-aware keda-token-cache-composite"
  SCENARIO_LIST="sustained-mixed long-context conversation"
  REPEATS=3
  RESULTS_ROOT="results/policy_study"
  PROM_URL="http://localhost:9090"
  METRIC_INTERVAL=5
  POLICY_SETTLE_SECONDS=45
  BENCH_TIMEOUT_SECONDS=30
  DRAIN_TIMEOUT_SECONDS=20
  MAX_IN_FLIGHT=4
  COOLDOWN_SECONDS=30
  FAIL_FAST=0

Example:
  REPEATS=3 MAX_IN_FLIGHT=4 \
  POLICY_LIST="hpa-cpu-baseline keda-waiting-requests keda-token-aware keda-token-cache-composite" \
  SCENARIO_LIST="sustained-mixed long-context conversation" \
  bash scripts/benchmark/run_policy_study.sh --model qwen25-0.5b-instruct
USAGE
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

POLICY_LIST="${POLICY_LIST:-hpa-cpu-baseline keda-waiting-requests keda-token-aware keda-token-cache-composite}"
SCENARIO_LIST="${SCENARIO_LIST:-sustained-mixed long-context conversation}"
REPEATS="${REPEATS:-3}"
RESULTS_ROOT="${RESULTS_ROOT:-${REPO_ROOT}/results/policy_study}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
METRIC_INTERVAL="${METRIC_INTERVAL:-5}"
POLICY_SETTLE_SECONDS="${POLICY_SETTLE_SECONDS:-45}"
BENCH_TIMEOUT_SECONDS="${BENCH_TIMEOUT_SECONDS:-30}"
DRAIN_TIMEOUT_SECONDS="${DRAIN_TIMEOUT_SECONDS:-20}"
MAX_IN_FLIGHT="${MAX_IN_FLIGHT:-4}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-30}"
FAIL_FAST="${FAIL_FAST:-0}"

need_cmd kubectl

TARGET="${TARGET:-http://localhost:${LOCAL_PORT}/v1}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-${WORKER_DEPLOYMENT_NAME}}"
STUDY_TS="$(date +%Y%m%d_%H%M%S)"
STUDY_ROOT="${RESULTS_ROOT}/${MODEL_KEY}/study_${STUDY_TS}"
mkdir -p "${STUDY_ROOT}"

save_cluster_state() {
  local outdir="$1"

  kubectl get deploy -n "${NAMESPACE}" "${DEPLOYMENT_NAME}" -o yaml > "${outdir}/deployment.yaml" 2>/dev/null || true
  kubectl get pods -n "${NAMESPACE}" -o wide > "${outdir}/pods.txt" 2>/dev/null || true
  kubectl get hpa -n "${NAMESPACE}" -o yaml > "${outdir}/hpa.yaml" 2>/dev/null || true
  kubectl get scaledobject -n "${NAMESPACE}" -o yaml > "${outdir}/scaledobjects.yaml" 2>/dev/null || true
  kubectl get events -n "${NAMESPACE}" --sort-by=.lastTimestamp > "${outdir}/events.txt" 2>/dev/null || true
}

log "Model file: ${MODEL_FILE}"
log "Model key: ${MODEL_KEY}"
log "Namespace: ${NAMESPACE}"
log "Deployment name: ${DEPLOYMENT_NAME}"
log "Target endpoint: ${TARGET}"
log "Study root: ${STUDY_ROOT}"
log "Policies: ${POLICY_LIST}"
log "Scenarios: ${SCENARIO_LIST}"
log "Repeats: ${REPEATS}"

printf '{\n' > "${STUDY_ROOT}/study_config.json"
printf '  "model_file": "%s",\n' "${MODEL_FILE}" >> "${STUDY_ROOT}/study_config.json"
printf '  "model_key": "%s",\n' "${MODEL_KEY}" >> "${STUDY_ROOT}/study_config.json"
printf '  "target": "%s",\n' "${TARGET}" >> "${STUDY_ROOT}/study_config.json"
printf '  "prom_url": "%s",\n' "${PROM_URL}" >> "${STUDY_ROOT}/study_config.json"
printf '  "policy_list": "%s",\n' "${POLICY_LIST}" >> "${STUDY_ROOT}/study_config.json"
printf '  "scenario_list": "%s",\n' "${SCENARIO_LIST}" >> "${STUDY_ROOT}/study_config.json"
printf '  "repeats": %s,\n' "${REPEATS}" >> "${STUDY_ROOT}/study_config.json"
printf '  "metric_interval": %s,\n' "${METRIC_INTERVAL}" >> "${STUDY_ROOT}/study_config.json"
printf '  "policy_settle_seconds": %s,\n' "${POLICY_SETTLE_SECONDS}" >> "${STUDY_ROOT}/study_config.json"
printf '  "bench_timeout_seconds": %s,\n' "${BENCH_TIMEOUT_SECONDS}" >> "${STUDY_ROOT}/study_config.json"
printf '  "drain_timeout_seconds": %s,\n' "${DRAIN_TIMEOUT_SECONDS}" >> "${STUDY_ROOT}/study_config.json"
printf '  "max_in_flight": %s\n' "${MAX_IN_FLIGHT}" >> "${STUDY_ROOT}/study_config.json"
printf '}\n' >> "${STUDY_ROOT}/study_config.json"

run_index=0
for policy in ${POLICY_LIST}; do
  for scenario in ${SCENARIO_LIST}; do
    for repeat in $(seq 1 "${REPEATS}"); do
      run_index=$((run_index + 1))
      log "=================================================="
      log "Run ${run_index}: policy=${policy} scenario=${scenario} repeat=${repeat}"
      log "=================================================="

      run_log="${STUDY_ROOT}/run_${run_index}_${policy}_${scenario}_r${repeat}.log"
      before_list="${STUDY_ROOT}/before_${run_index}.txt"
      find "${RESULTS_ROOT}/${MODEL_KEY}/${scenario}" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort > "${before_list}" || true

      set +e
      RESULTS_ROOT="${RESULTS_ROOT}" \
      PROM_URL="${PROM_URL}" \
      METRIC_INTERVAL="${METRIC_INTERVAL}" \
      POLICY_SETTLE_SECONDS="${POLICY_SETTLE_SECONDS}" \
      BENCH_TIMEOUT_SECONDS="${BENCH_TIMEOUT_SECONDS}" \
      DRAIN_TIMEOUT_SECONDS="${DRAIN_TIMEOUT_SECONDS}" \
      MAX_IN_FLIGHT="${MAX_IN_FLIGHT}" \
      bash "${REPO_ROOT}/scripts/benchmark/run_policy_eval.sh" \
        --model "${MODEL_FILE}" \
        --policy "${policy}" \
        --scenario "${scenario}" > "${run_log}" 2>&1
      status=$?
      set -e

      after_list="${STUDY_ROOT}/after_${run_index}.txt"
      find "${RESULTS_ROOT}/${MODEL_KEY}/${scenario}" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort > "${after_list}" || true
      run_dir="$(comm -13 "${before_list}" "${after_list}" | tail -n 1)"

      if [[ -n "${run_dir}" && -d "${run_dir}" ]]; then
        mkdir -p "${run_dir}/cluster_state"
        save_cluster_state "${run_dir}/cluster_state"
        cp "${run_log}" "${run_dir}/driver.log"
        cat > "${run_dir}/study_run.json" <<JSON
{
  "study_root": "${STUDY_ROOT}",
  "run_index": ${run_index},
  "repeat": ${repeat},
  "policy": "${policy}",
  "scenario": "${scenario}",
  "exit_code": ${status}
}
JSON
      fi

      if [[ ${status} -ne 0 ]]; then
        log "Run failed with exit code ${status}: policy=${policy} scenario=${scenario} repeat=${repeat}"
        if [[ "${FAIL_FAST}" == "1" ]]; then
          exit ${status}
        fi
      fi

      if [[ ${repeat} -lt ${REPEATS} ]]; then
        log "Cooling down for ${COOLDOWN_SECONDS}s before next repeat..."
        sleep "${COOLDOWN_SECONDS}"
      fi
    done
  done
done

python -u "${REPO_ROOT}/scripts/benchmark/summarize_policy_study.py" \
  --results-root "${RESULTS_ROOT}" \
  --model-key "${MODEL_KEY}" \
  --study-root "${STUDY_ROOT}"

log "Policy study complete."
log "Study root: ${STUDY_ROOT}"