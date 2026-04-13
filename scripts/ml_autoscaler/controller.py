#!/usr/bin/env python3
"""Lightweight ML autoscaler controller.

Runs as a long-lived process (inside a Pod or locally).  Every --interval
seconds it:
  1. Queries Prometheus for the same 5 metrics collected during benchmarks
  2. Engineers features with features.py
  3. Runs inference on the trained GBT model
  4. Patches the target Deployment replica count via kubectl

Environment / flags mirror the conventions used by the rest of the repo.

Usage (local, with port-forwards active):
    python scripts/ml_autoscaler/controller.py \
        --model-path models/ml_autoscaler.joblib \
        --prom-url http://localhost:9090 \
        --deployment-name qwen25-0-5b-instruct-kserve \
        --namespace llm-demo \
        --served-model-name "Qwen/Qwen2.5-0.5B-Instruct" \
        --min-replicas 1 --max-replicas 5 \
        --interval 10 \
        [--dry-run]
"""
import argparse
import json
import subprocess
import sys
import time
from typing import Dict, List, Optional
import os
sys.path.insert(0, os.path.dirname(__file__))
from features import compute_features, raw_row_to_dict, safe_float
import requests as http_requests

READY_REPLICAS_TEMPLATE = (
    'kube_deployment_status_replicas_ready{{deployment="{deployment}", namespace="{namespace}"}}'
)

def prom_query(prom_url: str, query: str, timeout_s: float = 10.0) -> Optional[float]:
    url = prom_url.rstrip("/") + "/api/v1/query"
    try:
        resp = http_requests.get(url, params={"query": query}, timeout=timeout_s)
        resp.raise_for_status()
        results = resp.json().get("data", {}).get("result", [])
        if not results:
            return None
        return float(results[0]["value"][1])
    except Exception as e:
        print(f"[WARN] Prometheus query failed: {e}", flush=True)
        return None

def prom_query_first(prom_url: str, queries: List[str]) -> Optional[float]:
    for q in queries:
        val = prom_query(prom_url, q)
        if val is not None:
            return val
    return None

def fetch_metrics(prom_url: str, namespace: str, model_name: str, deployment: str) -> Dict[str, float]:
    running = prom_query_first(prom_url, [
        f'sum(vllm:num_requests_running{{namespace="{namespace}",model_name="{model_name}"}})',
        f'sum(vllm:num_requests_running{{namespace="{namespace}"}})',
        "sum(vllm:num_requests_running)",
    ])
    waiting = prom_query_first(prom_url, [
        f'sum(vllm:num_requests_waiting{{namespace="{namespace}",model_name="{model_name}"}})',
        f'sum(vllm:num_requests_waiting{{namespace="{namespace}"}})',
        "sum(vllm:num_requests_waiting)",
    ])
    throughput = prom_query_first(prom_url, [
        f'sum(rate(vllm:generation_tokens_total{{namespace="{namespace}",model_name="{model_name}"}}[1m]))',
        f'sum(rate(vllm:generation_tokens_total{{namespace="{namespace}"}}[1m]))',
        "sum(rate(vllm:generation_tokens_total[1m]))",
    ])
    kv_cache = prom_query_first(prom_url, [
        f'100 * avg(vllm:gpu_cache_usage_perc{{namespace="{namespace}",model_name="{model_name}"}})',
        f'100 * avg(vllm:gpu_cache_usage_perc{{namespace="{namespace}"}})',
        f'avg(vllm:kv_cache_usage_perc{{namespace="{namespace}",model_name="{model_name}"}})',
        f'avg(vllm:kv_cache_usage_perc{{namespace="{namespace}"}})',
    ])
    ready_q = READY_REPLICAS_TEMPLATE.format(deployment=deployment, namespace=namespace)
    replicas = prom_query(prom_url, ready_q)
    return {
        "num_requests_running": running,
        "num_requests_waiting": waiting,
        "avg_generation_throughput_toks_per_s": throughput,
        "kv_cache_usage_perc": kv_cache,
        "ready_replicas": replicas,
    }

