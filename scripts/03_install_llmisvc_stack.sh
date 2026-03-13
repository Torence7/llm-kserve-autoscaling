#!/usr/bin/env bash
set -euo pipefail

curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
helm version

# Installs the infra + controllers needed for LLMInferenceService (LLMISvc)
# on a kind cluster. This follows the KServe hack/setup scripts (recommended).

KSERVE_SETUP_DIR="${KSERVE_SETUP_DIR:-$HOME/kserve/hack/setup}"

echo "[03] Installing LLMISvc stack using KServe hack/setup scripts"
echo "     Using: $KSERVE_SETUP_DIR"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl not found. Run scripts/00_bootstrap_tools.sh first."
  exit 1
fi

# Sanity: must be connected to a cluster
if ! kubectl get nodes >/dev/null 2>&1; then
  echo "ERROR: kubectl cannot reach a cluster. Create kind cluster first."
  exit 1
fi

# Ensure KServe repo is available (for hack/setup scripts)
if [[ ! -d "$KSERVE_SETUP_DIR/infra" ]]; then
  echo "[03] KServe setup scripts not found at $KSERVE_SETUP_DIR"
  echo "[03] Cloning kserve repo to \$HOME/kserve ..."
  cd "$HOME"
  git clone https://github.com/kserve/kserve.git
fi

cd "$KSERVE_SETUP_DIR"

echo "[03] Step A: cert-manager"
bash infra/manage.cert-manager-helm.sh --install

echo "[03] Step B: Gateway API CRDs"
bash infra/gateway-api/manage.gateway-api-crd.sh --install

echo "[03] Step C: Gateway API Inference Extension CRDs (GIE)"
bash infra/gateway-api/manage.gateway-api-extension-crd.sh --install

echo "[03] Step D: Envoy Gateway"
bash infra/manage.envoy-gateway-helm.sh --install

echo "[03] Step E: Envoy AI Gateway"
bash infra/manage.envoy-ai-gateway-helm.sh --install

echo "[03] Step F: LeaderWorkerSet (LWS) operator"
bash infra/manage.lws-operator.sh --install

echo "[03] Step G: GatewayClass + Gateway instance"
bash infra/gateway-api/manage.gateway-api-gwclass.sh --install
bash infra/gateway-api/manage.gateway-api-gw.sh --install
bash infra/gateway-api/manage.gateway-api-extension-crd.sh --install

echo "[03] Step H: Install LLMISvc components (controller + configs) via Helm script"
# IMPORTANT: use ENABLE_* vars (this is what the script expects)
env ENABLE_KSERVE=false ENABLE_LLMISVC=true bash infra/manage.kserve-helm.sh --install

echo "[03] Verifying CRDs + controllers..."
kubectl get crd llminferenceservices.serving.kserve.io >/dev/null
kubectl get crd llminferenceserviceconfigs.serving.kserve.io >/dev/null
kubectl get pods -n kserve | egrep 'kserve-controller-manager|llmisvc-controller-manager' || true

echo "[03] LLMISvc stack installed."