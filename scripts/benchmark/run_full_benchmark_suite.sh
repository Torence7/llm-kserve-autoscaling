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
  bash scripts/benchmark/run_full_benchmark_suite.sh

This runs policy/scenario benchmarking across multiple models by repeatedly
calling scripts/benchmark/run_policy_eval.sh.

Optional environment variables:
  MODEL_LIST="facebook-opt-125m qwen25-0.5b-instruct tinyllama-1.1b-chat phi3-mini-4k-instruct"
  POLICY_LIST="hpa-cpu-baseline keda-waiting-requests keda-token-aware keda-token-cache-composite"
  SCENARIO_LIST="short-bursts sustained-mixed long-context conversation conversation-realistic"
  REPEATS=3
  FAIL_FAST=0

  RESULTS_ROOT="results/policy_eval"
  SUITE_RESULTS_ROOT="results/benchmark_suites"

  PROM_URL="http://localhost:9090"
  METRIC_INTERVAL=5
  POLICY_SETTLE_SECONDS=20
  BENCH_TIMEOUT_SECONDS=15
  DRAIN_TIMEOUT_SECONDS=5
  MAX_IN_FLIGHT=1
  COOLDOWN_SECONDS=20

  AUTO_DEPLOY=0
  AUTO_DELETE_MODEL=0
  AUTO_PORT_FORWARD_MODEL=0
  AUTO_PORT_FORWARD_PROM=0
  AUTO_APPLY_MONITORING=0
  PORT_FORWARD_WAIT_SECONDS=30

  PROM_NAMESPACE="monitoring"
  PROM_SERVICE="prometheus-kube-prometheus-prometheus"
  PROM_LOCAL_PORT=9090
  PROM_REMOTE_PORT=9090

Examples:
  # Run everything in configs/models, configs/policies, configs/scenarios once
  REPEATS=1 bash scripts/benchmark/run_full_benchmark_suite.sh

  # Run a targeted subset
  MODEL_LIST="qwen25-0.5b-instruct tinyllama-1.1b-chat" \
  POLICY_LIST="hpa-cpu-baseline keda-waiting-requests" \
  SCENARIO_LIST="short-bursts long-context" \
  REPEATS=3 \
  bash scripts/benchmark/run_full_benchmark_suite.sh
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

need_model_tools
need_cmd python
need_cmd find
need_cmd sort
need_cmd comm
need_cmd kubectl

default_model_list="$(
  find "${REPO_ROOT}/configs/models" -maxdepth 1 -name '*.yaml' -type f \
    | sort \
    | sed -E 's#^.*/##; s#\.yaml$##' \
    | tr '\n' ' ' \
    | sed 's/[[:space:]]*$//'
)"
default_policy_list="$(
  find "${REPO_ROOT}/configs/policies" -maxdepth 1 -name '*.yaml' -type f \
    | sort \
    | sed -E 's#^.*/##; s#\.yaml$##' \
    | tr '\n' ' ' \
    | sed 's/[[:space:]]*$//'
)"
default_scenario_list="$(
  find "${REPO_ROOT}/configs/scenarios" -maxdepth 1 -name '*.yaml' -type f \
    | sort \
    | sed -E 's#^.*/##; s#\.yaml$##' \
    | tr '\n' ' ' \
    | sed 's/[[:space:]]*$//'
)"

MODEL_LIST="${MODEL_LIST:-${default_model_list}}"
POLICY_LIST="${POLICY_LIST:-${default_policy_list}}"
SCENARIO_LIST="${SCENARIO_LIST:-${default_scenario_list}}"
REPEATS="${REPEATS:-1}"
FAIL_FAST="${FAIL_FAST:-0}"

RESULTS_ROOT="${RESULTS_ROOT:-${REPO_ROOT}/results/policy_eval}"
SUITE_RESULTS_ROOT="${SUITE_RESULTS_ROOT:-${REPO_ROOT}/results/benchmark_suites}"

