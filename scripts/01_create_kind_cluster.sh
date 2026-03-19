#!/usr/bin/env bash
set -euo pipefail
CLUSTER_NAME="${CLUSTER_NAME:-kserve}"

echo "[01] kind create cluster ${CLUSTER_NAME}"
kind create cluster --name "${CLUSTER_NAME}" || true
kubectl cluster-info --context "kind-${CLUSTER_NAME}"
kubectl get nodes

# Copy kubeconfig to all real users
for user in $(getent passwd | awk -F: '$3 >= 1000 && $7 !~ /nologin|false/ {print $1}'); do
  home=$(eval echo ~$user)
  mkdir -p "$home/.kube"
  cp /users/geniuser/.kube/config "$home/.kube/config" 2>/dev/null || \
    cp /root/.kube/config "$home/.kube/config" 2>/dev/null || true
  chown -R "$user" "$home/.kube" || true
  echo "Copied kubeconfig to $user"
done
