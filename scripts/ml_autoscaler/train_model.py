#!/usr/bin/env python3
"""Train a queue-theory-informed residual Gradient Boosted Tree model.

Reads training CSV from collect_training_data.py, computes a Little's Law prior,
and trains a GBT regressor to predict residual replica corrections.

Usage:
    python scripts/ml_autoscaler/train_model.py \
        --training-csv data/ml_training.csv \
        --output models/ml_autoscaler.joblib \
        [--test-split 0.2] [--n-estimators 120] [--max-depth 4]
"""
from features import FEATURE_COLUMNS, PRIOR_COLUMN, RESIDUAL_COLUMN
import argparse
import csv
import json
import math
import sys
from pathlib import Path
from typing import Any, Dict, List
import os
sys.path.insert(0, os.path.dirname(__file__))

LABEL_COLUMN = "target_replicas"


def load_csv(path: str) -> List[Dict[str, Any]]:
    with open(path, "r", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def main() -> None:
    ap = argparse.ArgumentParser(description="Train ML autoscaler model.")
    ap.add_argument("--training-csv", required=True,
                    help="Path to training CSV")
    ap.add_argument("--output", required=True,
                    help="Path for serialised model (.joblib)")
    ap.add_argument("--test-split", type=float, default=0.2,
                    help="Fraction held out for evaluation")
    ap.add_argument("--n-estimators", type=int, default=120,
                    help="Number of boosting rounds")
    ap.add_argument("--max-depth", type=int, default=4, help="Max tree depth")
    ap.add_argument("--learning-rate", type=float,
                    default=0.1, help="Boosting learning rate")
    ap.add_argument("--min-samples-leaf", type=int,
                    default=5, help="Min samples per leaf")
    ap.add_argument("--min-replicas", type=int, default=1)
    ap.add_argument("--max-replicas", type=int, default=5)
    ap.add_argument("--target-utilization-per-pod", type=float, default=0.75)
    ap.add_argument("--assumed-input-tokens-per-request",
                    type=float, default=256.0)
    ap.add_argument("--assumed-output-tokens-per-request",
                    type=float, default=128.0)
    ap.add_argument("--min-latency-ms", type=float, default=50.0)
    args = ap.parse_args()
    try:
        import numpy as np
        from sklearn.ensemble import GradientBoostingRegressor
        from sklearn.model_selection import train_test_split
        from sklearn.metrics import mean_absolute_error, mean_squared_error
        import joblib
    except ImportError as e:
        print(f"Missing dependency: {e}")
        print("Install with: pip install scikit-learn joblib numpy")
        sys.exit(1)
    rows = load_csv(args.training_csv)
    if not rows:
        print("Training CSV is empty.")
        sys.exit(1)
    X = []
    y_residual = []
    y_target = []
    priors = []
    for row in rows:
        feat_vec = [float(row[col]) for col in FEATURE_COLUMNS]
        prior = float(row.get(PRIOR_COLUMN, 0.0))
        label = int(float(row[LABEL_COLUMN]))
        residual = float(row.get(RESIDUAL_COLUMN, label - prior))
        X.append(feat_vec)
        priors.append(prior)
        y_target.append(label)
        y_residual.append(residual)
    X = np.array(X, dtype=np.float32)
    y_target = np.array(y_target, dtype=np.int32)
    y_residual = np.array(y_residual, dtype=np.float32)
    priors = np.array(priors, dtype=np.float32)

    print(f"Dataset: {X.shape[0]} samples, {X.shape[1]} features")
    print(
        f"Label distribution: {dict(zip(*np.unique(y_target, return_counts=True)))}")

    indices = np.arange(X.shape[0])
    train_idx, test_idx = train_test_split(
        indices,
        test_size=args.test_split,
        random_state=42,
        stratify=y_target if len(set(y_target)) > 1 else None,
    )
    X_train = X[train_idx]
    X_test = X[test_idx]
    y_train_resid = y_residual[train_idx]
    y_test_target = y_target[test_idx]
    prior_test = priors[test_idx]

    print(f"Train: {len(X_train)}, Test: {len(X_test)}")

    reg = GradientBoostingRegressor(
        n_estimators=args.n_estimators,
        max_depth=args.max_depth,
        learning_rate=args.learning_rate,
        min_samples_leaf=args.min_samples_leaf,
        random_state=42,
    )

    reg.fit(X_train, y_train_resid)
    residual_pred = reg.predict(X_test)
    combined_pred = np.ceil(prior_test + residual_pred)
    combined_pred = np.clip(combined_pred, args.min_replicas,
                            args.max_replicas).astype(np.int32)

    mae = mean_absolute_error(y_test_target, combined_pred)
    rmse = math.sqrt(mean_squared_error(y_test_target, combined_pred))
    exact_acc = float(np.mean(combined_pred == y_test_target))
    within_one = float(np.mean(np.abs(combined_pred - y_test_target) <= 1))

    print(f"\nReplica MAE: {mae:.4f}")
    print(f"Replica RMSE: {rmse:.4f}")
    print(f"Exact-match accuracy: {exact_acc:.4f}")
    print(f"Within +/-1 replica: {within_one:.4f}")

    importances = sorted(
        zip(FEATURE_COLUMNS, reg.feature_importances_),
        key=lambda x: x[1],
        reverse=True,
    )
    print("Feature importances:")
    for name, imp in importances:
        print(f"  {name:30s} {imp:.4f}")

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    model_bundle = {
        "model_type": "queue_theory_residual_gbt",
        "residual_model": reg,
        "features": FEATURE_COLUMNS,
        "label": LABEL_COLUMN,
        "prior_column": PRIOR_COLUMN,
        "residual_column": RESIDUAL_COLUMN,
        "min_replicas": args.min_replicas,
        "max_replicas": args.max_replicas,
        "prior_params": {
            "target_utilization_per_pod": args.target_utilization_per_pod,
            "assumed_input_tokens_per_request": args.assumed_input_tokens_per_request,
            "assumed_output_tokens_per_request": args.assumed_output_tokens_per_request,
            "min_latency_ms": args.min_latency_ms,
        },
    }
    joblib.dump(model_bundle, out_path)

    size_kb = out_path.stat().st_size / 1024
    print(f"\nModel saved to {out_path} ({size_kb:.1f} KB)")
    meta = {
        "model_path": str(out_path),
        "model_type": "queue_theory_residual_gbt",
        "features": FEATURE_COLUMNS,
        "n_estimators": args.n_estimators,
        "max_depth": args.max_depth,
        "learning_rate": args.learning_rate,
        "training_samples": len(X_train),
        "test_samples": len(X_test),
        "metrics": {
            "replica_mae": float(mae),
            "replica_rmse": float(rmse),
            "exact_match_accuracy": float(exact_acc),
            "within_one_replica_accuracy": float(within_one),
        },
        "label_distribution": {str(k): int(v) for k, v in zip(*np.unique(y_target, return_counts=True))},
        "feature_importances": {name: float(imp) for name, imp in importances},
        "prior_params": model_bundle["prior_params"],
        "clamp": {
            "min_replicas": args.min_replicas,
            "max_replicas": args.max_replicas,
        },
    }
    meta_path = out_path.with_suffix(".meta.json")
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2)
    print(f"Metadata saved to {meta_path}")


if __name__ == "__main__":
    main()
