#!/usr/bin/env python3
"""Build a training dataset from past policy-evaluation runs.

Walks the results tree produced by run_policy_eval.sh, reads each run's
system_metrics.csv (+ requests.csv), engineers robust features via features.py,
labels each row with a queue-theory-informed oracle target, and writes a
single consolidated training CSV.

Usage:
    python scripts/ml_autoscaler/collect_training_data.py \
        --results-root results/policy_eval \
        --model-key qwen25_05b_instruct \
        --output data/ml_training.csv \
        [--min-replicas 1] [--max-replicas 5]
"""
from features import (
    FEATURE_COLUMNS,
    PRIOR_COLUMN,
    RESIDUAL_COLUMN,
    compute_features,
    compute_little_law_prior,
    compute_optimal_replicas,
    raw_row_to_dict,
    safe_float,
)
import argparse
import csv
import json
import math
from pathlib import Path
from typing import Any, Dict, List, Optional
import sys
import os
sys.path.insert(0, os.path.dirname(__file__))

LABEL_COLUMN = "target_replicas"
META_COLUMNS = ["run_dir", "policy_key", "scenario", "timestamp"]


def load_metrics_csv(path: Path) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    if not path.exists():
        return rows
    with open(path, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(row)
    return rows


def load_json_safe(path: Path) -> Optional[Dict[str, Any]]:
    if not path.exists():
        return None
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def load_requests_csv(path: Path) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    if not path.exists():
        return rows
    with open(path, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(row)
    return rows


def percentile(values: List[float], p: float) -> Optional[float]:
    if not values:
        return None
    vals = sorted(values)
    if len(vals) == 1:
        return vals[0]
    k = (len(vals) - 1) * (p / 100.0)
    lo = int(math.floor(k))
    hi = int(math.ceil(k))
    if lo == hi:
        return vals[lo]
    return vals[lo] * (hi - k) + vals[hi] * (k - lo)


def quantile(values: List[float], q: float) -> Optional[float]:
    if not values:
        return None
    return percentile(values, q * 100.0)


def estimate_tokens_from_chars(char_count: float, chars_per_token: float) -> float:
    if chars_per_token <= 0:
        return 0.0
    return max(0.0, char_count / chars_per_token)


def parse_request_rows(
    request_rows: List[Dict[str, Any]],
    chars_per_token: float,
) -> List[Dict[str, float]]:
    parsed: List[Dict[str, float]] = []
    for row in request_rows:
        ok_raw = str(row.get("ok", "")).strip().lower()
        ok = ok_raw in {"1", "true", "yes"}
        if not ok:
            continue

        start_ts = safe_float(row.get("start_ts"))
        end_ts = safe_float(row.get("end_ts"))
        latency_ms = safe_float(row.get("latency_ms"))
        ttft_ms = safe_float(row.get("ttft_ms"))
        prompt_chars = safe_float(row.get("prompt_chars"))
        output_chars = safe_float(row.get("output_chars"))
        if end_ts <= 0 or latency_ms <= 0:
            continue

        prompt_tokens = estimate_tokens_from_chars(
            prompt_chars, chars_per_token)
        output_tokens = estimate_tokens_from_chars(
            output_chars, chars_per_token)
        generation_ms = max(0.0, latency_ms - ttft_ms)
        itl_ms = generation_ms / max(1.0, output_tokens)

        parsed.append(
            {
                "start_ts": start_ts,
                "end_ts": end_ts,
                "prompt_tokens": prompt_tokens,
                "output_tokens": output_tokens,
                "ttft_ms": max(0.0, ttft_ms),
                "itl_ms": max(0.0, itl_ms),
            }
        )

    parsed.sort(key=lambda x: x["end_ts"])
    return parsed


def requests_in_window(
    requests: List[Dict[str, float]],
    start_ts: float,
    end_ts: float,
) -> List[Dict[str, float]]:
    return [r for r in requests if start_ts < r["end_ts"] <= end_ts]


def winsorize_rows(
    rows: List[Dict[str, Any]],
    columns: List[str],
    lower_q: float,
    upper_q: float,
) -> None:
    if not rows or lower_q <= 0.0 and upper_q >= 1.0:
        return
    for col in columns:
        vals = [safe_float(r.get(col)) for r in rows]
        lo = quantile(vals, lower_q)
        hi = quantile(vals, upper_q)
        if lo is None or hi is None:
            continue
        if lo > hi:
            lo, hi = hi, lo
        for r in rows:
            v = safe_float(r.get(col))
            r[col] = max(lo, min(hi, v))


def process_run(
    run_dir: Path,
    min_replicas: int,
    max_replicas: int,
    window_seconds: float,
    min_window_requests: int,
    chars_per_token: float,
    target_utilization_per_pod: float,
    assumed_input_tokens_per_request: float,
    assumed_output_tokens_per_request: float,
    min_latency_ms: float,
    ttft_slo_ms: float,
    itl_slo_ms: float,
    queue_depth_soft_target: float,
    queue_depth_per_replica: float,
    kv_cache_hit_rate_floor: float,
    low_output_tps_threshold: float,
) -> List[Dict[str, Any]]:
    metrics_path = run_dir / "system_metrics.csv"
    requests_path = run_dir / "requests.csv"
    metadata_path = run_dir / "metadata.json"
    if not metrics_path.exists() or not metadata_path.exists():
        return []
    metadata = load_json_safe(metadata_path) or {}
    policy_key = metadata.get("policy_key", "unknown")
    scenario = metadata.get("scenario", "unknown")
    raw_rows = load_metrics_csv(metrics_path)
    request_rows = load_requests_csv(requests_path)
    if not raw_rows:
        return []

    parsed_requests = parse_request_rows(
        request_rows, chars_per_token=chars_per_token)
    global_ttft = percentile([r["ttft_ms"]
                             for r in parsed_requests], 95) or ttft_slo_ms
    global_itl = percentile([r["itl_ms"]
                            for r in parsed_requests], 95) or itl_slo_ms

    output_rows: List[Dict[str, Any]] = []

    prev_ts: Optional[float] = None
    prev_signals: Dict[str, float] = {
        "input_tokens_per_sec": 0.0,
        "output_tokens_per_sec": 0.0,
        "p95_ttft_ms": global_ttft,
        "p95_itl_ms": global_itl,
    }

    for raw in raw_rows:
        ts = safe_float(raw.get("timestamp"))
        if ts <= 0.0:
            continue

        dt = max(
            1.0, ts - prev_ts) if prev_ts is not None else max(1.0, window_seconds)
        w = max(window_seconds, dt)
        w_start = ts - w
        w_requests = requests_in_window(parsed_requests, w_start, ts)

        req_input_tps = sum(r["prompt_tokens"]
                            for r in w_requests) / w if w > 0 else 0.0
        req_output_tps = sum(r["output_tokens"]
                             for r in w_requests) / w if w > 0 else 0.0
        req_ttft_p95 = percentile([r["ttft_ms"] for r in w_requests], 95)
        req_itl_p95 = percentile([r["itl_ms"] for r in w_requests], 95)

        prompt_tps_metric = safe_float(raw.get("prompt_tokens_per_sec"))
        output_tps_metric = safe_float(raw.get("output_tokens_per_sec"))
        if output_tps_metric <= 0.0:
            output_tps_metric = safe_float(
                raw.get("generation_tokens_per_sec"))
        if output_tps_metric <= 0.0:
            output_tps_metric = safe_float(
                raw.get("avg_generation_throughput_toks_per_s"))

        p95_ttft_metric = safe_float(raw.get("p95_ttft_ms"))
        p95_itl_metric = safe_float(raw.get("p95_itl_ms"))

        use_req_window = len(w_requests) >= min_window_requests

        input_tps = prompt_tps_metric if prompt_tps_metric > 0 else (
            req_input_tps if use_req_window else prev_signals["input_tokens_per_sec"])
        output_tps = output_tps_metric if output_tps_metric > 0 else (
            req_output_tps if use_req_window else prev_signals["output_tokens_per_sec"])
        ttft_p95 = p95_ttft_metric if p95_ttft_metric > 0 else (req_ttft_p95 if (
            use_req_window and req_ttft_p95 is not None) else prev_signals["p95_ttft_ms"])
        itl_p95 = p95_itl_metric if p95_itl_metric > 0 else (req_itl_p95 if (
            use_req_window and req_itl_p95 is not None) else prev_signals["p95_itl_ms"])

        merged_row: Dict[str, Any] = dict(raw)
        merged_row["input_tokens_per_sec"] = max(0.0, input_tps)
        merged_row["output_tokens_per_sec"] = max(0.0, output_tps)
        merged_row["p95_ttft_ms"] = max(0.0, ttft_p95)
        merged_row["p95_itl_ms"] = max(0.0, itl_p95)
        if merged_row.get("queue_depth") in (None, ""):
            merged_row["queue_depth"] = safe_float(
                merged_row.get("num_requests_waiting"))

        norm = raw_row_to_dict(merged_row)
        feats = compute_features(norm)
        prior = compute_little_law_prior(
            row=norm,
            min_replicas=min_replicas,
            max_replicas=max_replicas,
            target_utilization_per_pod=target_utilization_per_pod,
            assumed_input_tokens_per_request=assumed_input_tokens_per_request,
            assumed_output_tokens_per_request=assumed_output_tokens_per_request,
            min_latency_ms=min_latency_ms,
        )
        label = compute_optimal_replicas(
            norm,
            min_replicas=min_replicas,
            max_replicas=max_replicas,
            target_utilization_per_pod=target_utilization_per_pod,
            assumed_input_tokens_per_request=assumed_input_tokens_per_request,
            assumed_output_tokens_per_request=assumed_output_tokens_per_request,
            min_latency_ms=min_latency_ms,
            ttft_slo_ms=ttft_slo_ms,
            itl_slo_ms=itl_slo_ms,
            queue_depth_soft_target=queue_depth_soft_target,
            queue_depth_per_replica=queue_depth_per_replica,
            kv_cache_hit_rate_floor=kv_cache_hit_rate_floor,
            low_output_tps_threshold=low_output_tps_threshold,
        )
        residual = float(label - prior)

        row: Dict[str, Any] = {}
        for col, val in zip(META_COLUMNS, [str(run_dir), policy_key, scenario, raw.get("timestamp", "")]):
            row[col] = val
        for col, val in zip(FEATURE_COLUMNS, feats):
            row[col] = val
        row[PRIOR_COLUMN] = prior
        row[RESIDUAL_COLUMN] = residual
        row[LABEL_COLUMN] = label
        row["window_requests_count"] = len(w_requests)
        row["window_seconds"] = w
        output_rows.append(row)

        prev_ts = ts
        prev_signals = {
            "input_tokens_per_sec": merged_row["input_tokens_per_sec"],
            "output_tokens_per_sec": merged_row["output_tokens_per_sec"],
            "p95_ttft_ms": merged_row["p95_ttft_ms"],
            "p95_itl_ms": merged_row["p95_itl_ms"],
        }

    return output_rows


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Build ML training data from policy eval runs.")
    ap.add_argument("--results-root", required=True,
                    help="Root results directory (e.g. results/policy_eval)")
    ap.add_argument("--model-key", required=True,
                    help="Model key subdirectory to scan")
    ap.add_argument("--output", required=True, help="Output CSV path")
    ap.add_argument("--min-replicas", type=int, default=1)
    ap.add_argument("--max-replicas", type=int, default=5)
    ap.add_argument("--window-seconds", type=float, default=30.0,
                    help="Request-feature aggregation window")
    ap.add_argument("--min-window-requests", type=int, default=3,
                    help="Min request count to trust window percentiles")
    ap.add_argument("--chars-per-token", type=float, default=4.0,
                    help="Approx chars->token conversion factor")
    ap.add_argument("--winsor-lower", type=float, default=0.01,
                    help="Lower quantile for winsorization")
    ap.add_argument("--winsor-upper", type=float, default=0.99,
                    help="Upper quantile for winsorization")
    ap.add_argument("--target-utilization-per-pod", type=float, default=0.75)
    ap.add_argument("--assumed-input-tokens-per-request",
                    type=float, default=256.0)
    ap.add_argument("--assumed-output-tokens-per-request",
                    type=float, default=128.0)
    ap.add_argument("--min-latency-ms", type=float, default=50.0)
    ap.add_argument("--ttft-slo-ms", type=float, default=1800.0)
    ap.add_argument("--itl-slo-ms", type=float, default=140.0)
    ap.add_argument("--queue-depth-soft-target", type=float, default=2.0)
    ap.add_argument("--queue-depth-per-replica", type=float, default=4.0)
    ap.add_argument("--kv-cache-hit-rate-floor", type=float, default=0.45)
    ap.add_argument("--low-output-tps-threshold", type=float, default=5.0)
    args = ap.parse_args()
    model_root = Path(args.results_root) / args.model_key
    if not model_root.exists():
        print(f"Model root not found: {model_root}")
        sys.exit(1)
    all_rows: List[Dict[str, Any]] = []
    run_dirs = sorted(model_root.glob("*/*/metadata.json"))
    print(f"Found {len(run_dirs)} runs under {model_root}")
    for md_path in run_dirs:
        run_dir = md_path.parent
        rows = process_run(
            run_dir=run_dir,
            min_replicas=args.min_replicas,
            max_replicas=args.max_replicas,
            window_seconds=args.window_seconds,
            min_window_requests=args.min_window_requests,
            chars_per_token=args.chars_per_token,
            target_utilization_per_pod=args.target_utilization_per_pod,
            assumed_input_tokens_per_request=args.assumed_input_tokens_per_request,
            assumed_output_tokens_per_request=args.assumed_output_tokens_per_request,
            min_latency_ms=args.min_latency_ms,
            ttft_slo_ms=args.ttft_slo_ms,
            itl_slo_ms=args.itl_slo_ms,
            queue_depth_soft_target=args.queue_depth_soft_target,
            queue_depth_per_replica=args.queue_depth_per_replica,
            kv_cache_hit_rate_floor=args.kv_cache_hit_rate_floor,
            low_output_tps_threshold=args.low_output_tps_threshold,
        )
        if rows:
            all_rows.extend(rows)
            print(f"  {run_dir.name}: {len(rows)} samples")
    if not all_rows:
        print("No training samples found. Run policy evaluations first.")
        sys.exit(1)
    winsorize_rows(
        all_rows,
        columns=FEATURE_COLUMNS,
        lower_q=max(0.0, min(0.49, args.winsor_lower)),
        upper_q=min(1.0, max(0.51, args.winsor_upper)),
    )

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = META_COLUMNS + FEATURE_COLUMNS + \
        [PRIOR_COLUMN, RESIDUAL_COLUMN, LABEL_COLUMN,
            "window_requests_count", "window_seconds"]
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(all_rows)
    print(f"Wrote {len(all_rows)} training samples to {out_path}")


if __name__ == "__main__":
    main()
