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
## Grafana Dashboard

1. Deploy the dashboard ConfigMap (only needed once, or after updates)
```bash
bash scripts/apply_grafana_dashboard.sh
```

2. On your **local machine**, open an SSH tunnel to the CloudLab node while port-forwarding Grafana:
```bash
ssh -L 3000:localhost:3000 <user>@<cloudlab-host> \
  "kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring"
```

3. Open in your browser:
```
http://localhost:3000
```

4. Log in with username `admin`. Retrieve the password from the cluster:
```bash
kubectl get secret prometheus-grafana -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 -d && echo
```

5. Navigate to **Dashboards → vLLM + KServe Autoscaling**

The dashboard defaults to the last 5 minutes and auto-refreshes every 10 seconds. Use the `Namespace` dropdown to select `llm-demo`.

## Adding another model

To support a new model:

create a new YAML file in configs/models/

fill in the model-specific values

run the same generic scripts with --model <new-model>


## Running policy-comparison benchmarks

This repo supports policy-based benchmarking for comparing autoscaling strategies under the same workload scenario.

A policy run does the following:
- applies the selected autoscaling policy
- runs the benchmark workload for the selected scenario
- collects client-side benchmark results
- samples Prometheus-backed system metrics during the run

### Prerequisites

Make sure these are already running:

- the model is deployed
- the model endpoint is port-forwarded locally
- Prometheus is installed
- Prometheus is port-forwarded locally
- the Python virtual environment is activated

Example:

```bash
source .venv/bin/activate
bash scripts/portforward_model.sh --model qwen25-0.5b-instruct
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
```

Keep both port-forwards running in separate terminals while the benchmark is executing.

### Run one policy evaluation

Example HPA CPU baseline run:

```bash
source .venv/bin/activate
PROM_URL="http://localhost:9090" \
bash scripts/benchmark/run_policy_eval.sh \
  --model qwen25-0.5b-instruct \
  --policy hpa-cpu-baseline \
  --scenario short-bursts
```

Example KEDA run:

```bash
source .venv/bin/activate
PROM_URL="http://localhost:9090" \
bash scripts/benchmark/run_policy_eval.sh \
  --model qwen25-0.5b-instruct \
  --policy keda-waiting-requests \
  --scenario short-bursts
```

### ShareGPT-style realistic dataset workflow

If you want realistic prompts from ShareGPT-style traces:

1. Prepare benchmark JSONL prompts (`{"prompt":"..."}`) from a ShareGPT JSON/JSONL export:

```bash
python scripts/benchmark/prepare_sharegpt_dataset.py \
  --input /path/to/sharegpt.json \
  --output configs/data/sharegpt_prompts_5k.jsonl \
  --max-samples 5000 \
  --min-prompt-tokens 16 \
  --max-prompt-tokens 256
```

2. Run policy eval with the provided scenario:

```bash
PROM_URL="http://localhost:9090" \
MAX_IN_FLIGHT=4 \
DRAIN_TIMEOUT_SECONDS=300 \
BENCH_TIMEOUT_SECONDS=30 \
bash scripts/benchmark/run_policy_eval.sh \
  --model qwen25-0.5b-instruct \
  --policy hpa-cpu-baseline \
  --scenario conversation-sharegpt
```

Notebook version of this workflow:

```bash
jupyter notebook notebooks/benchmark_workflow.ipynb
```

### Compare multiple policies on the same scenario

Run the same scenario with different policies to compare behavior under identical load:

```bash
source .venv/bin/activate

PROM_URL="http://localhost:9090" \
bash scripts/benchmark/run_policy_eval.sh \
  --model qwen25-0.5b-instruct \
  --policy hpa-cpu-baseline \
  --scenario short-bursts

PROM_URL="http://localhost:9090" \
bash scripts/benchmark/run_policy_eval.sh \
  --model qwen25-0.5b-instruct \
  --policy keda-waiting-requests \
  --scenario short-bursts
```

### Outputs

Each run writes a timestamped results directory containing benchmark outputs and sampled system metrics.

Typical artifacts include:
- a benchmark summary
- per-request logs
- sampled system metrics such as running requests, waiting requests, throughput, KV-cache usage, and ready replicas

### Notes

- `PROM_URL` should point to the local Prometheus port-forward used during the run.
- use the same model and scenario across policies for fair comparisons
- make sure the selected policy is successfully applied before starting the benchmark
- keep Prometheus and model port-forwards active in separate terminals during the run
