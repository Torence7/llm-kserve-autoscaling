#!/usr/bin/env bash
set -euo pipefail

echo "[03] Install KServe Standard"
curl -s "https://raw.githubusercontent.com/kserve/kserve/master/hack/setup/quick-install/kserve-standard-mode-full-install-with-manifests.sh" | bash
kubectl get pods -n kserve
