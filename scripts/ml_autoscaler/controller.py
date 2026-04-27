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
import requests as http_requests
from features import compute_features, compute_little_law_prior, raw_row_to_dict, safe_float
import argparse
import json
import math
import subprocess
import sys
import time
from typing import Dict, List, Optional
import os
sys.path.insert(0, os.path.dirname(__file__))

READY_REPLICAS_TEMPLATE = (
    'kube_deployment_status_replicas_ready{{deployment="{deployment}", namespace="{namespace}"}}'
)


def prom_query(prom_url: str, query: str, timeout_s: float = 10.0) -> Optional[float]:
    url = prom_url.rstrip("/") + "/api/v1/query"
    try:
        resp = http_requests.get(
            url, params={"query": query}, timeout=timeout_s)
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
    output_tps = prom_query_first(prom_url, [
        f'sum(rate(vllm:generation_tokens_total{{namespace="{namespace}",model_name="{model_name}"}}[1m]))',
        f'sum(rate(vllm:generation_tokens_total{{namespace="{namespace}"}}[1m]))',
        "sum(rate(vllm:generation_tokens_total[1m]))",
    ])
    input_tps = prom_query_first(prom_url, [
        f'sum(rate(vllm:prompt_tokens_total{{namespace="{namespace}",model_name="{model_name}"}}[1m]))',
        f'sum(rate(vllm:prompt_tokens_total{{namespace="{namespace}"}}[1m]))',
        "sum(rate(vllm:prompt_tokens_total[1m]))",
    ])

    p95_ttft_ms = prom_query_first(prom_url, [
        f'histogram_quantile(0.95, sum(rate(vllm:time_to_first_token_seconds_bucket{{namespace="{namespace}",model_name="{model_name}"}}[2m])) by (le)) * 1000',
        f'histogram_quantile(0.95, sum(rate(vllm:time_to_first_token_seconds_bucket{{namespace="{namespace}"}}[2m])) by (le)) * 1000',
        f'1000 * avg(vllm:time_to_first_token_seconds{{namespace="{namespace}",model_name="{model_name}",quantile="0.95"}})',
        f'1000 * avg(vllm:time_to_first_token_seconds{{namespace="{namespace}",quantile="0.95"}})',
    ])

    p95_itl_ms = prom_query_first(prom_url, [
        f'histogram_quantile(0.95, sum(rate(vllm:inter_token_latency_seconds_bucket{{namespace="{namespace}",model_name="{model_name}"}}[2m])) by (le)) * 1000',
        f'histogram_quantile(0.95, sum(rate(vllm:inter_token_latency_seconds_bucket{{namespace="{namespace}"}}[2m])) by (le)) * 1000',
        f'1000 * avg(vllm:inter_token_latency_seconds{{namespace="{namespace}",model_name="{model_name}",quantile="0.95"}})',
        f'1000 * avg(vllm:inter_token_latency_seconds{{namespace="{namespace}",quantile="0.95"}})',
    ])

    kv_cache_hit_rate = prom_query_first(prom_url, [
        f'avg(vllm:gpu_prefix_cache_hit_rate{{namespace="{namespace}",model_name="{model_name}"}})',
        f'avg(vllm:gpu_prefix_cache_hit_rate{{namespace="{namespace}"}})',
        f'avg(vllm:kv_cache_hit_rate{{namespace="{namespace}",model_name="{model_name}"}})',
        f'avg(vllm:kv_cache_hit_rate{{namespace="{namespace}"}})',
    ])

    batch_size_avg = prom_query_first(prom_url, [
        f'avg(vllm:batch_size{{namespace="{namespace}",model_name="{model_name}"}})',
        f'avg(vllm:batch_size{{namespace="{namespace}"}})',
        f'avg(vllm:num_requests_running{{namespace="{namespace}",model_name="{model_name}"}})',
        f'avg(vllm:num_requests_running{{namespace="{namespace}"}})',
    ])

    kv_cache = prom_query_first(prom_url, [
        f'100 * avg(vllm:gpu_cache_usage_perc{{namespace="{namespace}",model_name="{model_name}"}})',
        f'100 * avg(vllm:gpu_cache_usage_perc{{namespace="{namespace}"}})',
        f'avg(vllm:kv_cache_usage_perc{{namespace="{namespace}",model_name="{model_name}"}})',
        f'avg(vllm:kv_cache_usage_perc{{namespace="{namespace}"}})',
    ])
    ready_q = READY_REPLICAS_TEMPLATE.format(
        deployment=deployment, namespace=namespace)
    replicas = prom_query(prom_url, ready_q)
    return {
        "num_requests_running": running,
        "num_requests_waiting": waiting,
        "avg_generation_throughput_toks_per_s": output_tps,
        "prompt_tokens_per_sec": input_tps,
        "output_tokens_per_sec": output_tps,
        "p95_ttft_ms": p95_ttft_ms,
        "p95_itl_ms": p95_itl_ms,
        "kv_cache_hit_rate": kv_cache_hit_rate,
        "batch_size_avg": batch_size_avg,
        "queue_depth": waiting,
        "kv_cache_usage_perc": kv_cache,
        "ready_replicas": replicas,
    }


