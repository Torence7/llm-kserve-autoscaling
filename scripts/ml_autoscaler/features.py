"""Shared feature engineering for the ML-based autoscaler.

This module provides:
1) A queueing-theory prior based on Little's Law.
2) Residual learning labels used by train_model.py.
3) A stable, explicit feature schema used by both training and inference.
"""
import math
from typing import Any, Dict, List

FEATURE_COLUMNS = [
    "input_tokens_per_sec",
    "output_tokens_per_sec",
    "p95_ttft_ms",
    "p95_itl_ms",
    "kv_cache_hit_rate",
    "batch_size_avg",
    "queue_depth",
]

PRIOR_COLUMN = "little_law_prior_replicas"
RESIDUAL_COLUMN = "target_residual"


def safe_float(val: Any) -> float:
    if val is None:
        return 0.0
    try:
        v = float(val)
        return v if math.isfinite(v) else 0.0
    except (ValueError, TypeError):
        return 0.0


def clamp(val: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, val))


def _first_present(row: Dict[str, Any], keys: List[str], default: float = 0.0) -> float:
    for k in keys:
        if k in row and row.get(k) not in (None, ""):
            return safe_float(row.get(k))
    return default


def _normalise_ratio(value: float) -> float:
    """Normalize ratio metrics that may be emitted as [0,1] or [0,100]."""
    if value <= 0.0:
        return 0.0
    if value > 1.0:
        return clamp(value / 100.0, 0.0, 1.0)
    return clamp(value, 0.0, 1.0)


def raw_row_to_dict(row: Dict[str, Any]) -> Dict[str, float]:
    """Normalise a single CSV DictReader row to floats.

    Handles both new and legacy metric column names to keep old benchmark
    runs trainable.
    """
    waiting = _first_present(row, ["queue_depth", "num_requests_waiting"])
    running = _first_present(row, ["num_requests_running"])
    replicas = max(1.0, _first_present(
        row, ["ready_replicas", "current_replicas"], default=1.0))
    output_tps = _first_present(
        row,
        [
            "output_tokens_per_sec",
            "generation_tokens_per_sec",
            "avg_generation_throughput_toks_per_s",
        ],
    )
    input_tps = _first_present(
        row, ["input_tokens_per_sec", "prompt_tokens_per_sec"])
    p95_ttft_ms = _first_present(row, ["p95_ttft_ms", "ttft_p95_ms"])
    p95_itl_ms = _first_present(row, ["p95_itl_ms", "itl_p95_ms"])
    kv_hit = _normalise_ratio(_first_present(
        row, ["kv_cache_hit_rate"], default=0.0))
    batch_size_avg = _first_present(row, ["batch_size_avg"], default=0.0)
    if batch_size_avg <= 0.0:
        batch_size_avg = running / replicas if replicas > 0 else 0.0

    return {
        "input_tokens_per_sec": max(0.0, input_tps),
        "output_tokens_per_sec": max(0.0, output_tps),
        "p95_ttft_ms": max(0.0, p95_ttft_ms),
        "p95_itl_ms": max(0.0, p95_itl_ms),
        "kv_cache_hit_rate": kv_hit,
        "batch_size_avg": max(0.0, batch_size_avg),
        "queue_depth": max(0.0, waiting),
        "requests_running": max(0.0, running),
        "requests_waiting": max(0.0, waiting),
        "current_replicas": replicas,
        "kv_cache_usage_perc": _first_present(row, ["kv_cache_usage_perc"], default=0.0),
    }


def compute_features(
    current: Dict[str, float],
) -> List[float]:
    """Return ordered features for the residual model."""
    return [
        max(0.0, current["input_tokens_per_sec"]),
        max(0.0, current["output_tokens_per_sec"]),
        max(0.0, current["p95_ttft_ms"]),
        max(0.0, current["p95_itl_ms"]),
        clamp(current["kv_cache_hit_rate"], 0.0, 1.0),
        max(0.0, current["batch_size_avg"]),
        max(0.0, current["queue_depth"]),
    ]


