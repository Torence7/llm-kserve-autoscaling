#!/usr/bin/env bash
set -euo pipefail
NS="kserve-test"
kubectl delete inferenceservice sklearn-iris -n "${NS}" --ignore-not-found=true