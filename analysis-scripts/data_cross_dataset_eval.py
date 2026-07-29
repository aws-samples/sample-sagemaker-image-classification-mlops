#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import argparse
import json
import os
import random
import sys
import time
from pathlib import Path

import boto3
import numpy as np
from botocore.exceptions import ClientError
from PIL import Image

IMG_SIZE = 224
SUPPORTED_EXTS = ("*.jpg", "*.jpeg", "*.png", "*.bmp", "*.tif", "*.tiff")


def collect_images(data_dir: Path, class_name: str, max_n: int | None) -> list[Path]:
    class_dir = data_dir / class_name
    if not class_dir.exists():
        print(f"❌ Missing class directory: {class_dir}")
        return []
    files: list[Path] = []
    for ext in SUPPORTED_EXTS:
        files.extend(class_dir.rglob(ext))
    # Stable shuffle (seed) so re-runs produce identical samples
    random.Random(42).shuffle(files)  # nosec B311 - seeded PRNG for reproducible sampling, not security
    if max_n is not None:
        files = files[:max_n]
    return files


def preprocess_image(path: Path) -> np.ndarray:
    img = Image.open(path).convert("RGB").resize((IMG_SIZE, IMG_SIZE))
    return np.asarray(img, dtype=np.float32) / 255.0


def invoke_endpoint(runtime, endpoint_name: str, image: np.ndarray) -> float:
    resp = runtime.invoke_endpoint(
        EndpointName=endpoint_name,
        ContentType="application/json",
        Body=json.dumps({"instances": [image.tolist()]}),
    )
    payload = json.loads(resp["Body"].read().decode())
    # Model returns [[score]] - score is probability of malignant
    return float(payload["predictions"][0][0])


def compute_metrics(y_true: list[int], y_pred: list[int], y_score: list[float]) -> dict:
    # Confusion matrix: rows=true, cols=predicted, order [benign=0, malignant=1]
    tp = sum(1 for t, p in zip(y_true, y_pred) if t == 1 and p == 1)
    tn = sum(1 for t, p in zip(y_true, y_pred) if t == 0 and p == 0)
    fp = sum(1 for t, p in zip(y_true, y_pred) if t == 0 and p == 1)
    fn = sum(1 for t, p in zip(y_true, y_pred) if t == 1 and p == 0)

    total = len(y_true)
    accuracy = (tp + tn) / total if total else 0.0
    precision = tp / (tp + fp) if (tp + fp) else 0.0
    recall = tp / (tp + fn) if (tp + fn) else 0.0
    f1 = 2 * precision * recall / (precision + recall) if (precision + recall) else 0.0
    specificity = tn / (tn + fp) if (tn + fp) else 0.0

    benign_total = tn + fp
    malignant_total = tp + fn
    benign_acc = tn / benign_total if benign_total else 0.0
    malignant_acc = tp / malignant_total if malignant_total else 0.0

    # Mean confidence per class (distance from 0.5 decision boundary)
    benign_conf = [abs(s - 0.5) * 2 for s, t in zip(y_score, y_true) if t == 0]
    malignant_conf = [abs(s - 0.5) * 2 for s, t in zip(y_score, y_true) if t == 1]

    return {
        "total_samples": total,
        "accuracy": round(accuracy, 4),
        "precision_malignant": round(precision, 4),
        "recall_malignant": round(recall, 4),
        "f1_malignant": round(f1, 4),
        "specificity_benign": round(specificity, 4),
        "benign_accuracy": round(benign_acc, 4),
        "malignant_accuracy": round(malignant_acc, 4),
        "confusion_matrix": {
            "true_negative": tn,
            "false_positive": fp,
            "false_negative": fn,
            "true_positive": tp,
        },
        "mean_confidence": {
            "benign": round(float(np.mean(benign_conf)), 4) if benign_conf else 0.0,
            "malignant": round(float(np.mean(malignant_conf)), 4) if malignant_conf else 0.0,
        },
    }


def print_summary(dataset_name: str, endpoint_name: str, metrics: dict, duration_s: float):
    cm = metrics["confusion_matrix"]
    print()
    print("=" * 70)
    print("  Cross-Dataset Evaluation Report")
    print("=" * 70)
    print(f"  Dataset:        {dataset_name}")
    print(f"  Endpoint:       {endpoint_name}")
    print(f"  Samples tested: {metrics['total_samples']}")
    print(
        f"  Duration:       {duration_s:.1f}s "
        f"({duration_s / max(metrics['total_samples'], 1):.2f}s/sample)"
    )
    print("-" * 70)
    print(f"  Overall Accuracy:     {metrics['accuracy']:.2%}")
    print(f"  Precision (malig):    {metrics['precision_malignant']:.2%}")
    print(
        f"  Recall    (malig):    {metrics['recall_malignant']:.2%}  "
        "← sensitivity; critical for healthcare"
    )
    print(f"  F1 Score  (malig):    {metrics['f1_malignant']:.2%}")
    print(f"  Specificity (benign): {metrics['specificity_benign']:.2%}")
    print("-" * 70)
    print("  Per-class accuracy:")
    print(f"    benign:    {metrics['benign_accuracy']:.2%}")
    print(f"    malignant: {metrics['malignant_accuracy']:.2%}")
    print("-" * 70)
    print("  Confusion matrix:")
    print("                   Predicted")
    print("                   benign   malignant")
    print(f"    True benign    {cm['true_negative']:>6}   {cm['false_positive']:>6}  (FP)")
    print(
        f"    True malignant {cm['false_negative']:>6}   {cm['true_positive']:>6}  (FN above → missed positive)"
    )
    print("-" * 70)
    print("  Mean model confidence:")
    print(f"    on benign samples:    {metrics['mean_confidence']['benign']:.2%}")
    print(f"    on malignant samples: {metrics['mean_confidence']['malignant']:.2%}")
    print("=" * 70)


