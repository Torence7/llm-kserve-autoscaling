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

  [[ -n "$arg" ]] || die "Usage: load_model_config --model <name|path>"

  if [[ -f "$arg" ]]; then
    echo "$arg"
    return 0
  fi

  if [[ -f "${root}/configs/models/${arg}.yaml" ]]; then
    echo "${root}/configs/models/${arg}.yaml"
    return 0
  fi

  local f
  while IFS= read -r -d '' f; do
    local mk llm name
    mk="$(yq -r '.model_key // ""' "$f" 2>/dev/null || true)"
    llm="$(yq -r '.llmisvc_name // ""' "$f" 2>/dev/null || true)"
    name="$(basename "$f" .yaml)"
    if [[ "$arg" == "$mk" || "$arg" == "$llm" || "$arg" == "$name" ]]; then
      echo "$f"
      return 0
    fi
  done < <(find "${root}/configs/models" -maxdepth 1 -name '*.yaml' -print0)

  die "Could not resolve model config: $arg"
}

resolve_policy_file() {
  local policy_key="${1:-}"
  local root
  root="$(repo_root)"

  [[ -n "$policy_key" ]] || die "Policy key is empty"

  if [[ -f "$policy_key" ]]; then
    echo "$policy_key"
    return 0
  fi

  if [[ -f "${root}/configs/policies/${policy_key}.yaml" ]]; then
    echo "${root}/configs/policies/${policy_key}.yaml"
    return 0
  fi

  die "Could not resolve policy config: $policy_key"
}

yaml_get_or_default() {
  local expr="$1"
  local file="$2"
  local default_value="${3:-}"

  local value
  value="$(yq -r "${expr} // \"__NULL__\"" "$file" 2>/dev/null || true)"

  if [[ -z "$value" || "$value" == "__NULL__" || "$value" == "null" ]]; then
    echo "$default_value"
  else
    echo "$value"
  fi
}

load_policy_config() {
  local policy_key="${1:-}"
  [[ -n "$policy_key" ]] || die "load_policy_config requires a policy key"

  POLICY_FILE="$(resolve_policy_file "$policy_key")"
  POLICY_KEY="$(yaml_get_or_default '.policy_key' "$POLICY_FILE" "$policy_key")"
  POLICY_TYPE="$(yaml_get_or_default '.policy_type' "$POLICY_FILE" "keda-prometheus")"

  MIN_REPLICAS="$(yaml_get_or_default '.min_replicas' "$POLICY_FILE" "1")"
  MAX_REPLICAS="$(yaml_get_or_default '.max_replicas' "$POLICY_FILE" "5")"
  POLLING_INTERVAL="$(yaml_get_or_default '.polling_interval' "$POLICY_FILE" "15")"
  COOLDOWN_PERIOD="$(yaml_get_or_default '.cooldown_period' "$POLICY_FILE" "60")"

  CPU_TARGET_UTILIZATION="$(yaml_get_or_default '.cpu_target_utilization' "$POLICY_FILE" "50")"

  PROMETHEUS_SERVER_ADDRESS="$(yaml_get_or_default '.prometheus.server_address' "$POLICY_FILE" "http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090")"
  PROMETHEUS_METRIC_NAME="$(yaml_get_or_default '.prometheus.metric_name' "$POLICY_FILE" "")"
  PROMETHEUS_QUERY="$(yaml_get_or_default '.prometheus.query' "$POLICY_FILE" "")"
  THRESHOLD="$(yaml_get_or_default '.prometheus.threshold' "$POLICY_FILE" "")"
  ACTIVATION_THRESHOLD="$(yaml_get_or_default '.prometheus.activation_threshold' "$POLICY_FILE" "")"

  SCALING_MODIFIER_TARGET="$(yaml_get_or_default '.advanced.scaling_modifiers.target' "$POLICY_FILE" "")"
  SCALING_MODIFIER_ACTIVATION_TARGET="$(yaml_get_or_default '.advanced.scaling_modifiers.activation_target' "$POLICY_FILE" "")"
  SCALING_MODIFIER_FORMULA="$(yaml_get_or_default '.advanced.scaling_modifiers.formula' "$POLICY_FILE" "")"

  TRIGGERS_COUNT="$(yq -r '(.triggers // []) | length' "$POLICY_FILE" 2>/dev/null || echo "0")"
}

