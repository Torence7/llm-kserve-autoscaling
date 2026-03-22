#!/usr/bin/env bash
set -euo pipefail
CLUSTER_NAME="${CLUSTER_NAME:-kserve}"

echo "[01] kind create cluster ${CLUSTER_NAME}"
kind create cluster --name "${CLUSTER_NAME}" --image kindest/node:v1.33.0 || true
kubectl cluster-info --context "kind-${CLUSTER_NAME}"
kubectl get nodes
