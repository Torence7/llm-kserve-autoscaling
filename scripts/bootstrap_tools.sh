#!/usr/bin/env bash
set -euo pipefail

echo "[00] Install Docker + kubectl + kind + helm (Linux)"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "Run this on CloudLab Linux."
  exit 1
fi

sudo apt-get update
sudo apt-get install -y docker.io curl ca-certificates gnupg

sudo usermod -aG docker "$USER" || true
newgrp docker <<'EONG'
docker ps >/dev/null
EONG

# kubectl (v1.30 stable)
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubectl

# kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

# helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

echo "[00] Versions:"
kubectl version --client
kind version
helm version

# yq
if ! command -v yq >/dev/null 2>&1; then
  echo "[00] Installing yq"
  sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
  sudo chmod +x /usr/local/bin/yq
fi