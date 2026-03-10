# OPT-125M on KServe (CloudLab baseline)

Reproducible baseline deployment of OPT-125M (vLLM CPU) on Kubernetes via KServe + LLMInferenceService.
Then establish a reactive autoscaling baseline (CPU HPA).

## CloudLab setup (Linux)
SSH into CloudLab node, then:

## CloudLab prerequisites (Ubuntu)

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
sudo usermod -aG docker $USER
newgrp docker
```

```bash
git clone git@github.com:<USERNAME>/llm-kserve-autoscaling.git
cd llm-kserve-autoscaling

bash scripts/00_bootstrap_tools.sh
bash scripts/01_create_kind_cluster.sh
bash scripts/02_install_metrics_server.sh
bash scripts/03_install_llmisvc_stack.sh
bash scripts/03b_install_llmisvc_stack.sh
bash scripts/04_apply_llm_presets.sh
bash scripts/05_deploy_llm_opt125m.sh

# If worker is stuck at 0/1 due to probe timing, run:
bash scripts/07_patch_worker_probes.sh

# Wait for pods:
bash scripts/06_wait_pods.sh

bash scripts/08_portforward_opt.sh

bash scripts/09_curl_opt.sh
```