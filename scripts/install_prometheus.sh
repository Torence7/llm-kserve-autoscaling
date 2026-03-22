#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

PROM_NAMESPACE="monitoring"
RELEASE_NAME="prometheus"
CHART_NAME="prometheus-community/kube-prometheus-stack"

need_cmd kubectl
need_cmd helm

log "Adding Prometheus Helm repo"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update

log "Installing/upgrading kube-prometheus-stack in namespace ${PROM_NAMESPACE}"
helm upgrade --install "${RELEASE_NAME}" "${CHART_NAME}" \
  --namespace "${PROM_NAMESPACE}" \
  --create-namespace \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false

log "Waiting for Grafana rollout"
kubectl rollout status deployment/prometheus-grafana -n "${PROM_NAMESPACE}" --timeout=180s

log "Waiting for Prometheus rollout"
kubectl rollout status statefulset/prometheus-prometheus-kube-prometheus-prometheus -n "${PROM_NAMESPACE}" --timeout=180s

log "Prometheus stack is ready"
kubectl get pods -n "${PROM_NAMESPACE}"