#!/usr/bin/env bash

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

need_model_tools() {
  need_cmd kubectl
  need_cmd yq
}

resolve_model_file() {
  local arg="${1:-}"
  local root
  root="$(repo_root)"

  [[ -n "$arg" ]] || die "Usage: --model <key|path>"

  if [[ -f "$arg" ]]; then
    echo "$arg"
    return 0
  fi

  if [[ -f "${root}/configs/models/${arg}.yaml" ]]; then
    echo "${root}/configs/models/${arg}.yaml"
    return 0
  fi

  die "Could not resolve model config: $arg"
}

# usage: load_model_config <key-or-path>
load_model_config() {
  need_model_tools

  MODEL_FILE="$(resolve_model_file "$1")"

  local default_name
  default_name="$(basename "$MODEL_FILE" .yaml)"

  MODEL_KEY="$(yq -r '.model_key // "'"${default_name}"'"' "$MODEL_FILE")"
  NAMESPACE="$(yq -r '.namespace // .metadata.namespace // "llm-demo"' "$MODEL_FILE")"

  LLMISVC_NAME="$(yq -r '.llmisvc_name // .metadata.name // "'"${default_name}"'"' "$MODEL_FILE")"
  HF_MODEL_ID="$(yq -r '.hf_model_id // (.spec.model.uri | sub("^hf://"; "")) // ""' "$MODEL_FILE")"
  SERVED_MODEL_NAME="$(yq -r '.served_model_name // .spec.model.name // .hf_model_id // ""' "$MODEL_FILE")"

  IMAGE="$(yq -r '.image // .spec.template.containers[0].image // ""' "$MODEL_FILE")"
  REPLICAS="$(yq -r '.replicas // .spec.model.replicas // 1' "$MODEL_FILE")"

  REMOTE_PORT="$(yq -r '.ports.remote // 8000' "$MODEL_FILE")"
  LOCAL_PORT="$(yq -r '.ports.local // 8001' "$MODEL_FILE")"

  REQUESTS_CPU="$(yq -r '.resources.requests.cpu // .spec.template.containers[0].resources.requests.cpu // "500m"' "$MODEL_FILE")"
  REQUESTS_MEMORY="$(yq -r '.resources.requests.memory // .spec.template.containers[0].resources.requests.memory // "4Gi"' "$MODEL_FILE")"
  LIMITS_CPU="$(yq -r '.resources.limits.cpu // .spec.template.containers[0].resources.limits.cpu // "2"' "$MODEL_FILE")"
  LIMITS_MEMORY="$(yq -r '.resources.limits.memory // .spec.template.containers[0].resources.limits.memory // "10Gi"' "$MODEL_FILE")"

  VLLM_LOGGING_LEVEL="$(yq -r '.env.VLLM_LOGGING_LEVEL // .spec.template.containers[0].env[]? | select(.name == "VLLM_LOGGING_LEVEL") | .value // "INFO"' "$MODEL_FILE" | tail -n 1)"
  [[ -n "$VLLM_LOGGING_LEVEL" && "$VLLM_LOGGING_LEVEL" != "null" ]] || VLLM_LOGGING_LEVEL="INFO"

  SMOKE_PROMPT="$(yq -r '.smoke_test.prompt // "Who are you?"' "$MODEL_FILE")"
  SMOKE_MAX_TOKENS="$(yq -r '.smoke_test.max_tokens // 40' "$MODEL_FILE")"

  LOAD_PROMPT="$(yq -r '.load_test.prompt // "Write a short paragraph about systems."' "$MODEL_FILE")"
  LOAD_MAX_TOKENS="$(yq -r '.load_test.max_tokens // 120' "$MODEL_FILE")"

  MIN_REPLICAS="$(yq -r '.scaling.min_replicas // 1' "$MODEL_FILE")"
  MAX_REPLICAS="$(yq -r '.scaling.max_replicas // 5' "$MODEL_FILE")"
  CPU_TARGET_UTILIZATION="$(yq -r '.scaling.cpu_target_utilization // 50' "$MODEL_FILE")"
  POLLING_INTERVAL="$(yq -r '.scaling.polling_interval // 15' "$MODEL_FILE")"
  COOLDOWN_PERIOD="$(yq -r '.scaling.cooldown_period // 60' "$MODEL_FILE")"

  BENCHMARK_PROMPT_TOKENS="$(yq -r '.benchmark.prompt_tokens // 128' "$MODEL_FILE")"
  BENCHMARK_OUTPUT_TOKENS="$(yq -r '.benchmark.output_tokens // 128' "$MODEL_FILE")"
  BENCHMARK_MAX_SECONDS="$(yq -r '.benchmark.max_seconds // 30' "$MODEL_FILE")"

  WORKLOAD_SERVICE_NAME="$(yq -r '.workload_service_name // ""' "$MODEL_FILE")"
  [[ -n "$WORKLOAD_SERVICE_NAME" && "$WORKLOAD_SERVICE_NAME" != "null" ]] || WORKLOAD_SERVICE_NAME="${LLMISVC_NAME}-kserve-workload-svc"

  WORKER_DEPLOYMENT_NAME="$(yq -r '.worker_deployment_name // ""' "$MODEL_FILE")"
  [[ -n "$WORKER_DEPLOYMENT_NAME" && "$WORKER_DEPLOYMENT_NAME" != "null" ]] || WORKER_DEPLOYMENT_NAME="${LLMISVC_NAME}-kserve"

  KEDA_SCALEDOBJECT_NAME="$(yq -r '.keda_scaledobject_name // ""' "$MODEL_FILE")"
  [[ -n "$KEDA_SCALEDOBJECT_NAME" && "$KEDA_SCALEDOBJECT_NAME" != "null" ]] || KEDA_SCALEDOBJECT_NAME="$(sanitize_name "${MODEL_KEY}")-cpu"

  METRICS_SERVICE_NAME="$(yq -r '.metrics_service_name // ""' "$MODEL_FILE")"
  [[ -n "$METRICS_SERVICE_NAME" && "$METRICS_SERVICE_NAME" != "null" ]] || METRICS_SERVICE_NAME="$(sanitize_name "${MODEL_KEY}")-vllm-metrics"

  SERVICE_MONITOR_NAME="$(yq -r '.service_monitor_name // ""' "$MODEL_FILE")"
  [[ -n "$SERVICE_MONITOR_NAME" && "$SERVICE_MONITOR_NAME" != "null" ]] || SERVICE_MONITOR_NAME="$(sanitize_name "${MODEL_KEY}")-vllm-monitor"

  [[ -n "$HF_MODEL_ID" && "$HF_MODEL_ID" != "null" ]] || die "hf_model_id/spec.model.uri missing in $MODEL_FILE"
  [[ -n "$SERVED_MODEL_NAME" && "$SERVED_MODEL_NAME" != "null" ]] || die "served_model_name/spec.model.name missing in $MODEL_FILE"
  [[ -n "$IMAGE" && "$IMAGE" != "null" ]] || die "image/spec.template.containers[0].image missing in $MODEL_FILE"
}