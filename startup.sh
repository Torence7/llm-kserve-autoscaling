#!/usr/bin/env bash
# CloudLab startup script
# Installs prerequisites, grants docker + kubeconfig access to all real users,
# then runs the full cloudlab_setup.sh (with KEDA + Prometheus).


set -euo pipefail

REPO_DIR="/local/repository"
LOG_FILE="/var/tmp/kserve-setup.log"

log() { printf '[%s] %s\n' "$(date +'%H:%M:%S')" "$*"; }

log "Updating apt and installing base dependencies..."
apt-get update -y
apt-get install -y docker.io git curl python3.12-venv

log "Enabling docker service..."
systemctl enable --now docker

# Docker group access for all users

log "Granting docker group membership to real users..."
while IFS=: read -r username _ uid _ _ homedir shell; do
    [[ "$uid" -lt 1000 ]] && continue
    [[ "$shell" =~ nologin|false ]] && continue
    usermod -aG docker "$username" || true
    log "  Added $username to docker group"
done < /etc/passwd

# Run the setup script
# Export REPO_DIR so cloudlab_setup.sh skips the git-clone step and uses the
# copy that CloudLab already placed at /local/repository.

log "Starting cloudlab_setup.sh (KEDA + Prometheus enabled)..."
REPO_DIR="$REPO_DIR" bash "$REPO_DIR/scripts/cloudlab_setup.sh" \
    --install-keda \
    --install-prometheus

# Distribute kubeconfig to all users

if [[ -f /users/geniuser/.kube/config ]]; then
    echo "Distributing kubeconfig to real users..."
    while IFS=: read -r username _ uid _ _ homedir shell; do
        [[ "$uid" -lt 1000 ]] && continue
        [[ "$shell" =~ nologin|false ]] && continue
        [[ -z "$homedir" ]] && continue
        [[ "$username" = "geniuser" ]] && continue
        mkdir -p "$homedir/.kube"
        cp /users/geniuser/.kube/config "$homedir/.kube/config"
        chown -R "$username" "$homedir/.kube"
        chmod 600 "$homedir/.kube/config"
        echo "  Copied kubeconfig to $username ($homedir/.kube/config)"
    done < /etc/passwd
else
    log "WARNING: /users/geniuser/.kube/config not found — kubeconfig not distributed."
fi

log "CloudLab startup complete."
log "Monitor pods: kubectl get pods -A"
log "Check setup log: tail -f $LOG_FILE"
