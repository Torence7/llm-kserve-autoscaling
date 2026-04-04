#!/usr/bin/env python3
import argparse
import csv
import json
import time
from pathlib import Path
from typing import Dict, Optional

import requests


DEFAULT_QUERIES = {
    "num_requests_running": "vllm:num_requests_running",
    "num_requests_waiting": "vllm:num_requests_waiting",
    "avg_generation_throughput_toks_per_s": "vllm:avg_generation_throughput_toks_per_s",
    "kv_cache_usage_perc": "vllm:kv_cache_usage_perc",
    "ready_replicas_template": 'kube_deployment_status_replicas_ready{{deployment="{deployment}", namespace="{namespace}"}}',
}


def prom_query(prom_url: str, query: str, timeout_s: float = 10.0) -> Optional[float]:
    url = prom_url.rstrip("/") + "/api/v1/query"
    try:
        resp = requests.get(url, params={"query": query}, timeout=timeout_s)
        resp.raise_for_status()
        payload = resp.json()
        results = payload.get("data", {}).get("result", [])
        if not results:
            return None
        return float(results[0]["value"][1])
    except Exception:
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
    ap = argparse.ArgumentParser(description="Poll Prometheus during a benchmark run and save system metrics.")
    ap.add_argument("--prom-url", required=True, help="Prometheus base URL, e.g. http://localhost:9090")
    ap.add_argument("--duration-seconds", type=int, required=True, help="How long to poll for")
    ap.add_argument("--interval-seconds", type=int, default=5, help="Polling interval")
    ap.add_argument("--deployment-name", required=True, help="Kubernetes deployment name")
    ap.add_argument("--namespace", default="llm-demo", help="Kubernetes namespace for ready replica query")
    ap.add_argument("--outcsv", required=True, help="CSV path to write")
    args = ap.parse_args()

    outcsv = Path(args.outcsv)
    outcsv.parent.mkdir(parents=True, exist_ok=True)

    ready_q = DEFAULT_QUERIES["ready_replicas_template"].format(
        deployment=args.deployment_name,
        namespace=args.namespace,
    )

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
                    "namespace": args.namespace,
                    "outcsv": str(outcsv),
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
                "num_requests_running": prom_query(args.prom_url, DEFAULT_QUERIES["num_requests_running"]),
                "num_requests_waiting": prom_query(args.prom_url, DEFAULT_QUERIES["num_requests_waiting"]),
                "avg_generation_throughput_toks_per_s": prom_query(
                    args.prom_url, DEFAULT_QUERIES["avg_generation_throughput_toks_per_s"]
                ),
                "kv_cache_usage_perc": prom_query(args.prom_url, DEFAULT_QUERIES["kv_cache_usage_perc"]),
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