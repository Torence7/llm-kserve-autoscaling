# OPT-125M on KServe (CloudLab baseline)

Reproducible baseline deployment of OPT-125M (vLLM CPU) on Kubernetes via KServe + LLMInferenceService.
Then establish a reactive autoscaling baseline (CPU HPA).

## CloudLab setup (Linux)
SSH into CloudLab node, then:

```bash
git clone git@github.com:<GH_USERNAME>/llm-kserve-autoscaling.git
cd llm-kserve-autoscaling

bash scripts/00_bootstrap_tools.sh
bash scripts/01_create_kind_cluster.sh
bash scripts/02_install_metrics_server.sh
bash scripts/03_install_kserve_standard.sh
bash scripts/04_apply_llm_presets.sh
bash scripts/05_deploy_llm_opt125m.sh

# If worker is stuck at 0/1 due to probe timing, run:
bash scripts/07_patch_worker_probes.sh

# Wait for pods:
bash scripts/06_wait_pods.sh