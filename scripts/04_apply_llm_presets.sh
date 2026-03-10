#!/usr/bin/env bash
set -euo pipefail

echo "[04] Apply LLM presets"
for f in \
  config-llm-template.yaml \
  config-llm-router-route.yaml \
  config-llm-scheduler.yaml \
  config-llm-worker-data-parallel.yaml \
  config-llm-prefill-template.yaml \
  config-llm-prefill-worker-data-parallel.yaml \
  config-llm-decode-template.yaml \
  config-llm-decode-worker-data-parallel.yaml
do
  kubectl apply -n kserve -f "https://raw.githubusercontent.com/kserve/kserve/master/config/llmisvcconfig/${f}"
done
kubectl get llminferenceserviceconfig -n kserve | head -n 20
