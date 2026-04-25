#!/usr/bin/env python3
import argparse
import csv
import json
from pathlib import Path
from statistics import mean
from typing import Any, Dict, Iterable, List, Optional, Tuple

import yaml


CORE_FILES = ["summary.json", "metadata.json", "requests.csv", "system_metrics.csv"]


def load_json(path: Path) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def load_yaml(path: Path) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def load_csv_rows(path: Path) -> List[Dict[str, Any]]:
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


def ibool(v: Any) -> bool:
    if isinstance(v, bool):
        return v
    s = str(v).strip().lower()
    return s in {"1", "true", "yes"}


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


def stdev(values: List[float]) -> Optional[float]:
    n = len(values)
    if n < 2:
        return None
    mu = sum(values) / n
    var = sum((v - mu) ** 2 for v in values) / (n - 1)
    return var ** 0.5


def ci95_halfwidth(values: List[Optional[float]]) -> Optional[float]:
    vals = [v for v in values if v is not None]
    if len(vals) < 2:
        return None
    sd = stdev(vals)
    if sd is None:
        return None
    return 1.96 * sd / (len(vals) ** 0.5)


def integrate_replica_seconds(metric_rows: List[Dict[str, Any]]) -> Optional[float]:
    points: List[Tuple[float, float]] = []
    for row in metric_rows:
        ts = fnum(row.get("timestamp"))
        rep = fnum(row.get("ready_replicas"))
        if ts is None or rep is None:
            continue
        points.append((ts, rep))
    if len(points) < 2:
        return None
    points.sort()
    total = 0.0
    for i in range(len(points) - 1):
        ts, rep = points[i]
        next_ts, _ = points[i + 1]
        total += max(0.0, next_ts - ts) * rep
    return total


def compute_scale_timing(metric_rows: List[Dict[str, Any]], start_replicas: Optional[float]) -> Dict[str, Optional[float]]:
    points: List[Tuple[float, float]] = []
    for row in metric_rows:
        ts = fnum(row.get("timestamp"))
        rep = fnum(row.get("ready_replicas"))
        if ts is None or rep is None:
            continue
        points.append((ts, rep))
    if not points:
        return {
            "first_scale_delay_s": None,
            "time_to_peak_scale_s": None,
            "recovery_delay_s": None,
        }
    points.sort()
    t0 = points[0][0]
    baseline = start_replicas if start_replicas is not None else points[0][1]
    peak = max(rep for _, rep in points)

    first_scale_delay = None
    first_peak_time = None
    recovery_delay = None

    for ts, rep in points:
        if first_scale_delay is None and rep > baseline:
            first_scale_delay = ts - t0
        if first_peak_time is None and rep == peak and peak > baseline:
            first_peak_time = ts
    if first_peak_time is not None:
        for ts, rep in points:
            if ts > first_peak_time and rep <= baseline:
                recovery_delay = ts - first_peak_time
                break

    return {
        "first_scale_delay_s": first_scale_delay,
        "time_to_peak_scale_s": None if first_peak_time is None else first_peak_time - t0,
        "recovery_delay_s": recovery_delay,
    }


def union_interval_seconds(intervals: Iterable[Tuple[float, float]]) -> float:
    cleaned = sorted((start, end) for start, end in intervals if end is not None and start is not None and end > start)
    if not cleaned:
        return 0.0
    merged: List[List[float]] = [[cleaned[0][0], cleaned[0][1]]]
    for start, end in cleaned[1:]:
        if start <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    return sum(end - start for start, end in merged)


def derive_slo_metrics(request_rows: List[Dict[str, Any]], scenario_cfg: Dict[str, Any]) -> Dict[str, Optional[float]]:
    slo_cfg = scenario_cfg.get("slo", {}) if isinstance(scenario_cfg, dict) else {}
    ttft_slo_ms = fnum(slo_cfg.get("ttft_p95_ms"))
    e2e_slo_ms = fnum(slo_cfg.get("e2e_p95_ms"))

    ok_rows = [r for r in request_rows if ibool(r.get("ok"))]
    ttft_violations = []
    e2e_violations = []

    ok_ttft_values: List[float] = []
    ok_e2e_values: List[float] = []

    for row in ok_rows:
        start_ts = fnum(row.get("start_ts"))
        end_ts = fnum(row.get("end_ts"))
        ttft_ms = fnum(row.get("ttft_ms"))
        latency_ms = fnum(row.get("latency_ms"))
        if ttft_ms is not None:
            ok_ttft_values.append(ttft_ms)
        if latency_ms is not None:
            ok_e2e_values.append(latency_ms)
        if ttft_slo_ms is not None and ttft_ms is not None and start_ts is not None and end_ts is not None and ttft_ms > ttft_slo_ms:
            ttft_violations.append((start_ts, end_ts))
        if e2e_slo_ms is not None and latency_ms is not None and start_ts is not None and end_ts is not None and latency_ms > e2e_slo_ms:
            e2e_violations.append((start_ts, end_ts))

    ttft_violation_count = 0 if ttft_slo_ms is None else sum(1 for v in ok_ttft_values if v > ttft_slo_ms)
    e2e_violation_count = 0 if e2e_slo_ms is None else sum(1 for v in ok_e2e_values if v > e2e_slo_ms)

    return {
        "ttft_slo_ms": ttft_slo_ms,
        "e2e_slo_ms": e2e_slo_ms,
        "ok_requests_above_ttft_slo": ttft_violation_count if ttft_slo_ms is not None else None,
        "ok_requests_above_e2e_slo": e2e_violation_count if e2e_slo_ms is not None else None,
        "ttft_slo_violation_rate": (ttft_violation_count / len(ok_rows)) if ttft_slo_ms is not None and ok_rows else None,
        "e2e_slo_violation_rate": (e2e_violation_count / len(ok_rows)) if e2e_slo_ms is not None and ok_rows else None,
        "wall_time_with_ttft_slo_violations_s": union_interval_seconds(ttft_violations) if ttft_slo_ms is not None else None,
        "wall_time_with_e2e_slo_violations_s": union_interval_seconds(e2e_violations) if e2e_slo_ms is not None else None,
    }


