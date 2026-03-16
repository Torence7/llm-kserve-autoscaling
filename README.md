# OPT-125M on KServe (CloudLab)

Reproducible baseline deployment of OPT-125M (vLLM CPU) on Kubernetes via KServe + LLMInferenceService.
Then establish a reactive autoscaling baseline (CPU HPA).

SSH into CloudLab node, then:
```bash
git clone git@github.com:<USERNAME>/llm-kserve-autoscaling.git
cd llm-kserve-autoscaling
```

## CloudLab setup (all at once)
SSH into CloudLab node, then:

```bash
bash scripts/cloudlab_setup.sh
```

#### CloudLab setup (script by script)

After SSH’ing into your CloudLab node, check if Docker/Git are installed:

```bash
docker --version || true
git --version || true
```

If Docker is missing, install it:
```bash
sudo apt-get update
sudo apt-get install -y docker.io git curl
sudo systemctl enable --now docker

# Allow non-root docker
sudo usermod -aG docker $USER

# IMPORTANT: refresh your session so group membership takes effect
exit   # then SSH back in

# Verify
groups
docker ps
docker run hello-world
```

```bash
bash scripts/00_bootstrap_tools.sh
bash scripts/01_create_kind_cluster.sh
bash scripts/02_install_metrics_server.sh
bash scripts/03_install_llmisvc_stack.sh
bash scripts/03b_verify_llmisvc.sh
bash scripts/04_apply_llm_presets.sh
bash scripts/05_deploy_llm_opt125m.sh

# If worker is stuck at 0/1 due to probe timing, run:
bash scripts/07_patch_worker_probes.sh

# Wait for pods:
bash scripts/06_wait_pods.sh
```

Run with test  input:
```bash
bash scripts/08_portforward_opt.sh

bash scripts/09_curl_opt.sh
```

Autoscaling HPA Baseline
```bash
bash scripts/10_create_hpa_baseline.sh
bash scripts/11_load_test.sh
```

KEDA Setup
```bash
bash  scripts/12_install_keda.sh
bash scripts/13_apply_keda_scaledobject.sh
bash scripts/14_verify_keda.sh
bash scripts/15_watch_keda_scaling.sh
```

Install GuideLLM
```bash
bash scripts/benchmark/install_guidellm.sh
```

Benchmark option A: Sweep
This runs multiple stages and increases load each stage to find saturation.
```bash
bash scripts/benchmark/guidellm_sweep.sh
```

Benchmark option B: Constant rate
This holds a fixed request rate for a fixed duration.
```bash
bash scripts/benchmark/guidellm_sweep.sh
```