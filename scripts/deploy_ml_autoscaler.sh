#!/usr/bin/env bash
set -euo pipefail
# Deploy the ML autoscaler controller as a Kubernetes Pod.
# Packages the trained model + controller code into a ConfigMap/Secret-mounted
# Pod that runs the controller loop inside the cluster.
#
# Usage:
#   bash scripts/deploy_ml_autoscaler.sh --model <model-key|path> [--policy <policy-key|path>]
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/model.sh"
MODEL_ARG=""
POLICY_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL_ARG="${2:-}"; shift 2 ;;
    --policy) POLICY_ARG="${2:-}"; shift 2 ;;
    -h|--help)
      echo "Usage: deploy_ml_autoscaler.sh --model <key|path> [--policy <key|path>]"
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
done
[[ -n "$MODEL_ARG" ]] || die "--model is required"
load_model_config "$MODEL_ARG"
if [[ -n "$POLICY_ARG" ]]; then
  load_policy_config "$POLICY_ARG"
fi
[[ "$POLICY_TYPE" == "ml" ]] || die "Policy type must be 'ml', got '${POLICY_TYPE}'"
REPO_ROOT="$(repo_root)"
ML_MODEL_PATH="${REPO_ROOT}/$(yaml_get_or_default '.ml.model_path' "$POLICY_FILE" "models/ml_autoscaler.joblib")"
[[ -f "$ML_MODEL_PATH" ]] || die "Trained model not found at ${ML_MODEL_PATH}. Run train_model.py first."
CONTROLLER_NAME="ml-autoscaler-${MODEL_KEY}"
CONTROLLER_NAME="$(sanitize_name "$CONTROLLER_NAME")"
log "Deleting any existing HPA or KEDA ScaledObject for ${WORKER_DEPLOYMENT_NAME}"
kubectl delete hpa -n "$NAMESPACE" "${WORKER_DEPLOYMENT_NAME}" --ignore-not-found >/dev/null 2>&1 || true
kubectl delete scaledobject -n "$NAMESPACE" -l "ml-autoscaler-target=${WORKER_DEPLOYMENT_NAME}" --ignore-not-found >/dev/null 2>&1 || true
log "Creating ConfigMap with ML model and controller code..."
kubectl create configmap "${CONTROLLER_NAME}-code" \
  -n "$NAMESPACE" \
  --from-file=controller.py="${REPO_ROOT}/scripts/ml_autoscaler/controller.py" \
  --from-file=features.py="${REPO_ROOT}/scripts/ml_autoscaler/features.py" \
  --from-file=__init__.py="${REPO_ROOT}/scripts/ml_autoscaler/__init__.py" \
  --dry-run=client -o yaml | kubectl apply -f -

MODEL_CONFIGMAP_NAME="${CONTROLLER_NAME}-model"
if kubectl get configmap "$MODEL_CONFIGMAP_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  kubectl create configmap "$MODEL_CONFIGMAP_NAME" \
    -n "$NAMESPACE" \
    --from-file=ml_autoscaler.joblib="$ML_MODEL_PATH" \
    --dry-run=client -o yaml | kubectl replace -f -
else
  kubectl create configmap "$MODEL_CONFIGMAP_NAME" \
    -n "$NAMESPACE" \
    --from-file=ml_autoscaler.joblib="$ML_MODEL_PATH"
fi
PROM_URL="$(yaml_get_or_default '.prometheus.server_address' "$POLICY_FILE" \
  "http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090")"
log "Deploying controller pod ${CONTROLLER_NAME}..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${CONTROLLER_NAME}
  namespace: ${NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${CONTROLLER_NAME}
  namespace: ${NAMESPACE}
rules:
  - apiGroups: ["apps"]
    resources: ["deployments/scale", "deployments"]
    verbs: ["get", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${CONTROLLER_NAME}
  namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${CONTROLLER_NAME}
subjects:
  - kind: ServiceAccount
    name: ${CONTROLLER_NAME}
    namespace: ${NAMESPACE}
---
apiVersion: v1
kind: Pod
metadata:
  name: ${CONTROLLER_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ml-autoscaler
    ml-autoscaler-target: ${WORKER_DEPLOYMENT_NAME}
spec:
  serviceAccountName: ${CONTROLLER_NAME}
  restartPolicy: Always
  containers:
    - name: controller
      image: python:3.11-slim
      command:
        - bash
        - -c
        - |
          apt-get update &&
          apt-get install --yes --no-install-recommends ca-certificates curl &&
          KUBECTL_VERSION="$(curl -L -s https://dl.k8s.io/release/stable.txt)" &&
          curl -L --fail --output /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" &&
          chmod +x /usr/local/bin/kubectl &&
          pip install --quiet scikit-learn joblib numpy requests &&
          python /app/controller.py \
            --model-path /model/ml_autoscaler.joblib \
            --prom-url "${PROM_URL}" \
            --deployment-name "${WORKER_DEPLOYMENT_NAME}" \
            --namespace "${NAMESPACE}" \
            --served-model-name "${SERVED_MODEL_NAME}" \
            --min-replicas ${MIN_REPLICAS} \
            --max-replicas ${MAX_REPLICAS} \
            --interval ${POLLING_INTERVAL} \
            --cooldown ${COOLDOWN_PERIOD}
      volumeMounts:
        - name: code
          mountPath: /app
        - name: model
          mountPath: /model
      resources:
        requests:
          cpu: "100m"
          memory: "256Mi"
        limits:
          cpu: "500m"
          memory: "512Mi"
  volumes:
    - name: code
      configMap:
        name: ${CONTROLLER_NAME}-code
    - name: model
      configMap:
        name: ${CONTROLLER_NAME}-model
EOF
log "Waiting for controller pod to start..."
kubectl wait pod "${CONTROLLER_NAME}" -n "$NAMESPACE" --for=condition=Ready --timeout=120s 2>/dev/null || {
  log "Pod not ready yet. Check with: kubectl logs -n ${NAMESPACE} ${CONTROLLER_NAME} -f"
}
log "ML autoscaler controller deployed: ${CONTROLLER_NAME}"
log "View logs: kubectl logs -n ${NAMESPACE} ${CONTROLLER_NAME} -f"