load_model_config() {
  need_model_tools

  MODEL_FILE="$(resolve_model_file "$1")"

  local default_name
  default_name="$(basename "$MODEL_FILE" .yaml)"

  MODEL_KEY="$(yaml_get_or_default '.model_key' "$MODEL_FILE" "$default_name")"
  NAMESPACE="$(yaml_get_or_default '.namespace' "$MODEL_FILE" "llm-demo")"
  LLMISVC_NAME="$(yaml_get_or_default '.llmisvc_name' "$MODEL_FILE" "$default_name")"

  HF_MODEL_ID="$(yaml_get_or_default '.hf_model_id' "$MODEL_FILE" "")"
  SERVED_MODEL_NAME="$(yaml_get_or_default '.served_model_name' "$MODEL_FILE" "$HF_MODEL_ID")"
  IMAGE="$(yaml_get_or_default '.image' "$MODEL_FILE" "")"
  REPLICAS="$(yaml_get_or_default '.replicas' "$MODEL_FILE" "1")"

  REMOTE_PORT="$(yaml_get_or_default '.ports.remote' "$MODEL_FILE" "8000")"
  LOCAL_PORT="$(yaml_get_or_default '.ports.local' "$MODEL_FILE" "8001")"

  REQUESTS_CPU="$(yaml_get_or_default '.resources.requests.cpu' "$MODEL_FILE" "500m")"
  REQUESTS_MEMORY="$(yaml_get_or_default '.resources.requests.memory' "$MODEL_FILE" "4Gi")"
  LIMITS_CPU="$(yaml_get_or_default '.resources.limits.cpu' "$MODEL_FILE" "2")"
  LIMITS_MEMORY="$(yaml_get_or_default '.resources.limits.memory' "$MODEL_FILE" "10Gi")"

  VLLM_LOGGING_LEVEL="$(yaml_get_or_default '.env.VLLM_LOGGING_LEVEL' "$MODEL_FILE" "INFO")"

  SMOKE_PROMPT="$(yaml_get_or_default '.smoke_test.prompt' "$MODEL_FILE" "Who are you?")"
  SMOKE_MAX_TOKENS="$(yaml_get_or_default '.smoke_test.max_tokens' "$MODEL_FILE" "40")"
  LOAD_PROMPT="$(yaml_get_or_default '.load_test.prompt' "$MODEL_FILE" "Write a short paragraph about systems.")"
  LOAD_MAX_TOKENS="$(yaml_get_or_default '.load_test.max_tokens' "$MODEL_FILE" "120")"

  BENCHMARK_PROMPT_TOKENS="$(yaml_get_or_default '.benchmark.prompt_tokens' "$MODEL_FILE" "128")"
  BENCHMARK_OUTPUT_TOKENS="$(yaml_get_or_default '.benchmark.output_tokens' "$MODEL_FILE" "128")"
  BENCHMARK_MAX_SECONDS="$(yaml_get_or_default '.benchmark.max_seconds' "$MODEL_FILE" "30")"

  WORKLOAD_SERVICE_NAME="$(yaml_get_or_default '.workload_service_name' "$MODEL_FILE" "${LLMISVC_NAME}-kserve-workload-svc")"
  WORKER_DEPLOYMENT_NAME="$(yaml_get_or_default '.worker_deployment_name' "$MODEL_FILE" "${LLMISVC_NAME}-kserve")"

  SCALING_POLICY_KEY="$(yaml_get_or_default '.scaling_policy' "$MODEL_FILE" "hpa-cpu-baseline")"
  load_policy_config "$SCALING_POLICY_KEY"

  KEDA_SCALEDOBJECT_NAME="$(yaml_get_or_default '.keda_scaledobject_name' "$MODEL_FILE" "$(sanitize_name "${MODEL_KEY}")-${POLICY_KEY}")"
  METRICS_SERVICE_NAME="$(yaml_get_or_default '.metrics_service_name' "$MODEL_FILE" "$(sanitize_name "${MODEL_KEY}")-vllm-metrics")"
  SERVICE_MONITOR_NAME="$(yaml_get_or_default '.service_monitor_name' "$MODEL_FILE" "$(sanitize_name "${MODEL_KEY}")-vllm-monitor")"

  [[ -n "$HF_MODEL_ID" ]] || die "hf_model_id missing in $MODEL_FILE"
  [[ -n "$SERVED_MODEL_NAME" ]] || die "served_model_name missing in $MODEL_FILE"
  [[ -n "$IMAGE" ]] || die "image missing in $MODEL_FILE"

  WORKLOAD_LABEL_NAME="$(yaml_get_or_default '.workload_label_name' "$MODEL_FILE" "$LLMISVC_NAME")"
  METRICS_PORT="$(yaml_get_or_default '.metrics_port' "$MODEL_FILE" "$REMOTE_PORT")"
  METRICS_PATH="$(yaml_get_or_default '.metrics_path' "$MODEL_FILE" "/metrics")"
  METRICS_SCRAPE_INTERVAL="$(yaml_get_or_default '.metrics_scrape_interval' "$MODEL_FILE" "15s")"
}