def validate_run_dir(run_dir: Path) -> Tuple[bool, str]:
    missing = [name for name in CORE_FILES if not (run_dir / name).exists()]
    if missing:
        return False, f"missing files: {', '.join(missing)}"
    return True, "complete"


def summarize_run(run_dir: Path) -> Optional[Dict[str, Any]]:
    ok, reason = validate_run_dir(run_dir)
    if not ok:
        return None

    summary_path = run_dir / "summary.json"
    metadata_path = run_dir / "metadata.json"
    metrics_path = run_dir / "system_metrics.csv"
    requests_path = run_dir / "requests.csv"

    summary = load_json(summary_path)
    metadata = load_json(metadata_path)
    metric_rows = load_csv_rows(metrics_path)
    request_rows = load_csv_rows(requests_path)

    scenario_cfg: Dict[str, Any] = {}
    scenario_path = metadata.get("scenario_path")
    if scenario_path:
        scenario_file = Path(str(scenario_path))
        if scenario_file.exists():
            scenario_cfg = load_yaml(scenario_file)

    waiting = [fnum(r.get("num_requests_waiting")) for r in metric_rows]
    running = [fnum(r.get("num_requests_running")) for r in metric_rows]
    throughput = [fnum(r.get("avg_generation_throughput_toks_per_s")) for r in metric_rows]
    kv_cache = [fnum(r.get("kv_cache_usage_perc")) for r in metric_rows]
    replicas = [fnum(r.get("ready_replicas")) for r in metric_rows]

    launched = int(summary.get("requests_launched") or 0)
    recorded = int(summary.get("requests_total_recorded") or 0)
    ok_requests = int(summary.get("requests_ok") or 0)
    failed = int(summary.get("requests_failed") or 0)
    unfinished = int(summary.get("requests_unfinished") or max(0, launched - recorded))

    scale_metrics = compute_scale_timing(metric_rows, fnum(metadata.get("start_replicas")))
    replica_seconds = integrate_replica_seconds(metric_rows)
    slo_metrics = derive_slo_metrics(request_rows, scenario_cfg)

    return {
        "run_dir": str(run_dir),
        "artifact_status": reason,
        "model_key": metadata.get("model_key"),
        "scenario": metadata.get("scenario"),
        "policy_key": metadata.get("policy_key"),
        "policy_type": metadata.get("policy_type"),
        "requests_launched": launched,
        "requests_total_recorded": recorded,
        "requests_ok": ok_requests,
        "requests_failed": failed,
        "requests_unfinished": unfinished,
        "completion_rate": (ok_requests / launched) if launched else None,
        "recorded_success_rate": (ok_requests / recorded) if recorded else None,
        "error_rate": (failed / recorded) if recorded else None,
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
        "replica_seconds": replica_seconds,
        "successful_requests_per_replica_second": (ok_requests / replica_seconds) if replica_seconds and replica_seconds > 0 else None,
        "policy_settle_seconds": metadata.get("policy_settle_seconds"),
        "max_in_flight": metadata.get("max_in_flight"),
        **scale_metrics,
        **slo_metrics,
    }


