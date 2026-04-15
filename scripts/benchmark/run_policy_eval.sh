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
  bash scripts/benchmark/run_policy_eval.sh --model <key|path> --policy <key|path> --scenario <name>

Examples:
  bash scripts/benchmark/run_policy_eval.sh --model qwen25-0.5b-instruct --policy hpa-cpu-baseline --scenario short-bursts
  bash scripts/benchmark/run_policy_eval.sh --model configs/models/qwen25-0.5b-instruct.yaml --policy configs/policies/hpa-cpu-baseline.yaml --scenario conversation-realistic

Optional environment variables:
  RESULTS_ROOT="results/policy_eval"
  PROM_URL="http://localhost:9090"
  METRIC_INTERVAL=5
  POLICY_SETTLE_SECONDS=20
  BENCH_TIMEOUT_SECONDS=15
  DRAIN_TIMEOUT_SECONDS=5
  MAX_IN_FLIGHT=1
  START_REPLICAS=1
EOF
}

MODEL_ARG=""
POLICY_ARG=""
SCENARIO_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      MODEL_ARG="${2:-}"
      shift 2
      ;;
    --policy)
      POLICY_ARG="${2:-}"
      shift 2
      ;;
    --scenario)
      SCENARIO_NAME="${2:-}"
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

[[ -n "${MODEL_ARG}" ]] || die "--model is required"
[[ -n "${POLICY_ARG}" ]] || die "--policy is required"
[[ -n "${SCENARIO_NAME}" ]] || die "--scenario is required"

need_model_tools
need_cmd python

load_model_config "${MODEL_ARG}"
load_policy_config "${POLICY_ARG}"

RESULTS_ROOT="${RESULTS_ROOT:-${REPO_ROOT}/results/policy_eval}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
METRIC_INTERVAL="${METRIC_INTERVAL:-5}"
POLICY_SETTLE_SECONDS="${POLICY_SETTLE_SECONDS:-20}"
BENCH_TIMEOUT_SECONDS="${BENCH_TIMEOUT_SECONDS:-15}"
DRAIN_TIMEOUT_SECONDS="${DRAIN_TIMEOUT_SECONDS:-5}"
MAX_IN_FLIGHT="${MAX_IN_FLIGHT:-1}"
START_REPLICAS="${START_REPLICAS:-${MIN_REPLICAS}}"

TARGET="${TARGET:-http://localhost:${LOCAL_PORT}/v1}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-${WORKER_DEPLOYMENT_NAME}}"
SCENARIO_PATH="${REPO_ROOT}/configs/scenarios/${SCENARIO_NAME}.yaml"

[[ -f "${SCENARIO_PATH}" ]] || die "Scenario file not found: ${SCENARIO_PATH}"

timestamp="$(date +%Y%m%d_%H%M%S)"
run_dir="${RESULTS_ROOT}/${MODEL_KEY}/${SCENARIO_NAME}/${POLICY_KEY}_${timestamp}"
mkdir -p "${run_dir}"

duration_seconds="$(python - <<PY
import yaml

with open("${SCENARIO_PATH}", "r", encoding="utf-8") as f:
    cfg = yaml.safe_load(f)

if not isinstance(cfg, dict):
    raise SystemExit("Scenario YAML must parse to a mapping/object")

if "duration_seconds" in cfg and cfg["duration_seconds"] is not None:
    print(int(cfg["duration_seconds"]))
elif "phases" in cfg and cfg["phases"] is not None:
    phases = cfg["phases"]
    if not isinstance(phases, list) or not phases:
        raise SystemExit("Scenario phases must be a non-empty list")
    total = 0
    for i, phase in enumerate(phases, start=1):
        if not isinstance(phase, dict):
            raise SystemExit(f"Phase {i} must be a mapping/object")
        if "duration_seconds" not in phase:
            raise SystemExit(f"Phase {i} missing duration_seconds")
        total += int(phase["duration_seconds"])
    print(total)
else:
    raise SystemExit("Scenario must define either top-level duration_seconds or phases[].duration_seconds")
PY
)"
metric_duration_seconds=$(( duration_seconds + DRAIN_TIMEOUT_SECONDS + 5 ))

