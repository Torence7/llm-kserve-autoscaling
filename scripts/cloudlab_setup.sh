#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/Torence7/llm-kserve-autoscaling.git"
REPO_DIR="${REPO_DIR:-${HOME}/llm-kserve-autoscaling}"
REPO_BRANCH="main"

if [[ ! -d "$REPO_DIR/.git" ]]; then
  echo "Cloning repo into $REPO_DIR"
  git clone --branch "$REPO_BRANCH" "$REPO_URL" "$REPO_DIR"
else
  echo "Repo already exists at $REPO_DIR"
  cd "$REPO_DIR"
  git fetch origin
  git checkout "$REPO_BRANCH"
  git pull origin "$REPO_BRANCH"
fi

cd "$REPO_DIR"
echo "Now on branch: $(git branch --show-current)"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

MODEL="qwen25-0.5b-instruct"
SKIP_DEPLOY="0"
SKIP_BENCHMARK_SETUP="0"
RUN_KEDA_INSTALL="0"
RUN_PROM_STACK="0"

usage() {
  cat <<USAGE
Usage:
  bash scripts/cloudlab_setup.sh [--model <key|path>] [--skip-deploy] [--skip-benchmark-setup] [--install-keda] [--install-prometheus]

Options:
  --model <key|path>        Model key under configs/models/ or a direct YAML path.
  --skip-deploy             Stop after cluster/stack setup without deploying a model.
  --skip-benchmark-setup    Skip GuideLLM virtualenv setup.
  --install-keda            Install KEDA during setup.
  --install-prometheus      Install kube-prometheus-stack during setup.
  -h, --help                Show this help message.
USAGE
}

log() {
  printf '[%s] %s\n' "$(date +'%H:%M:%S')" "$*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

have_script() {
  [[ -f "${REPO_ROOT}/scripts/$1" ]]
}

run_script() {
  local script="$1"
  shift || true
  have_script "$script" || die "Missing script: scripts/$script"
  log "Running scripts/$script $*"
  bash "${REPO_ROOT}/scripts/$script" "$@"
}

ensure_docker_ready() {
  if ! command -v docker >/dev/null 2>&1; then
    die "Docker is not installed or not on PATH. Check scripts/bootstrap_tools.sh."
  fi

  # Start docker if it exists but is not running
  if command -v systemctl >/dev/null 2>&1; then
    if ! sudo systemctl is-active --quiet docker; then
      log "Docker service is not active. Starting docker..."
      sudo systemctl start docker || true
    fi
    sudo systemctl enable docker >/dev/null 2>&1 || true
  fi

  # First check if current shell already has access
  if docker ps >/dev/null 2>&1; then
    log "Docker is installed and accessible."
    return 0
  fi

  # Try to add user to docker group if needed
  if ! id -nG "$USER" | grep -qw docker; then
    log "Adding $USER to docker group..."
    sudo usermod -aG docker "$USER" || true
  fi

  # Re-check current shell
  if docker ps >/dev/null 2>&1; then
    log "Docker is now accessible."
    return 0
  fi

  cat <<EOF
Docker is installed, but the current shell cannot access the Docker daemon.

This usually means the docker group membership has not been applied to the current session yet.

Run:
  newgrp docker

Then verify:
  docker ps

After that, rerun:
  bash scripts/cloudlab_setup.sh --model ${MODEL}
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      MODEL="${2:-}"
      shift 2
      ;;
    --skip-deploy)
      SKIP_DEPLOY="1"
      shift
      ;;
    --skip-benchmark-setup)
      SKIP_BENCHMARK_SETUP="1"
      shift
      ;;
    --install-keda)
      RUN_KEDA_INSTALL="1"
      shift
      ;;
    --install-prometheus)
      RUN_PROM_STACK="1"
      shift
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

cd "$REPO_ROOT"

log "Repo root: $REPO_ROOT"
log "Selected model: $MODEL"

if have_script "bootstrap_tools.sh"; then
  run_script "bootstrap_tools.sh"
else
  log "Skipping bootstrap_tools.sh (not present)"
fi

ensure_docker_ready

run_script "create_kind_cluster.sh"
run_script "install_metrics_server.sh"
run_script "install_llmisvc_stack.sh"

if have_script "verify_llmisvc.sh"; then
  run_script "verify_llmisvc.sh"
else
  log "Skipping verify_llmisvc.sh (not present)"
fi

if have_script "apply_llm_presets.sh"; then
  run_script "apply_llm_presets.sh"
else
  log "Skipping apply_llm_presets.sh (not present)"
fi

if [[ "$RUN_KEDA_INSTALL" == "1" ]]; then
  run_script "install_keda.sh"
  if have_script "verify_keda.sh"; then
    run_script "verify_keda.sh"
  fi
fi

if [[ "$RUN_PROM_STACK" == "1" ]]; then
  log "Installing kube-prometheus-stack"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
  helm repo update
  helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --create-namespace \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false
fi

if [[ "$SKIP_DEPLOY" == "1" ]]; then
  cat <<SKIPMSG

Setup finished without deployment.

Next steps:
  bash scripts/deploy_model.sh --model ${MODEL}
  bash scripts/wait_pods.sh
  bash scripts/portforward_model.sh --model ${MODEL}
  bash scripts/smoke_test.sh --model ${MODEL}
SKIPMSG
  exit 0
fi

run_script "deploy_model.sh" --model "$MODEL"

if have_script "wait_pods.sh"; then
  run_script "wait_pods.sh"
else
  log "Skipping wait_pods.sh (not present)"
fi

if [[ "$SKIP_BENCHMARK_SETUP" != "1" ]] && have_script "benchmark/install_guidellm.sh"; then
  run_script "benchmark/install_guidellm.sh"
fi

cat <<DONE

CloudLab setup complete.

Suggested next steps:

  # Terminal 1: keep port-forward running
  bash scripts/portforward_model.sh --model ${MODEL}

  # Terminal 2: smoke test the deployed model
  bash scripts/smoke_test.sh --model ${MODEL}

  # HPA baseline
  bash scripts/create_hpa.sh --model ${MODEL}
  bash scripts/load_test.sh --model ${MODEL}
  kubectl get hpa -n llm-demo -w

  # KEDA (if installed)
  bash scripts/apply_keda_scaledobject.sh --model ${MODEL}
  bash scripts/watch_keda_scaling.sh

  # GuideLLM
  bash scripts/benchmark/guidellm_constant_rate.sh --model ${MODEL}
  bash scripts/benchmark/guidellm_sweep.sh --model ${MODEL}

If pods are not becoming ready, inspect them with:
  kubectl get pods -n llm-demo
  kubectl describe pod -n llm-demo <pod-name>
  kubectl logs -n llm-demo <pod-name>

DONE
