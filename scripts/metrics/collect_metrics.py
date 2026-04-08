#!/usr/bin/env python3
import argparse
import csv
import json
import time
from pathlib import Path
from typing import Dict, List, Optional

import requests


READY_REPLICAS_TEMPLATE = (
    'kube_deployment_status_replicas_ready{{deployment="{deployment}", namespace="{namespace}"}}'
)


def prom_query(prom_url: str, query: str, timeout_s: float = 10.0) -> Optional[float]:
    url = prom_url.rstrip("/") + "/api/v1/query"
    try:
        resp = requests.get(url, params={"query": query}, timeout=timeout_s)
        resp.raise_for_status()
        payload = resp.json()
        results = payload.get("data", {}).get("result", [])

        if not results:
            return None

        if len(results) > 1:
            raise ValueError(f"Query returned multiple series, expected one: {query}")

        return float(results[0]["value"][1])
    except Exception as e:
        print(f"[WARN] Prometheus query failed: {query} | error: {e}", flush=True)
        return None


def prom_query_first(prom_url: str, queries: List[str], timeout_s: float = 10.0) -> Optional[float]:
    for q in queries:
        value = prom_query(prom_url, q, timeout_s=timeout_s)
        if value is not None:
            return value
    return None


def write_row(writer: csv.writer, row: Dict[str, Optional[float]]) -> None:
    writer.writerow([
        row["timestamp"],
        row["num_requests_running"],
        row["num_requests_waiting"],
        row["avg_generation_throughput_toks_per_s"],
        row["kv_cache_usage_perc"],
        row["ready_replicas"],
    ])


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Poll Prometheus during a benchmark run and save system metrics."
    )
    ap.add_argument(
        "--prom-url",
        required=True,
        help="Prometheus base URL, e.g. http://localhost:9090",
    )
    ap.add_argument(
        "--duration-seconds",
        type=int,
        required=True,
        help="How long to poll for",
    )
    ap.add_argument(
        "--interval-seconds",
        type=int,
        default=5,
        help="Polling interval",
    )
    ap.add_argument(
        "--deployment-name",
        required=True,
        help="Kubernetes deployment name for ready replica query",
    )
    ap.add_argument(
        "--model-name",
        required=True,
        help='vLLM model_name label, e.g. "Qwen/Qwen2.5-0.5B-Instruct"',
    )
    ap.add_argument(
        "--namespace",
        default="llm-demo",
        help="Kubernetes namespace for ready replica query",
    )
    ap.add_argument(
        "--outcsv",
        required=True,
        help="CSV path to write",
    )
    args = ap.parse_args()

    outcsv = Path(args.outcsv)
    outcsv.parent.mkdir(parents=True, exist_ok=True)

    ready_q = READY_REPLICAS_TEMPLATE.format(
        deployment=args.deployment_name,
        namespace=args.namespace,
    )

    num_requests_running_q = [
        f'sum(vllm:num_requests_running{{namespace="{args.namespace}",model_name="{args.model_name}"}})',
        f'sum(vllm:num_requests_running{{namespace="{args.namespace}"}})',
        f'sum(vllm:num_requests_running{{model_name="{args.model_name}"}})',
        "sum(vllm:num_requests_running)",
    ]
    num_requests_waiting_q = [
        f'sum(vllm:num_requests_waiting{{namespace="{args.namespace}",model_name="{args.model_name}"}})',
        f'sum(vllm:num_requests_waiting{{namespace="{args.namespace}"}})',
        f'sum(vllm:num_requests_waiting{{model_name="{args.model_name}"}})',
        "sum(vllm:num_requests_waiting)",
    ]
    kv_cache_usage_q = [
        f'100 * avg(vllm:gpu_cache_usage_perc{{namespace="{args.namespace}",model_name="{args.model_name}"}})',
        f'100 * avg(vllm:gpu_cache_usage_perc{{namespace="{args.namespace}"}})',
        f'100 * avg(vllm:gpu_cache_usage_perc{{model_name="{args.model_name}"}})',
        "100 * avg(vllm:gpu_cache_usage_perc)",
        f'avg(vllm:kv_cache_usage_perc{{namespace="{args.namespace}",model_name="{args.model_name}"}})',
        f'avg(vllm:kv_cache_usage_perc{{namespace="{args.namespace}"}})',
        f'avg(vllm:kv_cache_usage_perc{{model_name="{args.model_name}"}})',
        "avg(vllm:kv_cache_usage_perc)",
    ]
    generation_throughput_q = [
        f'sum(rate(vllm:generation_tokens_total{{namespace="{args.namespace}",model_name="{args.model_name}"}}[1m]))',
        f'sum(rate(vllm:generation_tokens_total{{namespace="{args.namespace}"}}[1m]))',
        f'sum(rate(vllm:generation_tokens_total{{model_name="{args.model_name}"}}[1m]))',
        "sum(rate(vllm:generation_tokens_total[1m]))",
    ]

    end_time = time.time() + args.duration_seconds

    with open(outcsv, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow([
            "timestamp",
            "num_requests_running",
            "num_requests_waiting",
            "avg_generation_throughput_toks_per_s",
            "kv_cache_usage_perc",
            "ready_replicas",
        ])

        print(
            json.dumps(
                {
                    "prom_url": args.prom_url,
                    "duration_seconds": args.duration_seconds,
                    "interval_seconds": args.interval_seconds,
                    "deployment_name": args.deployment_name,
                    "model_name": args.model_name,
                    "namespace": args.namespace,
                    "outcsv": str(outcsv),
                    "queries": {
                        "num_requests_running": num_requests_running_q,
                        "num_requests_waiting": num_requests_waiting_q,
                        "avg_generation_throughput_toks_per_s": generation_throughput_q,
                        "kv_cache_usage_perc": kv_cache_usage_q,
                        "ready_replicas": ready_q,
                    },
                },
                indent=2,
            ),
            flush=True,
        )

        sample_idx = 0
        while time.time() < end_time:
            now = time.time()
            row = {
                "timestamp": now,
                "num_requests_running": prom_query_first(args.prom_url, num_requests_running_q),
                "num_requests_waiting": prom_query_first(args.prom_url, num_requests_waiting_q),
                "avg_generation_throughput_toks_per_s": prom_query_first(args.prom_url, generation_throughput_q),
                "kv_cache_usage_perc": prom_query_first(args.prom_url, kv_cache_usage_q),
                "ready_replicas": prom_query(args.prom_url, ready_q),
            }
            write_row(writer, row)
            f.flush()

            sample_idx += 1
            if sample_idx % 5 == 0:
                print(f"Collected {sample_idx} samples...", flush=True)

            time.sleep(args.interval_seconds)

    print(f"Wrote system metrics to {outcsv}", flush=True)


if __name__ == "__main__":
    main()
