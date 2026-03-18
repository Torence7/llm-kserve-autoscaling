#!/usr/bin/env bash
set -euo pipefail

echo "[04] Apply LLM presets (version-pinned)"

# Detect installed controller tag (e.g., v0.16.0, v0.17.0-rc0)
IMG=$(kubectl -n kserve get deploy llmisvc-controller-manager \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)

if [[ -z "$IMG" ]]; then
  echo "ERROR: llmisvc-controller-manager not found in namespace kserve."
  exit 1
fi

TAG="${IMG##*:}"
echo "Detected llmisvc controller image: $IMG"
echo "Using KServe tag: $TAG"

BASE="https://raw.githubusercontent.com/kserve/kserve/${TAG}/config/llmisvcconfig"

# These are the preset configs you were applying
FILES=(
  "config-llm-template.yaml"
  "config-llm-router-route.yaml"
  "config-llm-scheduler.yaml"
  "config-llm-worker-data-parallel.yaml"
  "config-llm-prefill-template.yaml"
  "config-llm-prefill-worker-data-parallel.yaml"
  "config-llm-decode-template.yaml"
  "config-llm-decode-worker-data-parallel.yaml"
)

for f in "${FILES[@]}"; do
  echo "[04] Applying ${f} from ${TAG}"
  kubectl apply -f "${BASE}/${f}"
done

kubectl get llminferenceserviceconfig -n kserve
echo "Done."