def interpret_results(metrics: dict, in_dist_baseline: float = 0.97):
    """Give a verdict on whether the model generalizes."""
    acc = metrics["accuracy"]
    drop = in_dist_baseline - acc
    print()
    print("📋 Generalization verdict:")
    if drop < 0.05:
        print("  ✅ EXCELLENT: accuracy held within 5pp of in-distribution baseline")
        print(f"     (dropped only {drop * 100:.1f}pp from {in_dist_baseline:.0%} to {acc:.0%})")
        print("     Model appears to learn generalizable features.")
    elif drop < 0.15:
        print(f"  ⚠️  ACCEPTABLE: {drop * 100:.1f}pp drop from {in_dist_baseline:.0%} to {acc:.0%}")
        print("     Typical for medical imaging cross-dataset transfer.")
        print("     Adding this dataset to training would likely help.")
    else:
        print(f"  ❌ POOR: {drop * 100:.1f}pp drop from {in_dist_baseline:.0%} to {acc:.0%}")
        print("     Strong evidence of overfitting to training distribution.")
        print("     Recommend retraining with diverse multi-source data.")

    recall = metrics["recall_malignant"]
    if recall < 0.85:
        print()
        print(f"  ⚠️  Sensitivity concern: missed {(1 - recall) * 100:.1f}% of malignant cases.")
        print("     In healthcare, a missed positive is the highest-cost error.")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Cross-dataset evaluation for the deployed ensemble endpoint."
    )
    parser.add_argument(
        "--data-dir",
        type=Path,
        required=True,
        help="Directory containing breast_benign/ and breast_malignant/",
    )
    parser.add_argument(
        "--endpoint",
        default=None,
        help="SageMaker endpoint name (default: env SAGEMAKER_ENDPOINT_NAME "
        "or 'medical-image-classification-endpoint')",
    )
    parser.add_argument("--region", default=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))
    parser.add_argument(
        "--max-per-class",
        type=int,
        default=500,
        help="Max images per class to evaluate (default: 500)",
    )
    parser.add_argument(
        "--baseline",
        type=float,
        default=0.97,
        help="In-distribution accuracy baseline for verdict (default: 0.97)",
    )
    args = parser.parse_args()

    endpoint_name = (
        args.endpoint
        or os.environ.get("SAGEMAKER_ENDPOINT_NAME")
        or "medical-image-classification-endpoint"
    )

    if not args.data_dir.exists():
        print(f"❌ Data directory not found: {args.data_dir}")
        return 1

    benign = collect_images(args.data_dir, "breast_benign", args.max_per_class)
    malignant = collect_images(args.data_dir, "breast_malignant", args.max_per_class)

    if not benign or not malignant:
        print("❌ No images found. Expected breast_benign/ and breast_malignant/ subfolders.")
        return 1

    print(f"🧪 Evaluating endpoint '{endpoint_name}' on out-of-distribution dataset")
    print(f"   Data dir:  {args.data_dir}")
    print(f"   Benign:    {len(benign)} images")
    print(f"   Malignant: {len(malignant)} images")
    print()

    runtime = boto3.client("sagemaker-runtime", region_name=args.region)

    y_true: list[int] = []
    y_pred: list[int] = []
    y_score: list[float] = []
    errors = 0

    samples = [(p, 0) for p in benign] + [(p, 1) for p in malignant]
    random.Random(1).shuffle(samples)  # nosec B311 - seeded PRNG for reproducible sampling, not security

    t0 = time.time()
    for i, (path, label) in enumerate(samples, 1):
        try:
            img = preprocess_image(path)
            score = invoke_endpoint(runtime, endpoint_name, img)
            y_score.append(score)
            y_pred.append(1 if score > 0.5 else 0)
            y_true.append(label)
        except ClientError as e:
            errors += 1
            if errors <= 3:
                print(f"   ⚠️  Endpoint error on {path.name}: {e.response['Error']['Code']}")
        except (OSError, ValueError) as e:
            errors += 1
            if errors <= 3:
                print(f"   ⚠️  Image read error on {path.name}: {e}")

        if i % 50 == 0 or i == len(samples):
            running_acc = sum(1 for t, p in zip(y_true, y_pred) if t == p) / max(len(y_true), 1)
            print(f"   [{i}/{len(samples)}] running accuracy: {running_acc:.2%}")

    duration = time.time() - t0

    if not y_true:
        print("❌ No successful predictions - check endpoint status and data format.")
        return 1

    metrics = compute_metrics(y_true, y_pred, y_score)
    metrics["errors"] = errors

    print_summary(args.data_dir.name, endpoint_name, metrics, duration)
    interpret_results(metrics, in_dist_baseline=args.baseline)

    report_path = args.data_dir / "cross_dataset_report.json"
    report = {
        "dataset": str(args.data_dir),
        "endpoint": endpoint_name,
        "region": args.region,
        "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "baseline_accuracy": args.baseline,
        "metrics": metrics,
        "duration_seconds": round(duration, 2),
    }
    report_path.write_text(json.dumps(report, indent=2))
    print(f"\n📄 Report saved: {report_path}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
