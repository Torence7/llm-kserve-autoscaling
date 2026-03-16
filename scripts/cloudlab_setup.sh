#!/usr/bin/env bash
set -euo pipefail

# One-shot CloudLab setup for running this repo's scripts (no GitHub clone).
#
# Assumes the repo folder already exists on the VM (e.g., uploaded via scp).
#
# Usage:
#   bash cloudlab_setup_all.sh
#
# Optional env vars:
#   REPO_DIR="$HOME/llm-kserve-autoscaling"

REPO_DIR="${REPO_DIR:-$HOME/llm-kserve-autoscaling}"

log() { echo -e "\n[cloudlab_setup] $*\n"; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_apt_pkgs() {
  local pkgs=("$@")
  sudo apt-get update -y
  sudo apt-get install -y "${pkgs[@]}"
}

ensure_docker() {
  if need_cmd docker; then
    log "Docker already installed: $(docker --version || true)"
  else
    log "Docker not found. Installing docker.io..."
    ensure_apt_pkgs docker.io
  fi

  log "Enabling + starting Docker..."
  sudo systemctl enable --now docker

  if ! getent group docker >/dev/null 2>&1; then
    log "Creating docker group..."
    sudo groupadd docker
  fi

  if id -nG "$USER" | grep -qw docker; then
    log "User '$USER' is already in docker group."
  else
    log "Adding '$USER' to docker group..."
    sudo usermod -aG docker "$USER"
  fi
}

have_docker_access() {
  docker ps >/dev/null 2>&1
}

run_pipeline() {
  if [[ ! -d "$REPO_DIR" ]]; then
    echo "ERROR: Repo dir not found: $REPO_DIR"
    echo "Upload it first (scp/zip/etc), or set REPO_DIR to the correct path."
    exit 1
  fi

  cd "$REPO_DIR"

  log "Running project scripts from: $REPO_DIR"

  bash scripts/00_bootstrap_tools.sh
  bash scripts/01_create_kind_cluster.sh
  bash scripts/02_install_metrics_server.sh
  bash scripts/03_install_llmisvc_stack.sh
  bash scripts/03b_verify_llmisvc.sh
  bash scripts/04_apply_llm_presets.sh
  bash scripts/05_deploy_llm_opt125m.sh

  log "Done. Quick sanity checks:"
  kubectl get pods -n kserve || true
  kubectl get llminferenceservice -n llm-demo || true

  cat <<'EOF'

Next:
  # Terminal 1 (keep running):
  bash scripts/08_portforward_opt.sh

  # Terminal 2 (send a request):
  bash scripts/09_curl_opt.sh

Autoscaling baseline:
  bash scripts/10_create_hpa_baseline.sh
  bash scripts/11_load_test.sh

EOF
}

main() {
  log "Step 1/2: Install prerequisites (docker/git/curl) + enable docker"
  ensure_docker

  # git + curl are commonly needed by your scripts even if you already uploaded repo
  if ! need_cmd git || ! need_cmd curl; then
    log "Installing git + curl..."
    ensure_apt_pkgs git curl
  fi

  log "Step 2/2: Ensure we can talk to Docker without sudo, then run the pipeline"

  if have_docker_access; then
    log "Docker access OK in this shell."
    run_pipeline
    exit 0
  fi

  log "Docker access still denied in this shell. Re-running under docker group using 'sg docker'..."
  log "If THIS fails, you must log out + SSH back in once."

  sg docker -c "
    set -euo pipefail
    echo '[cloudlab_setup/sg] Groups:' \$(id -nG)
    docker ps >/dev/null 2>&1 || (echo '[cloudlab_setup/sg] Still no docker access. Log out + SSH back in.' && exit 1)
    REPO_DIR='$REPO_DIR' bash -lc '
      set -euo pipefail
      cd \"\$REPO_DIR\"
      bash scripts/00_bootstrap_tools.sh
      bash scripts/01_create_kind_cluster.sh
      bash scripts/02_install_metrics_server.sh
      bash scripts/03_install_llmisvc_stack.sh
      bash scripts/03b_verify_llmisvc.sh
      bash scripts/04_apply_llm_presets.sh
      bash scripts/05_deploy_llm_opt125m.sh
      echo
      echo \"[cloudlab_setup/sg] Setup complete.\"
    '
  "

  log "All done."
}

main "$@"