log "Model file: ${MODEL_FILE}"
log "Model key: ${MODEL_KEY}"
log "Policy file: ${POLICY_FILE}"
log "Policy key: ${POLICY_KEY}"
log "Policy type: ${POLICY_TYPE}"
log "Scenario: ${SCENARIO_NAME}"
log "Scenario path: ${SCENARIO_PATH}"
log "Scenario duration (derived): ${duration_seconds}s"
log "Deployment name: ${DEPLOYMENT_NAME}"
log "Served model name: ${SERVED_MODEL_NAME}"
log "Namespace: ${NAMESPACE}"
log "Target endpoint: ${TARGET}"
log "Results dir: ${run_dir}"

log "Resetting deployment replicas to START_REPLICAS=${START_REPLICAS} before applying policy..."
kubectl scale deploy "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" --replicas="${START_REPLICAS}"
kubectl rollout status deploy "${DEPLOYMENT_NAME}" -n "${NAMESPACE}" --timeout=180s
sleep 5

log "Applying policy ${POLICY_KEY} ..."
case "${POLICY_TYPE}" in
  hpa|hpa-cpu)
    bash "${REPO_ROOT}/scripts/create_hpa.sh" \
      --model "${MODEL_FILE}" \
      --policy "${POLICY_FILE}"
    kubectl get hpa -n "${NAMESPACE}" || true
    ;;
  keda|keda-prometheus|keda-composite)
    bash "${REPO_ROOT}/scripts/apply_keda_scaledobject.sh" \
      --model "${MODEL_FILE}" \
      --policy "${POLICY_FILE}"
    kubectl get scaledobject -n "${NAMESPACE}" || true
    ;;
  ml)
    bash "${REPO_ROOT}/scripts/deploy_ml_autoscaler.sh" \
      --model "${MODEL_FILE}" \
      --policy "${POLICY_FILE}"
    kubectl get pod -n "${NAMESPACE}" -l app=ml-autoscaler || true
    ;;
  *)
    die "Unsupported policy_type for policy eval: ${POLICY_TYPE}"
    ;;
esac

echo "Waiting for deployment to be fully ready..."
kubectl rollout status deployment/qwen25-0-5b-instruct-kserve -n llm-demo --timeout=600s

kubectl wait pod -n llm-demo \
  -l app.kubernetes.io/name=qwen25-0-5b-instruct,kserve.io/component=workload \
  --for=condition=Ready \
  --timeout=600s

echo "Waiting for vLLM endpoint to respond..."
for i in $(seq 1 60); do
  if curl -sf http://localhost:8002/v1/models > /dev/null 2>&1; then
    echo "Endpoint ready after ~$((i*10))s."
    break
  fi
  echo "  [$i/60] Not ready yet, retrying in 10s..."
  sleep 10
done

log "Starting Prometheus metric collection..."
python -u "${REPO_ROOT}/scripts/metrics/collect_metrics.py" \
  --prom-url "${PROM_URL}" \
  --duration-seconds "${metric_duration_seconds}" \
  --interval-seconds "${METRIC_INTERVAL}" \
  --deployment-name "${DEPLOYMENT_NAME}" \
  --model-name "${SERVED_MODEL_NAME}" \
  --namespace "${NAMESPACE}" \
  --outcsv "${run_dir}/system_metrics.csv" &
METRICS_PID=$!

log "Running benchmark traffic..."
python -u "${REPO_ROOT}/scripts/benchmark/run_benchmark.py" \
  --target "${TARGET}" \
  --model-name "${SERVED_MODEL_NAME}" \
  --scenario "${SCENARIO_PATH}" \
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
  "scenario": "${SCENARIO_NAME}",
  "scenario_path": "${SCENARIO_PATH}",
  "scenario_duration_seconds": ${duration_seconds},
  "policy_file": "${POLICY_FILE}",
  "policy_key": "${POLICY_KEY}",
  "policy_type": "${POLICY_TYPE}",
  "target": "${TARGET}",
  "prom_url": "${PROM_URL}",
  "metric_interval_seconds": ${METRIC_INTERVAL},
  "policy_settle_seconds": ${POLICY_SETTLE_SECONDS},
  "benchmark_timeout_seconds": ${BENCH_TIMEOUT_SECONDS},
  "drain_timeout_seconds": ${DRAIN_TIMEOUT_SECONDS},
  "max_in_flight": ${MAX_IN_FLIGHT},
  "start_replicas": ${START_REPLICAS}
}
EOF

log "Policy evaluation complete."
log "Results saved under: ${run_dir}"