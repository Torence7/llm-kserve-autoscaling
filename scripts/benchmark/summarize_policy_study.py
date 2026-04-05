#!/usr/bin/env python3
import argparse
import csv
import json
from pathlib import Path
from statistics import mean
from typing import Any, Dict, List, Optional


def load_json(path: Path) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def load_metrics_csv(path: Path) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    if not path.exists():
        return rows
    with open(path, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(row)
    return rows


def fnum(v: Any) -> Optional[float]:
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    s = str(v).strip()
    if not s or s.lower() == "none":
        return None
    try:
        return float(s)
    except ValueError:
        return None


def avg(values: List[Optional[float]]) -> Optional[float]:
    vals = [v for v in values if v is not None]
    return mean(vals) if vals else None


def maxv(values: List[Optional[float]]) -> Optional[float]:
    vals = [v for v in values if v is not None]
    return max(vals) if vals else None


def minv(values: List[Optional[float]]) -> Optional[float]:
    vals = [v for v in values if v is not None]
    return min(vals) if vals else None


def count_changes(values: List[Optional[float]]) -> int:
    vals = [v for v in values if v is not None]
    if len(vals) < 2:
        return 0
    changes = 0
    prev = vals[0]
    for cur in vals[1:]:
        if cur != prev:
            changes += 1
            prev = cur
    return changes


def summarize_run(run_dir: Path) -> Optional[Dict[str, Any]]:
    summary_path = run_dir / "summary.json"
    metadata_path = run_dir / "metadata.json"
    metrics_path = run_dir / "system_metrics.csv"
    if not summary_path.exists() or not metadata_path.exists():
        return None

    summary = load_json(summary_path)
    metadata = load_json(metadata_path)
    metric_rows = load_metrics_csv(metrics_path)

    waiting = [fnum(r.get("num_requests_waiting")) for r in metric_rows]
    running = [fnum(r.get("num_requests_running")) for r in metric_rows]
    throughput = [fnum(r.get("avg_generation_throughput_toks_per_s")) for r in metric_rows]
    kv_cache = [fnum(r.get("kv_cache_usage_perc")) for r in metric_rows]
    replicas = [fnum(r.get("ready_replicas")) for r in metric_rows]

    total = summary.get("requests_total_recorded") or 0
    failed = summary.get("requests_failed") or 0
    error_rate = (failed / total) if total else None

    return {
        "run_dir": str(run_dir),
        "model_key": metadata.get("model_key"),
        "scenario": metadata.get("scenario"),
        "policy_key": metadata.get("policy_key"),
        "policy_type": metadata.get("policy_type"),
        "requests_total_recorded": total,
        "requests_ok": summary.get("requests_ok"),
        "requests_failed": failed,
        "error_rate": error_rate,
        "latency_p50_ms": fnum(summary.get("latency_p50_ms")),
        "latency_p95_ms": fnum(summary.get("latency_p95_ms")),
        "ttft_p50_ms": fnum(summary.get("ttft_p50_ms")),
        "ttft_p95_ms": fnum(summary.get("ttft_p95_ms")),
        "avg_waiting_requests": avg(waiting),
        "max_waiting_requests": maxv(waiting),
        "avg_running_requests": avg(running),
        "max_running_requests": maxv(running),
        "avg_generation_toks_per_s": avg(throughput),
        "max_generation_toks_per_s": maxv(throughput),
        "avg_kv_cache_usage_perc": avg(kv_cache),
        "max_kv_cache_usage_perc": maxv(kv_cache),
        "avg_ready_replicas": avg(replicas),
        "min_ready_replicas": minv(replicas),
        "max_ready_replicas": maxv(replicas),
        "replica_change_events": count_changes(replicas),
        "policy_settle_seconds": metadata.get("policy_settle_seconds"),
        "max_in_flight": metadata.get("max_in_flight"),
    }


def aggregate(rows: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    buckets: Dict[tuple, List[Dict[str, Any]]] = {}
    for row in rows:
        key = (row["model_key"], row["scenario"], row["policy_key"])
        buckets.setdefault(key, []).append(row)

    out: List[Dict[str, Any]] = []
    numeric_fields = [
        "requests_total_recorded", "requests_ok", "requests_failed", "error_rate",
        "latency_p50_ms", "latency_p95_ms", "ttft_p50_ms", "ttft_p95_ms",
        "avg_waiting_requests", "max_waiting_requests", "avg_running_requests", "max_running_requests",
        "avg_generation_toks_per_s", "max_generation_toks_per_s",
        "avg_kv_cache_usage_perc", "max_kv_cache_usage_perc",
        "avg_ready_replicas", "min_ready_replicas", "max_ready_replicas", "replica_change_events",
    ]
    for (model_key, scenario, policy_key), bucket in sorted(buckets.items()):
        row: Dict[str, Any] = {
            "model_key": model_key,
            "scenario": scenario,
            "policy_key": policy_key,
            "runs": len(bucket),
        }
        for field in numeric_fields:
            row[field] = avg([fnum(r.get(field)) for r in bucket])
        out.append(row)
    return out


def write_csv(path: Path, rows: List[Dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not rows:
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write("")
        return
    fieldnames = list(rows[0].keys())
    with open(path, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--results-root", required=True)
    ap.add_argument("--model-key", required=True)
    ap.add_argument("--study-root", required=True)
    args = ap.parse_args()

    model_root = Path(args.results_root) / args.model_key
    run_rows: List[Dict[str, Any]] = []
    if model_root.exists():
        for summary_path in model_root.glob("*/*/summary.json"):
            run_dir = summary_path.parent
            row = summarize_run(run_dir)
            if row is not None:
                run_rows.append(row)

    aggregate_rows = aggregate(run_rows)
    study_root = Path(args.study_root)
    write_csv(study_root / "all_runs.csv", run_rows)
    write_csv(study_root / "aggregated_by_policy_scenario.csv", aggregate_rows)

    leaderboard = sorted(
        aggregate_rows,
        key=lambda r: (
            float("inf") if r.get("latency_p95_ms") is None else r["latency_p95_ms"],
            float("inf") if r.get("ttft_p95_ms") is None else r["ttft_p95_ms"],
            float("inf") if r.get("error_rate") is None else r["error_rate"],
            float("inf") if r.get("avg_ready_replicas") is None else r["avg_ready_replicas"],
        ),
    )
    with open(study_root / "leaderboard.json", "w", encoding="utf-8") as f:
        json.dump(leaderboard, f, indent=2)

    print(json.dumps({
        "study_root": str(study_root),
        "runs_found": len(run_rows),
        "aggregated_rows": len(aggregate_rows),
        "all_runs_csv": str(study_root / "all_runs.csv"),
        "aggregate_csv": str(study_root / "aggregated_by_policy_scenario.csv"),
        "leaderboard_json": str(study_root / "leaderboard.json"),
    }, indent=2))


if __name__ == "__main__":
    main()