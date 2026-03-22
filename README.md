# LLM KServe Autoscaling

Config-driven deployment and autoscaling experiments for LLM serving on Kubernetes using **KServe**, **LLMInferenceService**, **vLLM**, **HPA**, and **KEDA**.

This repo is set up so that:
- **model-specific details live in `configs/models/`**
- **scripts are generic and take `--model <key|path>`**
- **the same workflow can be reused across different models**
- **deployment, smoke testing, load generation, and scaling are all driven from one model config**

The initial example model is **OPT-125M on vLLM CPU**, but the goal of the repo is to support multiple models without rewriting scripts.


# # Quick start

### Cloudlab Profile Setup

1. Create a cluster with this [profile](https://www.cloudlab.us/p/f6217a554802140fb4fda7ef718f6ce14f62830c). You must be apart of the Michigan-BigData project to have access. This will automatically install a KIND cluster with KServe installed.

OR

### Repository Clone Setup

1. Clone the repo
```bash
git clone git@github.com:<YOUR-USERNAME>/llm-kserve-autoscaling.git
cd llm-kserve-autoscaling
```
2. Run the all-in-one CloudLab bootstrap
```bash
bash scripts/cloudlab_setup.sh
```

This sets up the cluster and serving stack. After that, you can use the generic scripts below.

##  Manual setup, step by step

If you want to run everything manually instead of using the one-shot setup script, use this flow.

1. Bootstrap local tools
```bash
bash scripts/bootstrap_tools.sh
```
2. Create the kind cluster
```bash
bash scripts/create_kind_cluster.sh
```
3. Install metrics server
```bash
bash scripts/install_metrics_server.sh
```
4. Install the KServe / LLMInferenceService stack
```bash
bash scripts/install_llmisvc_stack.sh
```
5. Verify the stack
```bash
bash scripts/verify_llmisvc.sh
```
6. Apply any required LLM presets
```bash
bash scripts/apply_llm_presets.sh
```
7. Deploy a model with a model key
```bash
bash scripts/deploy_model.sh --model facebook-opt-125m
```
8. Wait for pods to become ready
```bash
bash scripts/wait_pods.sh
```

If a worker gets stuck due to probe timing, you can patch probes if needed:
```bash
bash scripts/patch_worker_probes.sh
```

## Port-forwarding

To send local requests to the deployed model:
```bash
bash scripts/portforward_model.sh --model facebook-opt-125m
```
This port-forwards the selected model’s workload service to the local port specified in the model config.

Keep this running in its own terminal.

## Quick Tests
### Smoke testing

In another terminal, run:
```bash
bash scripts/smoke_test.sh --model facebook-opt-125m
```

### Load generation

To continuously send requests and create load:
```bash
bash scripts/load_test.sh --model facebook-opt-125m
```

## KEDA autoscaling
1. Install KEDA
```bash
bash scripts/install_keda.sh
```
2. Apply the ScaledObject for the selected model
```bash
bash scripts/apply_keda_scaledobject.sh --model facebook-opt-125m
```
3. Verify KEDA resources
```bash
bash scripts/verify_keda.sh
```
4. Watch scaling live
```bash
bash scripts/watch_keda_scaling.sh
```

## Benchmarking with GuideLLM
1. Install GuideLLM into the repo virtual environment
```bash
bash scripts/benchmark/install_guidellm.sh
```
2. Run a sweep benchmark

This increases pressure across stages to find saturation:
```bash
bash scripts/benchmark/guidellm_sweep.sh --model facebook-opt-125m
```
3. Run a constant-rate benchmark
```bash
bash scripts/benchmark/guidellm_constant_rate.sh --model facebook-opt-125m
```
You can override values as needed:
```bash
RATE=2 \
MAX_SECONDS=90 \
bash scripts/benchmark/guidellm_constant_rate.sh --model facebook-opt-125m
```

Benchmark defaults such as prompt tokens, output tokens, and duration are read from the model config.

## Monitoring with Prometheus
1. Install prometheus
```bash
bash scripts/install_prometheus.sh
```
2. Apply monitoring manifests for a specific model
```bash
bash scripts/apply_monitoring.sh --model qwen25-0.5b-instruct
```
3. Check whether the model exposes vLLM metrics
```bash
VLLM_POD=$(kubectl get pod -n llm-demo -l app.kubernetes.io/name=qwen25-0-5b-instruct -o jsonpath='{.items[0].metadata.name}')
echo "$VLLM_POD"

#Then inspect the metrics endpoint:
kubectl exec -n llm-demo "$VLLM_POD" -- wget -qO- http://localhost:8000/metrics | head -20
kubectl exec -n llm-demo "$VLLM_POD" -- wget -qO- http://localhost:8000/metrics | grep "^vllm"
```
4. Check whether Prometheus sees the metrics
```bash
kubectl describe svc qwen25-0-5b-instruct-vllm-metrics -n llm-demo | grep -E 'Endpoints|Selector'
```
If you want to query Prometheus directly, first find the Prometheus pod:
```bash
PROM_POD=$(kubectl get pod -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}')
echo "$PROM_POD"
```

Then query:
```bash
kubectl exec -n monitoring "$PROM_POD" -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=vllm:num_requests_running' | python3 -m json.tool
```
## Adding another model

To support a new model:

create a new YAML file in configs/models/

fill in the model-specific values

run the same generic scripts with --model <new-model>





