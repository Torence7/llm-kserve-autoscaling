#!/usr/bin/env python3
"""Build a training dataset from past policy-evaluation runs.

Walks the results tree produced by run_policy_eval.sh, reads each run's
system_metrics.csv, engineers features via features.py, labels each row with
the oracle replica target, and writes a single consolidated training CSV.

Usage:
    python scripts/ml_autoscaler/collect_training_data.py \
        --results-root results/policy_eval \
        --model-key qwen25_05b_instruct \
        --output data/ml_training.csv \
        [--min-replicas 1] [--max-replicas 5]
"""
import argparse
import csv
import json
from pathlib import Path
from typing import Any, Dict, List, Optional
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from features import (
    FEATURE_COLUMNS,
    compute_features,
    compute_optimal_replicas,
    raw_row_to_dict,
)

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

def process_run(
    run_dir: Path,
    min_replicas: int,
    max_replicas: int,
) -> List[Dict[str, Any]]:
    metrics_path = run_dir / "system_metrics.csv"
    metadata_path = run_dir / "metadata.json"
    if not metrics_path.exists() or not metadata_path.exists():
        return []
    metadata = load_json_safe(metadata_path) or {}
    policy_key = metadata.get("policy_key", "unknown")
    scenario = metadata.get("scenario", "unknown")
    raw_rows = load_metrics_csv(metrics_path)
    if not raw_rows:
        return []
    normalised = [raw_row_to_dict(r) for r in raw_rows]
    output_rows: List[Dict[str, Any]] = []
    prev = None
    for i, (raw, norm) in enumerate(zip(raw_rows, normalised)):
        feats = compute_features(norm, prev)
        label = compute_optimal_replicas(norm, min_replicas=min_replicas, max_replicas=max_replicas)
        row: Dict[str, Any] = {}
        for col, val in zip(META_COLUMNS, [str(run_dir), policy_key, scenario, raw.get("timestamp", "")]):
            row[col] = val
        for col, val in zip(FEATURE_COLUMNS, feats):
            row[col] = val
        row[LABEL_COLUMN] = label
        output_rows.append(row)
        prev = norm
    return output_rows

def main() -> None:
    ap = argparse.ArgumentParser(description="Build ML training data from policy eval runs.")
    ap.add_argument("--results-root", required=True, help="Root results directory (e.g. results/policy_eval)")
    ap.add_argument("--model-key", required=True, help="Model key subdirectory to scan")
    ap.add_argument("--output", required=True, help="Output CSV path")
    ap.add_argument("--min-replicas", type=int, default=1)
    ap.add_argument("--max-replicas", type=int, default=5)
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
        rows = process_run(run_dir, args.min_replicas, args.max_replicas)
        if rows:
            all_rows.extend(rows)
            print(f"  {run_dir.name}: {len(rows)} samples")
    if not all_rows:
        print("No training samples found. Run policy evaluations first.")
        sys.exit(1)
    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = META_COLUMNS + FEATURE_COLUMNS + [LABEL_COLUMN]
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(all_rows)
    print(f"Wrote {len(all_rows)} training samples to {out_path}")

if __name__ == "__main__":
    main()
