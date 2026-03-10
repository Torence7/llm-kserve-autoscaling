#!/usr/bin/env bash
set -euo pipefail

echo "[04] Apply LLM presets (LLMInferenceServiceConfig objects)"

# Guardrails: presets require the CRD to exist
if ! kubectl get crd llminferenceserviceconfigs.serving.kserve.io >/dev/null 2>&1; then
  echo "ERROR: CRD llminferenceserviceconfigs.serving.kserve.io not found."
  echo "Run: bash scripts/03_install_llmisvc_stack.sh"
  exit 1
fi

# Apply presets from KServe repo (versioned by whatever 'master' is at time;
# if you want strict reproducibility, pin to a tag later.)
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
  echo "[04] Applying $f"
  kubectl apply -n kserve -f "https://raw.githubusercontent.com/kserve/kserve/master/config/llmisvcconfig/${f}"
done

echo "[04] Done. Current LLMInferenceServiceConfig objects in kserve:"
kubectl get llminferenceserviceconfig -n kserve | head -n 30