def scale_deployment(deployment: str, namespace: str, replicas: int, dry_run: bool = False) -> bool:
    cmd = ["kubectl", "scale", "deploy", deployment,
           "-n", namespace, f"--replicas={replicas}"]
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
    ap.add_argument("--model-path", required=True,
                    help="Path to trained .joblib model")
    ap.add_argument("--prom-url", default="http://localhost:9090",
                    help="Prometheus base URL")
    ap.add_argument("--deployment-name", required=True,
                    help="Target Kubernetes deployment")
    ap.add_argument("--namespace", default="llm-demo")
    ap.add_argument("--served-model-name", required=True,
                    help="vLLM model_name label")
    ap.add_argument("--min-replicas", type=int, default=1)
    ap.add_argument("--max-replicas", type=int, default=5)
    ap.add_argument("--interval", type=int, default=10,
                    help="Seconds between scaling decisions")
    ap.add_argument("--cooldown", type=int, default=30,
                    help="Min seconds between scale changes")
    ap.add_argument("--dry-run", action="store_true",
                    help="Log decisions without scaling")
    ap.add_argument("--max-iterations", type=int, default=0,
                    help="Stop after N iterations (0 = forever)")
    args = ap.parse_args()
    try:
        import joblib
        import numpy as np
    except ImportError as e:
        print(f"Missing dependency: {e}")
        print("Install with: pip install scikit-learn joblib numpy requests")
        sys.exit(1)
    bundle = joblib.load(args.model_path)
    model_type = str(bundle.get("model_type", "legacy_classifier"))
    is_residual_model = "residual_model" in bundle

    if is_residual_model:
        model = bundle["residual_model"]
    else:
        model = bundle["model"]

    feature_names = bundle.get("features", [])
    prior_params = bundle.get("prior_params", {})
    target_utilization_per_pod = float(
        prior_params.get("target_utilization_per_pod", 0.75))
    assumed_input_tokens_per_request = float(
        prior_params.get("assumed_input_tokens_per_request", 256.0))
    assumed_output_tokens_per_request = float(
        prior_params.get("assumed_output_tokens_per_request", 128.0))
    min_latency_ms = float(prior_params.get("min_latency_ms", 50.0))

    bundle_min_replicas = int(bundle.get("min_replicas", args.min_replicas))
    bundle_max_replicas = int(bundle.get("max_replicas", args.max_replicas))
    effective_min_replicas = max(1, args.min_replicas, bundle_min_replicas)
    effective_max_replicas = max(effective_min_replicas, min(
        args.max_replicas, bundle_max_replicas))

    print(json.dumps({
        "event": "controller_start",
        "model_type": model_type,
        "model_path": args.model_path,
        "deployment": args.deployment_name,
        "namespace": args.namespace,
        "served_model_name": args.served_model_name,
        "interval_seconds": args.interval,
        "cooldown_seconds": args.cooldown,
        "min_replicas": effective_min_replicas,
        "max_replicas": effective_max_replicas,
        "dry_run": args.dry_run,
        "features": feature_names,
        "prior_params": {
            "target_utilization_per_pod": target_utilization_per_pod,
            "assumed_input_tokens_per_request": assumed_input_tokens_per_request,
            "assumed_output_tokens_per_request": assumed_output_tokens_per_request,
            "min_latency_ms": min_latency_ms,
        },
    }, indent=2), flush=True)

    last_scale_time = 0.0
    current_target = 0
    iteration = 0
    while True:
        iteration += 1
        if args.max_iterations > 0 and iteration > args.max_iterations:
            print(
                f"Reached max iterations ({args.max_iterations}), exiting.", flush=True)
            break
        raw = fetch_metrics(args.prom_url, args.namespace,
                            args.served_model_name, args.deployment_name)
        norm = raw_row_to_dict(raw)

        if current_target <= 0:
            current_target = int(max(effective_min_replicas, min(
                effective_max_replicas, round(norm["current_replicas"]))))

        feat_vec = compute_features(norm)
        X = np.array([feat_vec], dtype=np.float32)

        prior = compute_little_law_prior(
            row=norm,
            min_replicas=effective_min_replicas,
            max_replicas=effective_max_replicas,
            target_utilization_per_pod=target_utilization_per_pod,
            assumed_input_tokens_per_request=assumed_input_tokens_per_request,
            assumed_output_tokens_per_request=assumed_output_tokens_per_request,
            min_latency_ms=min_latency_ms,
        )

        if is_residual_model:
            residual_pred = float(model.predict(X)[0])
            predicted = int(math.ceil(prior + residual_pred))
            predicted = max(effective_min_replicas, min(
                effective_max_replicas, predicted))
        else:
            residual_pred = None
            predicted = int(model.predict(X)[0])
            predicted = max(effective_min_replicas, min(
                effective_max_replicas, predicted))

        # Reactive guard: if latency is high or queue is building, don't let
        # the model suppress the prior's scale-up signal.
        queue = norm.get("queue_depth", 0.0)
        ttft = norm.get("p95_ttft_ms", 0.0)
        itl = norm.get("p95_itl_ms", 0.0)
        latency_pressure = (
            (queue > 2.0)
            or (ttft > 2000.0 and norm.get("output_tokens_per_sec", 0.0) > 0)
            or (itl > 150.0 and norm.get("output_tokens_per_sec", 0.0) > 0)
        )
        if latency_pressure and predicted < prior:
            predicted = prior

        now = time.time()
        in_cooldown = (now - last_scale_time) < args.cooldown
        should_scale = predicted != current_target and not in_cooldown
        log_entry = {
            "event": "tick",
            "iteration": iteration,
            "metrics": {k: safe_float(v) for k, v in raw.items()},
            "little_law_prior": prior,
            "predicted_residual": residual_pred,
            "predicted_replicas": predicted,
            "latency_pressure": latency_pressure,
            "current_target": current_target,
            "in_cooldown": in_cooldown,
            "action": "scale" if should_scale else "hold",
        }
        print(json.dumps(log_entry), flush=True)
        if should_scale:
            ok = scale_deployment(
                args.deployment_name, args.namespace, predicted, dry_run=args.dry_run)
            if ok:
                current_target = predicted
                last_scale_time = now
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
