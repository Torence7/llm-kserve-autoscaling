#!/usr/bin/env bash
set -euo pipefail

echo "[02] metrics-server"
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system patch deployment metrics-server \
  --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' || true
kubectl rollout status -n kube-system deployment/metrics-server
kubectl top nodes