def scale_deployment(deployment: str, namespace: str, replicas: int, dry_run: bool = False) -> bool:
    cmd = ["kubectl", "scale", "deploy", deployment, "-n", namespace, f"--replicas={replicas}"]
    if dry_run:
        print(f"[DRY-RUN] Would run: {' '.join(cmd)}", flush=True)
        return True
    try:
        subprocess.check_call(cmd, timeout=30)
        return True
    except subprocess.CalledProcessError as e:
        print(f"[ERROR] kubectl scale failed: {e}", flush=True)
        return False

def main() -> None:
    ap = argparse.ArgumentParser(description="ML autoscaler controller loop.")
    ap.add_argument("--model-path", required=True, help="Path to trained .joblib model")
    ap.add_argument("--prom-url", default="http://localhost:9090", help="Prometheus base URL")
    ap.add_argument("--deployment-name", required=True, help="Target Kubernetes deployment")
    ap.add_argument("--namespace", default="llm-demo")
    ap.add_argument("--served-model-name", required=True, help="vLLM model_name label")
    ap.add_argument("--min-replicas", type=int, default=1)
    ap.add_argument("--max-replicas", type=int, default=5)
    ap.add_argument("--interval", type=int, default=10, help="Seconds between scaling decisions")
    ap.add_argument("--cooldown", type=int, default=30, help="Min seconds between scale changes")
    ap.add_argument("--dry-run", action="store_true", help="Log decisions without scaling")
    ap.add_argument("--max-iterations", type=int, default=0, help="Stop after N iterations (0 = forever)")
    args = ap.parse_args()
    try:
        import joblib
        import numpy as np
    except ImportError as e:
        print(f"Missing dependency: {e}")
        print("Install with: pip install scikit-learn joblib numpy requests")
        sys.exit(1)
    bundle = joblib.load(args.model_path)
    model = bundle["model"]
    feature_names = bundle["features"]
    print(json.dumps({
        "event": "controller_start",
        "model_path": args.model_path,
        "deployment": args.deployment_name,
        "namespace": args.namespace,
        "served_model_name": args.served_model_name,
        "interval_seconds": args.interval,
        "cooldown_seconds": args.cooldown,
        "min_replicas": args.min_replicas,
        "max_replicas": args.max_replicas,
        "dry_run": args.dry_run,
        "features": feature_names,
    }, indent=2), flush=True)
    prev_metrics: Optional[Dict[str, float]] = None
    last_scale_time = 0.0
    current_target = 0
    iteration = 0
    while True:
        iteration += 1
        if args.max_iterations > 0 and iteration > args.max_iterations:
            print(f"Reached max iterations ({args.max_iterations}), exiting.", flush=True)
            break
        raw = fetch_metrics(args.prom_url, args.namespace, args.served_model_name, args.deployment_name)
        norm = raw_row_to_dict(raw)
        feat_vec = compute_features(norm, prev_metrics)
        prev_metrics = norm
        X = np.array([feat_vec], dtype=np.float32)
        predicted = int(model.predict(X)[0])
        predicted = max(args.min_replicas, min(args.max_replicas, predicted))
        now = time.time()
        in_cooldown = (now - last_scale_time) < args.cooldown
        should_scale = predicted != current_target and not in_cooldown
        log_entry = {
            "event": "tick",
            "iteration": iteration,
            "metrics": {k: safe_float(v) for k, v in raw.items()},
            "predicted_replicas": predicted,
            "current_target": current_target,
            "in_cooldown": in_cooldown,
            "action": "scale" if should_scale else "hold",
        }
        print(json.dumps(log_entry), flush=True)
        if should_scale:
            ok = scale_deployment(args.deployment_name, args.namespace, predicted, dry_run=args.dry_run)
            if ok:
                current_target = predicted
                last_scale_time = now
        time.sleep(args.interval)

if __name__ == "__main__":
    main()
