#!/usr/bin/env python3
"""Train a lightweight Gradient Boosted Tree to predict optimal replica count.

Reads the consolidated training CSV (from collect_training_data.py), fits a
GradientBoostingClassifier, evaluates hold-out accuracy, and serialises the
model to a compact joblib file for deployment.

Usage:
    python scripts/ml_autoscaler/train_model.py \
        --training-csv data/ml_training.csv \
        --output models/ml_autoscaler.joblib \
        [--test-split 0.2] [--n-estimators 120] [--max-depth 4]
"""
import argparse
import csv
import json
import sys
from pathlib import Path
from typing import Any, Dict, List
import os
sys.path.insert(0, os.path.dirname(__file__))
from features import FEATURE_COLUMNS

LABEL_COLUMN = "target_replicas"

def load_csv(path: str) -> List[Dict[str, Any]]:
    with open(path, "r", encoding="utf-8") as f:
        return list(csv.DictReader(f))

def main() -> None:
    ap = argparse.ArgumentParser(description="Train ML autoscaler model.")
    ap.add_argument("--training-csv", required=True, help="Path to training CSV")
    ap.add_argument("--output", required=True, help="Path for serialised model (.joblib)")
    ap.add_argument("--test-split", type=float, default=0.2, help="Fraction held out for evaluation")
    ap.add_argument("--n-estimators", type=int, default=120, help="Number of boosting rounds")
    ap.add_argument("--max-depth", type=int, default=4, help="Max tree depth")
    ap.add_argument("--learning-rate", type=float, default=0.1, help="Boosting learning rate")
    ap.add_argument("--min-samples-leaf", type=int, default=5, help="Min samples per leaf")
    args = ap.parse_args()
    try:
        import numpy as np
        from sklearn.ensemble import GradientBoostingClassifier
        from sklearn.model_selection import train_test_split
        from sklearn.metrics import classification_report, accuracy_score
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
    y = []
    for row in rows:
        feat_vec = [float(row[col]) for col in FEATURE_COLUMNS]
        label = int(float(row[LABEL_COLUMN]))
        X.append(feat_vec)
        y.append(label)
    X = np.array(X, dtype=np.float32)
    y = np.array(y, dtype=np.int32)
    print(f"Dataset: {X.shape[0]} samples, {X.shape[1]} features")
    print(f"Label distribution: {dict(zip(*np.unique(y, return_counts=True)))}")
    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=args.test_split, random_state=42, stratify=y if len(set(y)) > 1 else None,
    )
    print(f"Train: {len(X_train)}, Test: {len(X_test)}")
    clf = GradientBoostingClassifier(
        n_estimators=args.n_estimators,
        max_depth=args.max_depth,
        learning_rate=args.learning_rate,
        min_samples_leaf=args.min_samples_leaf,
        random_state=42,
    )
    clf.fit(X_train, y_train)
    y_pred = clf.predict(X_test)
    acc = accuracy_score(y_test, y_pred)
    print(f"\nTest accuracy: {acc:.4f}")
    print("\nClassification report:")
    print(classification_report(y_test, y_pred, zero_division=0))
    importances = sorted(
        zip(FEATURE_COLUMNS, clf.feature_importances_),
        key=lambda x: x[1],
        reverse=True,
    )
    print("Feature importances:")
    for name, imp in importances:
        print(f"  {name:30s} {imp:.4f}")
    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    joblib.dump({"model": clf, "features": FEATURE_COLUMNS, "label": LABEL_COLUMN}, out_path)
    size_kb = out_path.stat().st_size / 1024
    print(f"\nModel saved to {out_path} ({size_kb:.1f} KB)")
    meta = {
        "model_path": str(out_path),
        "features": FEATURE_COLUMNS,
        "n_estimators": args.n_estimators,
        "max_depth": args.max_depth,
        "learning_rate": args.learning_rate,
        "training_samples": len(X_train),
        "test_samples": len(X_test),
        "test_accuracy": acc,
        "label_distribution": {str(k): int(v) for k, v in zip(*np.unique(y, return_counts=True))},
        "feature_importances": {name: float(imp) for name, imp in importances},
    }
    meta_path = out_path.with_suffix(".meta.json")
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2)
    print(f"Metadata saved to {meta_path}")

if __name__ == "__main__":
    main()