PROM_URL="${PROM_URL:-http://localhost:9090}"
METRIC_INTERVAL="${METRIC_INTERVAL:-5}"
POLICY_SETTLE_SECONDS="${POLICY_SETTLE_SECONDS:-20}"
BENCH_TIMEOUT_SECONDS="${BENCH_TIMEOUT_SECONDS:-15}"
DRAIN_TIMEOUT_SECONDS="${DRAIN_TIMEOUT_SECONDS:-5}"
MAX_IN_FLIGHT="${MAX_IN_FLIGHT:-1}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-20}"
AUTO_DEPLOY="${AUTO_DEPLOY:-0}"
AUTO_DELETE_MODEL="${AUTO_DELETE_MODEL:-0}"
AUTO_PORT_FORWARD_MODEL="${AUTO_PORT_FORWARD_MODEL:-0}"
AUTO_PORT_FORWARD_PROM="${AUTO_PORT_FORWARD_PROM:-0}"
AUTO_APPLY_MONITORING="${AUTO_APPLY_MONITORING:-0}"
PORT_FORWARD_WAIT_SECONDS="${PORT_FORWARD_WAIT_SECONDS:-30}"
PROM_NAMESPACE="${PROM_NAMESPACE:-monitoring}"
PROM_SERVICE="${PROM_SERVICE:-prometheus-kube-prometheus-prometheus}"
PROM_LOCAL_PORT="${PROM_LOCAL_PORT:-9090}"
PROM_REMOTE_PORT="${PROM_REMOTE_PORT:-9090}"

[[ -n "${MODEL_LIST}" ]] || die "MODEL_LIST is empty"
[[ -n "${POLICY_LIST}" ]] || die "POLICY_LIST is empty"
[[ -n "${SCENARIO_LIST}" ]] || die "SCENARIO_LIST is empty"

suite_ts="$(date +%Y%m%d_%H%M%S)"
suite_root="${SUITE_RESULTS_ROOT}/suite_${suite_ts}"
mkdir -p "${suite_root}"

summary_tsv="${suite_root}/summary.tsv"
printf 'run_index\tmodel\tpolicy\tscenario\trepeat\texit_code\trun_dir\tlog_file\n' > "${summary_tsv}"

MODEL_PF_PID=""
PROM_PF_PID=""

