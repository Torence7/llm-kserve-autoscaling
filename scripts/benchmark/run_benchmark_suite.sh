 #!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

MODEL_KEY="${MODEL_KEY:?Set MODEL_KEY, e.g. MODEL_KEY=qwen25-0.5b-instruct}"
POLICY_LIST="${POLICY_LIST:-hpa-cpu-baseline keda-token-aware keda-token-cache-composite keda-waiting-requests}"
SCENARIO_LIST="${SCENARIO_LIST:-conversation-realistic conversation long-context short-bursts sustained-mixed}"
REPEATS="${REPEATS:-1}"

AUTO_DEPLOY="${AUTO_DEPLOY:-1}"
AUTO_DELETE_MODEL="${AUTO_DELETE_MODEL:-1}"
AUTO_PORT_FORWARD_MODEL="${AUTO_PORT_FORWARD_MODEL:-1}"
AUTO_PORT_FORWARD_PROM="${AUTO_PORT_FORWARD_PROM:-0}"
AUTO_APPLY_MONITORING="${AUTO_APPLY_MONITORING:-1}"
ALLOW_PROM_MISSING="${ALLOW_PROM_MISSING:-0}"

RESULTS_ROOT="${RESULTS_ROOT:-${REPO_ROOT}/results/policy_eval}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
METRIC_INTERVAL="${METRIC_INTERVAL:-5}"
POLICY_SETTLE_SECONDS="${POLICY_SETTLE_SECONDS:-20}"
BENCH_TIMEOUT_SECONDS="${BENCH_TIMEOUT_SECONDS:-15}"
DRAIN_TIMEOUT_SECONDS="${DRAIN_TIMEOUT_SECONDS:-5}"
MAX_IN_FLIGHT="${MAX_IN_FLIGHT:-1}"
PORT_FORWARD_WAIT_SECONDS="${PORT_FORWARD_WAIT_SECONDS:-30}"
MODEL_READY_TIMEOUT_SECONDS="${MODEL_READY_TIMEOUT_SECONDS:-180}"
ROLLOUT_TIMEOUT_SECONDS="${ROLLOUT_TIMEOUT_SECONDS:-300}"

NAMESPACE=""
LLMISVC_NAME=""
MODEL_LOCAL_PORT=""
MODEL_REMOTE_PORT=""
WORKLOAD_SERVICE_NAME=""
WORKER_DEPLOYMENT_NAME=""
MODEL_PF_PID=""
PROM_PF_PID=""
PROM_AVAILABLE=1

echo "=========================================="
echo "Model benchmark suite starting"
echo "Model: ${MODEL_KEY}"
echo "Policies: ${POLICY_LIST}"
echo "Scenarios: ${SCENARIO_LIST}"
echo "Repeats: ${REPEATS}"
echo "AUTO_DEPLOY=${AUTO_DEPLOY}"
echo "AUTO_DELETE_MODEL=${AUTO_DELETE_MODEL}"
echo "AUTO_PORT_FORWARD_MODEL=${AUTO_PORT_FORWARD_MODEL}"
echo "AUTO_PORT_FORWARD_PROM=${AUTO_PORT_FORWARD_PROM}"
echo "AUTO_APPLY_MONITORING=${AUTO_APPLY_MONITORING}"
echo "ALLOW_PROM_MISSING=${ALLOW_PROM_MISSING}"
echo "PROM_URL=${PROM_URL}"
echo "=========================================="

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}

need_cmd bash
need_cmd kubectl
need_cmd python3
need_cmd curl