def aggregate(rows: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    buckets: Dict[tuple, List[Dict[str, Any]]] = {}
    for row in rows:
        key = (row["model_key"], row["scenario"], row["policy_key"])
        buckets.setdefault(key, []).append(row)

    out: List[Dict[str, Any]] = []
    averaged_fields = [
        "latency_p50_ms", "latency_p95_ms", "ttft_p50_ms", "ttft_p95_ms",
        "avg_waiting_requests", "max_waiting_requests", "avg_running_requests", "max_running_requests",
        "avg_generation_toks_per_s", "max_generation_toks_per_s",
        "avg_kv_cache_usage_perc", "max_kv_cache_usage_perc",
        "avg_ready_replicas", "min_ready_replicas", "max_ready_replicas", "replica_change_events",
        "first_scale_delay_s", "time_to_peak_scale_s", "recovery_delay_s",
        "ttft_slo_ms", "e2e_slo_ms",
        "ttft_slo_violation_rate", "e2e_slo_violation_rate",
        "wall_time_with_ttft_slo_violations_s", "wall_time_with_e2e_slo_violations_s",
    ]
    summed_fields = [
        "requests_launched", "requests_total_recorded", "requests_ok", "requests_failed", "requests_unfinished",
        "replica_seconds", "ok_requests_above_ttft_slo", "ok_requests_above_e2e_slo",
    ]

    for (model_key, scenario, policy_key), bucket in sorted(buckets.items()):
        row: Dict[str, Any] = {
            "model_key": model_key,
            "scenario": scenario,
            "policy_key": policy_key,
            "runs": len(bucket),
        }
        for field in summed_fields:
            vals = [fnum(r.get(field)) for r in bucket]
            row[field] = sum(v for v in vals if v is not None)
        for field in averaged_fields:
            vals = [fnum(r.get(field)) for r in bucket]
            row[field] = avg(vals)
            row[f"{field}_ci95_halfwidth"] = ci95_halfwidth(vals)

        launched = fnum(row.get("requests_launched")) or 0.0
        recorded = fnum(row.get("requests_total_recorded")) or 0.0
        ok_requests = fnum(row.get("requests_ok")) or 0.0
        failed = fnum(row.get("requests_failed")) or 0.0
        replica_seconds = fnum(row.get("replica_seconds")) or 0.0

        row["completion_rate"] = (ok_requests / launched) if launched else None
        row["recorded_success_rate"] = (ok_requests / recorded) if recorded else None
        row["error_rate"] = (failed / recorded) if recorded else None
        row["successful_requests_per_replica_second"] = (ok_requests / replica_seconds) if replica_seconds else None
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


def collect_candidate_run_dirs(model_root: Path) -> List[Path]:
    run_dirs: List[Path] = []
    if not model_root.exists():
        return run_dirs
    for scenario_dir in model_root.iterdir():
        if not scenario_dir.is_dir() or scenario_dir.name.startswith("study_"):
            continue
        for run_dir in scenario_dir.iterdir():
            if run_dir.is_dir():
                run_dirs.append(run_dir)
    return sorted(run_dirs)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--results-root", required=True)
    ap.add_argument("--model-key", required=True)
    ap.add_argument("--study-root", required=True)
    args = ap.parse_args()

    model_root = Path(args.results_root) / args.model_key
    candidate_run_dirs = collect_candidate_run_dirs(model_root)

    run_rows: List[Dict[str, Any]] = []
    excluded_rows: List[Dict[str, Any]] = []

    for run_dir in candidate_run_dirs:
        ok, reason = validate_run_dir(run_dir)
        if not ok:
            excluded_rows.append({"run_dir": str(run_dir), "reason": reason})
            continue
        row = summarize_run(run_dir)
        if row is None:
            excluded_rows.append({"run_dir": str(run_dir), "reason": "unable to summarize"})
            continue
        run_rows.append(row)

    aggregate_rows = aggregate(run_rows)
    study_root = Path(args.study_root)
    write_csv(study_root / "all_runs.csv", run_rows)
    write_csv(study_root / "aggregated_by_policy_scenario.csv", aggregate_rows)
    write_csv(study_root / "excluded_runs.csv", excluded_rows)

    leaderboard = sorted(
        aggregate_rows,
        key=lambda r: (
            -(r["completion_rate"] if r.get("completion_rate") is not None else -1.0),
            (r["e2e_slo_violation_rate"] if r.get("e2e_slo_violation_rate") is not None else float("inf")),
            (r["ttft_p95_ms"] if r.get("ttft_p95_ms") is not None else float("inf")),
            (r["latency_p95_ms"] if r.get("latency_p95_ms") is not None else float("inf")),
            (r["avg_ready_replicas"] if r.get("avg_ready_replicas") is not None else float("inf")),
        ),
    )
    with open(study_root / "leaderboard.json", "w", encoding="utf-8") as f:
        json.dump(leaderboard, f, indent=2)

    print(json.dumps({
        "study_root": str(study_root),
        "candidate_run_dirs": len(candidate_run_dirs),
        "runs_included": len(run_rows),
        "runs_excluded": len(excluded_rows),
        "all_runs_csv": str(study_root / "all_runs.csv"),
        "aggregate_csv": str(study_root / "aggregated_by_policy_scenario.csv"),
        "excluded_runs_csv": str(study_root / "excluded_runs.csv"),
        "leaderboard_json": str(study_root / "leaderboard.json"),
    }, indent=2))


if __name__ == "__main__":
    main()