wait_for_tcp() {
  local host="$1"
  local port="$2"
  local timeout_seconds="$3"
  local waited=0
  while (( waited < timeout_seconds )); do
    if (echo >"/dev/tcp/${host}/${port}") >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

stop_pid_if_running() {
  local pid="${1:-}"
  if [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1; then
    kill "${pid}" >/dev/null 2>&1 || true
    wait "${pid}" >/dev/null 2>&1 || true
  fi
}

cleanup_background_jobs() {
  stop_pid_if_running "${MODEL_PF_PID}"
  stop_pid_if_running "${PROM_PF_PID}"
}
trap cleanup_background_jobs EXIT

start_prometheus_port_forward() {
  local log_file="$1"
  if [[ "${AUTO_PORT_FORWARD_PROM}" != "1" ]]; then
    return 0
  fi
  if wait_for_tcp "127.0.0.1" "${PROM_LOCAL_PORT}" 1; then
    log "Prometheus local port ${PROM_LOCAL_PORT} already reachable; reusing existing endpoint."
    return 0
  fi
  log "Starting Prometheus port-forward: svc/${PROM_SERVICE} ${PROM_LOCAL_PORT}:${PROM_REMOTE_PORT} (ns=${PROM_NAMESPACE})"
  kubectl port-forward -n "${PROM_NAMESPACE}" "svc/${PROM_SERVICE}" "${PROM_LOCAL_PORT}:${PROM_REMOTE_PORT}" > "${log_file}" 2>&1 &
  PROM_PF_PID=$!
  if ! wait_for_tcp "127.0.0.1" "${PROM_LOCAL_PORT}" "${PORT_FORWARD_WAIT_SECONDS}"; then
    die "Prometheus port-forward did not become ready on localhost:${PROM_LOCAL_PORT}"
  fi
}

validate_prometheus_endpoint_or_die() {
  if [[ "${AUTO_PORT_FORWARD_PROM}" == "1" ]]; then
    return 0
  fi
  if ! wait_for_tcp "127.0.0.1" "${PROM_LOCAL_PORT}" 1; then
    die "Prometheus endpoint is not reachable on localhost:${PROM_LOCAL_PORT}. Start port-forward or set AUTO_PORT_FORWARD_PROM=1."
  fi
}

deploy_model_if_enabled() {
  local model="$1"
  if [[ "${AUTO_DEPLOY}" != "1" ]]; then
    return 0
  fi
  log "Auto-deploy enabled. Deploying model ${model} ..."
  bash "${REPO_ROOT}/scripts/deploy_model.sh" --model "${model}"
  log "Waiting for deployment/${WORKER_DEPLOYMENT_NAME} rollout ..."
  kubectl rollout status deployment "${WORKER_DEPLOYMENT_NAME}" -n "${NAMESPACE}" --timeout=900s
}

start_model_port_forward_if_enabled() {
  local log_file="$1"
  if [[ "${AUTO_PORT_FORWARD_MODEL}" != "1" ]]; then
    return 0
  fi
  stop_pid_if_running "${MODEL_PF_PID}"
  MODEL_PF_PID=""
  log "Starting model port-forward: svc/${WORKLOAD_SERVICE_NAME} ${LOCAL_PORT}:${REMOTE_PORT} (ns=${NAMESPACE})"
  kubectl port-forward -n "${NAMESPACE}" "svc/${WORKLOAD_SERVICE_NAME}" "${LOCAL_PORT}:${REMOTE_PORT}" > "${log_file}" 2>&1 &
  MODEL_PF_PID=$!
  if ! wait_for_tcp "127.0.0.1" "${LOCAL_PORT}" "${PORT_FORWARD_WAIT_SECONDS}"; then
    die "Model port-forward did not become ready on localhost:${LOCAL_PORT} for ${MODEL_KEY}"
  fi
}

validate_model_endpoint_or_die() {
  if [[ "${AUTO_PORT_FORWARD_MODEL}" == "1" ]]; then
    return 0
  fi
  if ! wait_for_tcp "127.0.0.1" "${LOCAL_PORT}" 1; then
    die "Model endpoint for ${MODEL_KEY} is not reachable on localhost:${LOCAL_PORT}. Start port-forward or set AUTO_PORT_FORWARD_MODEL=1."
  fi
}

delete_model_if_enabled() {
  if [[ "${AUTO_DELETE_MODEL}" != "1" ]]; then
    return 0
  fi
  log "Auto-delete enabled. Deleting LLMInferenceService ${LLMISVC_NAME} in namespace ${NAMESPACE} ..."
  kubectl delete llminferenceservice "${LLMISVC_NAME}" -n "${NAMESPACE}" --ignore-not-found
}

apply_monitoring_if_enabled() {
  local model="$1"
  if [[ "${AUTO_APPLY_MONITORING}" != "1" ]]; then
    return 0
  fi
  log "AUTO_APPLY_MONITORING=1 -> Applying monitoring resources for ${model} ..."
  bash "${REPO_ROOT}/scripts/apply_monitoring.sh" --model "${model}"
}

log "=================================================="
log "Full benchmark suite starting"
log "Suite root: ${suite_root}"
log "RESULTS_ROOT: ${RESULTS_ROOT}"
log "Models: ${MODEL_LIST}"
log "Policies: ${POLICY_LIST}"
log "Scenarios: ${SCENARIO_LIST}"
log "Repeats: ${REPEATS}"
log "AUTO_DEPLOY=${AUTO_DEPLOY} AUTO_DELETE_MODEL=${AUTO_DELETE_MODEL} AUTO_PORT_FORWARD_MODEL=${AUTO_PORT_FORWARD_MODEL} AUTO_PORT_FORWARD_PROM=${AUTO_PORT_FORWARD_PROM}"
log "AUTO_APPLY_MONITORING=${AUTO_APPLY_MONITORING}"
log "=================================================="

run_index=0
failed_runs=0

start_prometheus_port_forward "${suite_root}/prometheus_portforward.log"
validate_prometheus_endpoint_or_die

for model in ${MODEL_LIST}; do
  load_model_config "${model}"
  model_key_for_paths="${MODEL_KEY}"
  deploy_model_if_enabled "${model}"
  apply_monitoring_if_enabled "${model}"
  start_model_port_forward_if_enabled "${suite_root}/model_portforward_${model_key_for_paths}.log"
  validate_model_endpoint_or_die

  for policy in ${POLICY_LIST}; do
    for scenario in ${SCENARIO_LIST}; do
      for repeat in $(seq 1 "${REPEATS}"); do
        run_index=$((run_index + 1))
        run_log="${suite_root}/run_${run_index}_${model_key_for_paths}_${policy}_${scenario}_r${repeat}.log"
        before_list="${suite_root}/before_${run_index}.txt"
        after_list="${suite_root}/after_${run_index}.txt"

        find "${RESULTS_ROOT}/${model_key_for_paths}/${scenario}" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort > "${before_list}" || true

        log "Run ${run_index}: model=${model} policy=${policy} scenario=${scenario} repeat=${repeat}"

        set +e
        RESULTS_ROOT="${RESULTS_ROOT}" \
        PROM_URL="${PROM_URL}" \
        METRIC_INTERVAL="${METRIC_INTERVAL}" \
        POLICY_SETTLE_SECONDS="${POLICY_SETTLE_SECONDS}" \
        BENCH_TIMEOUT_SECONDS="${BENCH_TIMEOUT_SECONDS}" \
        DRAIN_TIMEOUT_SECONDS="${DRAIN_TIMEOUT_SECONDS}" \
        MAX_IN_FLIGHT="${MAX_IN_FLIGHT}" \
        bash "${REPO_ROOT}/scripts/benchmark/run_policy_eval.sh" \
          --model "${model}" \
          --policy "${policy}" \
          --scenario "${scenario}" > "${run_log}" 2>&1
        status=$?
        set -e

        find "${RESULTS_ROOT}/${model_key_for_paths}/${scenario}" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort > "${after_list}" || true
        run_dir="$(comm -13 "${before_list}" "${after_list}" | tail -n 1)"

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "${run_index}" "${model}" "${policy}" "${scenario}" "${repeat}" "${status}" "${run_dir}" "${run_log}" \
          >> "${summary_tsv}"

        if [[ "${status}" -ne 0 ]]; then
          failed_runs=$((failed_runs + 1))
          log "Run ${run_index} FAILED (exit=${status})"
          log "Recent log output for failed run:"
          tail -n 20 "${run_log}" | sed 's/^/[run-log] /'
          if [[ "${FAIL_FAST}" == "1" ]]; then
            die "Stopping early because FAIL_FAST=1"
          fi
        fi

        if [[ "${repeat}" -lt "${REPEATS}" ]]; then
          log "Cooling down for ${COOLDOWN_SECONDS}s..."
          sleep "${COOLDOWN_SECONDS}"
        fi
      done
    done
  done

  stop_pid_if_running "${MODEL_PF_PID}"
  MODEL_PF_PID=""
  delete_model_if_enabled
done

log "=================================================="
log "Suite complete. Total runs: ${run_index}, Failed runs: ${failed_runs}"
log "Summary: ${summary_tsv}"
log "Suite root: ${suite_root}"
log "=================================================="