def compute_little_law_prior(
    row: Dict[str, float],
    min_replicas: int,
    max_replicas: int,
    target_utilization_per_pod: float,
    assumed_input_tokens_per_request: float,
    assumed_output_tokens_per_request: float,
    min_latency_ms: float,
) -> int:
    """Estimate baseline replicas using Little's Law.

    Little's Law on requests:
      N ~= lambda * W
    where lambda is estimated request arrival rate and W is mean request
    latency. We derive lambda from token rates and convert to pods using
    target utilization per pod.
    """
    util = max(0.10, target_utilization_per_pod)
    input_tps = max(0.0, row.get("input_tokens_per_sec", 0.0))
    output_tps = max(0.0, row.get("output_tokens_per_sec", 0.0))
    queue_depth = max(0.0, row.get("queue_depth", 0.0))

    req_rate_from_input = input_tps / \
        max(1.0, assumed_input_tokens_per_request)
    req_rate_from_output = output_tps / \
        max(1.0, assumed_output_tokens_per_request)
    arrival_rate_req_s = max(req_rate_from_input, req_rate_from_output)

    ttft_ms = max(min_latency_ms, row.get("p95_ttft_ms", 0.0))
    itl_ms = max(0.0, row.get("p95_itl_ms", 0.0))
    mean_latency_s = (ttft_ms + itl_ms *
                      max(1.0, assumed_output_tokens_per_request)) / 1000.0

    if arrival_rate_req_s <= 0.0 and queue_depth <= 0.0:
        return min_replicas

    concurrent_demand = arrival_rate_req_s * mean_latency_s
    desired = int(math.ceil(concurrent_demand / util))
    return max(min_replicas, min(max_replicas, desired))


def compute_optimal_replicas(
    row: Dict[str, float],
    min_replicas: int = 1,
    max_replicas: int = 5,
    target_utilization_per_pod: float = 0.75,
    assumed_input_tokens_per_request: float = 256.0,
    assumed_output_tokens_per_request: float = 128.0,
    min_latency_ms: float = 50.0,
    ttft_slo_ms: float = 1800.0,
    itl_slo_ms: float = 140.0,
    queue_depth_soft_target: float = 2.0,
    queue_depth_per_replica: float = 4.0,
    kv_cache_hit_rate_floor: float = 0.45,
    low_output_tps_threshold: float = 5.0,
) -> int:
    """Build a robust training target with a Little's Law prior + residuals."""
    prior = compute_little_law_prior(
        row=row,
        min_replicas=min_replicas,
        max_replicas=max_replicas,
        target_utilization_per_pod=target_utilization_per_pod,
        assumed_input_tokens_per_request=assumed_input_tokens_per_request,
        assumed_output_tokens_per_request=assumed_output_tokens_per_request,
        min_latency_ms=min_latency_ms,
    )

    queue_depth = row.get("queue_depth", 0.0)
    p95_ttft_ms = row.get("p95_ttft_ms", 0.0)
    p95_itl_ms = row.get("p95_itl_ms", 0.0)
    kv_cache_hit_rate = clamp(row.get("kv_cache_hit_rate", 0.0), 0.0, 1.0)
    output_tps = row.get("output_tokens_per_sec", 0.0)

    residual = 0
    if queue_depth > queue_depth_soft_target:
        residual += int(math.ceil((queue_depth - queue_depth_soft_target) /
                        max(1.0, queue_depth_per_replica)))
    if p95_ttft_ms > ttft_slo_ms:
        residual += 1
    if p95_itl_ms > itl_slo_ms:
        residual += 1
    if kv_cache_hit_rate > 0 and kv_cache_hit_rate < kv_cache_hit_rate_floor:
        residual += 1

    if queue_depth <= 0.25 and p95_ttft_ms < 0.5 * ttft_slo_ms and output_tps < low_output_tps_threshold:
        residual -= 1

    desired = prior + residual
    return max(min_replicas, min(max_replicas, desired))
