"""Shared feature engineering for the ML-based autoscaler.

Converts raw Prometheus time-series rows (from collect_metrics.py CSVs) into
the feature vector consumed by both training and inference.
"""
import math
from typing import Any, Dict, List, Optional
FEATURE_COLUMNS = [
    "requests_running",
    "requests_waiting",
    "generation_throughput",
    "kv_cache_pct",
    "current_replicas",
    "requests_running_delta",
    "requests_waiting_delta",
    "throughput_delta",
    "kv_cache_delta",
    "waiting_per_replica",
    "running_per_replica",
    "throughput_per_replica",
    "load_intensity",
]

def safe_float(val: Any) -> float:
    if val is None:
        return 0.0
    try:
        v = float(val)
        return v if math.isfinite(v) else 0.0
    except (ValueError, TypeError):
        return 0.0

def raw_row_to_dict(row: Dict[str, Any]) -> Dict[str, float]:
    """Normalise a single CSV DictReader row to floats."""
    return {
        "requests_running": safe_float(row.get("num_requests_running")),
        "requests_waiting": safe_float(row.get("num_requests_waiting")),
        "generation_throughput": safe_float(row.get("avg_generation_throughput_toks_per_s")),
        "kv_cache_pct": safe_float(row.get("kv_cache_usage_perc")),
        "current_replicas": max(1.0, safe_float(row.get("ready_replicas"))),
    }

def compute_features(
    current: Dict[str, float],
    previous: Optional[Dict[str, float]] = None,
) -> List[float]:
    """Return an ordered feature vector from current + optional prior sample."""
    prev = previous or current
    replicas = max(current["current_replicas"], 1.0)
    running = current["requests_running"]
    waiting = current["requests_waiting"]
    throughput = current["generation_throughput"]
    kv = current["kv_cache_pct"]
    features = [
        running,
        waiting,
        throughput,
        kv,
        replicas,
        running - prev["requests_running"],
        waiting - prev["requests_waiting"],
        throughput - prev["generation_throughput"],
        kv - prev["kv_cache_pct"],
        waiting / replicas,
        running / replicas,
        throughput / replicas if replicas > 0 else 0.0,
        running + 2.0 * waiting,
    ]
    return features

def compute_optimal_replicas(
    row: Dict[str, float],
    min_replicas: int = 1,
    max_replicas: int = 5,
    target_running_per_replica: float = 2.0,
    waiting_weight: float = 1.5,
    kv_pressure_threshold: float = 70.0,
) -> int:
    """Heuristic labelling: what replica count *should* we have had?

    This is the "oracle" used to create training labels from historical data.
    It balances responsiveness (low waiting) with efficiency (few replicas).
    """
    running = row["requests_running"]
    waiting = row["requests_waiting"]
    kv = row["kv_cache_pct"]
    demand = running + waiting_weight * waiting
    desired_from_demand = math.ceil(demand / target_running_per_replica) if target_running_per_replica > 0 else 1
    kv_boost = 0
    if kv > kv_pressure_threshold:
        kv_boost = math.ceil((kv - kv_pressure_threshold) / 15.0)
    desired = desired_from_demand + kv_boost
    return max(min_replicas, min(max_replicas, desired))
