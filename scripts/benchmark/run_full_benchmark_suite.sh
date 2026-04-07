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

[[ -n "${MODEL_LIST}" ]] || die "MODEL_LIST is empty"
[[ -n "${POLICY_LIST}" ]] || die "POLICY_LIST is empty"
[[ -n "${SCENARIO_LIST}" ]] || die "SCENARIO_LIST is empty"

suite_ts="$(date +%Y%m%d_%H%M%S)"
suite_root="${SUITE_RESULTS_ROOT}/suite_${suite_ts}"
mkdir -p "${suite_root}"

summary_tsv="${suite_root}/summary.tsv"
printf 'run_index\tmodel\tpolicy\tscenario\trepeat\texit_code\trun_dir\tlog_file\n' > "${summary_tsv}"

log "=================================================="
log "Full benchmark suite starting"
log "Suite root: ${suite_root}"
log "RESULTS_ROOT: ${RESULTS_ROOT}"
log "Models: ${MODEL_LIST}"
log "Policies: ${POLICY_LIST}"
log "Scenarios: ${SCENARIO_LIST}"
log "Repeats: ${REPEATS}"
log "=================================================="

run_index=0
failed_runs=0

for model in ${MODEL_LIST}; do
  load_model_config "${model}"
  model_key_for_paths="${MODEL_KEY}"

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
done

log "=================================================="
log "Suite complete. Total runs: ${run_index}, Failed runs: ${failed_runs}"
log "Summary: ${summary_tsv}"
log "Suite root: ${suite_root}"
log "=================================================="

