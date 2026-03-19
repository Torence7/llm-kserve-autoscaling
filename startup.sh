#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="/local/repository"
SCRIPTS_DIR="$REPO_DIR/scripts"

log() { echo -e "\n[cloudlab_setup] $*\n"; }
need_cmd() { command -v "$1" >/dev/null 2>&1; }

# ── Prerequisites ─────────────────────────────────────────────────────────────

if ! need_cmd docker; then
  log "Installing docker..."
  apt-get update -y
  apt-get install -y docker.io
fi

systemctl enable --now docker

# Give all logged-in users docker access 
for user in $(getent passwd | awk -F: '$3 >= 1000 && $7 !~ /nologin|false/ {print $1}'); do
  usermod -aG docker "$user" || true
done

if ! need_cmd git || ! need_cmd curl; then
  apt-get update -y
  apt-get install -y git curl
fi

# ── Run scripts ───────────────────────────────────────────────────────────────

cd "$REPO_DIR"
chmod +x "$SCRIPTS_DIR"/*.sh
log "Running scripts from: $SCRIPTS_DIR"

for script in $(ls "$SCRIPTS_DIR"/[0-9][0-9]*.sh | sort); do
  log "Running $script"
  bash "$script"
done

# ── Sanity check ──────────────────────────────────────────────────────────────

log "Done."
kubectl get pods -n kserve || true
kubectl get llminferenceservice -n llm-demo || true
