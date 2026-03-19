#!/usr/bin/env bash
set -euo pipefail

echo "metrics-server"

kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

kubectl patch deployment metrics-server -n kube-system --type='json' -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"},
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-preferred-address-types=InternalIP,Hostname,InternalDNS,ExternalDNS,ExternalIP"}
]'

kubectl rollout status deployment/metrics-server -n kube-system --timeout=180s

echo "Waiting for Metrics API to become available..."

for i in {1..18}; do
  if kubectl top nodes >/dev/null 2>&1; then
    echo "Metrics API is available"
    kubectl top nodes
    exit 0
  fi

  echo "Metrics API not ready yet (attempt $i/18), waiting 10s..."
  sleep 10
done

echo "ERROR: Metrics API did not become available in time"
echo "Debug info:"
kubectl get pods -n kube-system | grep metrics-server || true
kubectl get apiservice v1beta1.metrics.k8s.io || true
kubectl describe apiservice v1beta1.metrics.k8s.io || true
kubectl logs -n kube-system deployment/metrics-server || true
exit 1