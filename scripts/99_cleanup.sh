#!/usr/bin/env bash
set -euo pipefail
kubectl delete namespace llm-demo --ignore-not-found
kubectl delete namespace kserve-test --ignore-not-found