load_model_fields() {
  local output
  output="$(
    MODEL_KEY="${MODEL_KEY}" python3 - <<'PY'
import os
import yaml

path = os.path.join("configs", "models", os.environ["MODEL_KEY"] + ".yaml")
with open(path, "r") as f:
    cfg = yaml.safe_load(f)

namespace = cfg["namespace"]
llmisvc_name = cfg["llmisvc_name"]
local_port = cfg["ports"]["local"]
remote_port = cfg["ports"]["remote"]

print(namespace)
print(llmisvc_name)
print(local_port)
print(remote_port)
PY
  )"

  NAMESPACE="$(echo "${output}" | sed -n '1p')"
  LLMISVC_NAME="$(echo "${output}" | sed -n '2p')"
  MODEL_LOCAL_PORT="$(echo "${output}" | sed -n '3p')"
  MODEL_REMOTE_PORT="$(echo "${output}" | sed -n '4p')"

  WORKLOAD_SERVICE_NAME="${LLMISVC_NAME}-kserve-workload-svc"
  WORKER_DEPLOYMENT_NAME="${LLMISVC_NAME}-kserve"
}

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

cleanup() {
  stop_pid_if_running "${MODEL_PF_PID}"
  stop_pid_if_running "${PROM_PF_PID}"

  if [[ "${AUTO_DELETE_MODEL}" == "1" && -n "${LLMISVC_NAME}" && -n "${NAMESPACE}" ]]; then
    kubectl delete llminferenceservice "${LLMISVC_NAME}" -n "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

wait_for_model_rollout_if_possible() {
  if kubectl get deployment "${WORKER_DEPLOYMENT_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    echo "Waiting for rollout of deployment/${WORKER_DEPLOYMENT_NAME} ..."
    kubectl rollout status deployment "${WORKER_DEPLOYMENT_NAME}" -n "${NAMESPACE}" --timeout="${ROLLOUT_TIMEOUT_SECONDS}s" || true
  else
    echo "Deployment ${WORKER_DEPLOYMENT_NAME} not found yet; continuing to endpoint readiness checks"
  fi
}

start_model_port_forward_if_needed() {
  if [[ "${AUTO_PORT_FORWARD_MODEL}" != "1" ]]; then
    return 0
  fi

  stop_pid_if_running "${MODEL_PF_PID}"
  MODEL_PF_PID=""

  echo "Starting model port-forward svc/${WORKLOAD_SERVICE_NAME} ${MODEL_LOCAL_PORT}:${MODEL_REMOTE_PORT} in ns ${NAMESPACE}"
  kubectl port-forward -n "${NAMESPACE}" "svc/${WORKLOAD_SERVICE_NAME}" "${MODEL_LOCAL_PORT}:${MODEL_REMOTE_PORT}" >"/tmp/${MODEL_KEY}_pf.log" 2>&1 &
  MODEL_PF_PID=$!

  if ! wait_for_tcp "127.0.0.1" "${MODEL_LOCAL_PORT}" "${PORT_FORWARD_WAIT_SECONDS}"; then
    echo "ERROR: model port-forward did not become ready on localhost:${MODEL_LOCAL_PORT}" >&2
    [[ -f "/tmp/${MODEL_KEY}_pf.log" ]] && tail -n 50 "/tmp/${MODEL_KEY}_pf.log" >&2
    kubectl get svc -n "${NAMESPACE}" >&2 || true
    kubectl get pods -n "${NAMESPACE}" >&2 || true
    exit 1
  fi
}

start_prom_port_forward_if_needed() {
  if [[ "${AUTO_PORT_FORWARD_PROM}" != "1" ]]; then
    return 0
  fi

  stop_pid_if_running "${PROM_PF_PID}"
  PROM_PF_PID=""

  echo "Starting Prometheus port-forward on localhost:9090"
  kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090 >"/tmp/prom_pf.log" 2>&1 &
  PROM_PF_PID=$!

  if ! wait_for_tcp "127.0.0.1" "9090" "${PORT_FORWARD_WAIT_SECONDS}"; then
    if [[ "${ALLOW_PROM_MISSING}" == "1" ]]; then
      echo "WARNING: Prometheus port-forward did not come up; continuing without metrics"
      PROM_AVAILABLE=0
      return 0
    fi
    echo "ERROR: Prometheus port-forward did not become ready on localhost:9090" >&2
    [[ -f "/tmp/prom_pf.log" ]] && tail -n 50 "/tmp/prom_pf.log" >&2
    exit 1
  fi
}

validate_model_endpoint() {
  local waited=0

  while (( waited < MODEL_READY_TIMEOUT_SECONDS )); do
    if curl -fsS "http://localhost:${MODEL_LOCAL_PORT}/v1/models" >/dev/null 2>&1; then
      echo "Model endpoint is ready at http://localhost:${MODEL_LOCAL_PORT}/v1/models"
      return 0
    fi

    if (( waited % 10 == 0 )); then
      echo "Waiting for model endpoint on localhost:${MODEL_LOCAL_PORT} ..."
      kubectl get pods -n "${NAMESPACE}" || true
    fi

    sleep 2
    waited=$((waited + 2))
  done

  echo "ERROR: model endpoint is not responding at http://localhost:${MODEL_LOCAL_PORT}/v1/models after ${MODEL_READY_TIMEOUT_SECONDS}s" >&2
  [[ -f "/tmp/${MODEL_KEY}_pf.log" ]] && tail -n 50 "/tmp/${MODEL_KEY}_pf.log" >&2
  kubectl get svc -n "${NAMESPACE}" >&2 || true
  kubectl get pods -n "${NAMESPACE}" >&2 || true
  kubectl describe deployment "${WORKER_DEPLOYMENT_NAME}" -n "${NAMESPACE}" >&2 || true
  exit 1
}

validate_prometheus_if_needed() {
  if [[ "${PROM_AVAILABLE}" != "1" ]]; then
    return 0
  fi

  if ! curl -fsS "${PROM_URL}/api/v1/query?query=up" >/dev/null 2>&1; then
    if [[ "${ALLOW_PROM_MISSING}" == "1" ]]; then
      echo "WARNING: Prometheus not reachable at ${PROM_URL}; continuing without metrics"
      PROM_AVAILABLE=0
      return 0
    fi
    echo "ERROR: Prometheus not reachable at ${PROM_URL}" >&2
    exit 1
  fi
}

load_model_fields

if [[ "${AUTO_DEPLOY}" == "1" ]]; then
  bash "${REPO_ROOT}/scripts/deploy_model.sh" --model "${MODEL_KEY}"
  wait_for_model_rollout_if_possible
fi

if [[ "${AUTO_APPLY_MONITORING}" == "1" ]]; then
  bash "${REPO_ROOT}/scripts/apply_monitoring.sh" --model "${MODEL_KEY}"
fi

start_model_port_forward_if_needed
validate_model_endpoint

start_prom_port_forward_if_needed
validate_prometheus_if_needed

for policy in ${POLICY_LIST}; do
  for scenario in ${SCENARIO_LIST}; do
    for repeat in $(seq 1 "${REPEATS}"); do
      echo "Running model=${MODEL_KEY} policy=${policy} scenario=${scenario} repeat=${repeat}"

      RESULTS_ROOT="${RESULTS_ROOT}" \
      PROM_URL="${PROM_URL}" \
      METRIC_INTERVAL="${METRIC_INTERVAL}" \
      POLICY_SETTLE_SECONDS="${POLICY_SETTLE_SECONDS}" \
      BENCH_TIMEOUT_SECONDS="${BENCH_TIMEOUT_SECONDS}" \
      DRAIN_TIMEOUT_SECONDS="${DRAIN_TIMEOUT_SECONDS}" \
      MAX_IN_FLIGHT="${MAX_IN_FLIGHT}" \
      SKIP_METRICS="$([[ "${PROM_AVAILABLE}" == "1" ]] && echo 0 || echo 1)" \
      bash "${REPO_ROOT}/scripts/benchmark/run_policy_eval.sh" \
        --model "${MODEL_KEY}" \
        --policy "${policy}" \
        --scenario "${scenario}"
    done
  done
done

echo "Done with model ${MODEL_KEY}"