#!/usr/bin/env python3
import argparse
import csv
import json
import time
from pathlib import Path
from typing import Dict, Optional

import requests


DEFAULT_QUERIES = {
    "num_requests_running": 'vllm:num_requests_running',
    "num_requests_waiting": 'vllm:num_requests_waiting',
    "kv_cache_usage_perc": 'vllm:kv_cache_usage_perc',
    "avg_generation_throughput": 'vllm:avg_generation_throughput_toks_per_s',
    "ready_replicas": 'kube_deployment_status_replicas_ready{deployment="%s"}',
}


def prom_query(prom_url: str, query: str) -> Optional[float]:
    url = prom_url.rstrip("/") + "/api/v1/query"
    resp = requests.get(url, params={"query": query}, timeout=10)
    resp.raise_for_status()
    data = resp.json()
    result = data.get("data", {}).get("result", [])
    if not result:
        return None
    try:
        return float(result[0]["value"][1])
    except Exception:
        return None


def main() -> None:
    ap = argparse.ArgumentParser(description="Poll Prometheus and save benchmark system metrics.")
    ap.add_argument("--prom-url", required=True, help="Prometheus base URL, e.g. http://localhost:9090")
    ap.add_argument("--duration-seconds", type=int, required=True)
    ap.add_argument("--interval-seconds", type=int, default=15)
    ap.add_argument("--deployment-name", required=True, help="Kubernetes deployment name for ready replicas query")
    ap.add_argument("--outcsv", required=True)
    args = ap.parse_args()

    outcsv = Path(args.outcsv)
    outcsv.parent.mkdir(parents=True, exist_ok=True)

    start = time.time()
    end = start + args.duration_seconds

    with open(outcsv, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow([
            "timestamp",
            "num_requests_running",
            "num_requests_waiting",
            "kv_cache_usage_perc",
            "avg_generation_throughput",
            "ready_replicas",
        ])

        while time.time() < end:
            ts = time.time()
            ready_q = DEFAULT_QUERIES["ready_replicas"] % args.deployment_name

            row = [
                ts,
                prom_query(args.prom_url, DEFAULT_QUERIES["num_requests_running"]),
                prom_query(args.prom_url, DEFAULT_QUERIES["num_requests_waiting"]),
                prom_query(args.prom_url, DEFAULT_QUERIES["kv_cache_usage_perc"]),
                prom_query(args.prom_url, DEFAULT_QUERIES["avg_generation_throughput"]),
                prom_query(args.prom_url, ready_q),
            ]
            writer.writerow(row)
            f.flush()
            time.sleep(args.interval_seconds)


if __name__ == "__main__":
    main()