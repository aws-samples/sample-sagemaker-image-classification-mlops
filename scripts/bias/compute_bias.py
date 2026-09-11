#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Compute pre- and post-training fairness metrics with Fairlearn (Part 4).

Runs as a SageMaker Processing job after the evaluation step. Reads the
ensemble's per-image predictions plus a sensitive-feature column, computes
demographic-parity and equal-opportunity style metrics, and writes
``bias_metrics.json`` to the output path so the pipeline's fairness condition
can gate registration on it.

Fairlearn computes the metrics; AI Fairness 360 computes the same set if a
team prefers it.

Output schema (consumed by the pipeline's Std:JsonGet condition):

    {
      "demographic_parity_difference": 0.03,
      "equal_opportunity_difference": 0.04,
      "class_imbalance": 0.00,
      "difference_in_proportions_of_labels": 0.02,
      "per_group": { "<group>": {"n": 120, "selection_rate": 0.51, ...} },
      "sensitive_feature": "magnification",
      "threshold": 0.10,
      "passed": true
    }
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

# Fairlearn is the bias-metric engine. Guarded so the script fails with a clear
# message rather than a bare ImportError inside the processing container.
try:
    from fairlearn.metrics import (
        MetricFrame,
        demographic_parity_difference,
        equalized_odds_difference,
        selection_rate,
        true_positive_rate,
    )

    _FAIRLEARN_AVAILABLE = True
except ImportError:  # pragma: no cover
    _FAIRLEARN_AVAILABLE = False


DEFAULT_THRESHOLD = 0.10


def load_predictions(predictions_path: Path) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Read y_true, y_pred and the sensitive feature from the evaluation output.

    Accepts either the ensemble's predictions.json (``true_labels`` +
    ``predictions`` + ``test_filenames``) or a flat records list.
    """
    payload = json.loads(predictions_path.read_text())

    if isinstance(payload, dict) and "true_labels" in payload:
        y_true = np.asarray(payload["true_labels"], dtype=int)
        preds = payload.get("predictions", {})
        # predictions may be {model: [scores]} or a flat list of scores
        scores = next(iter(preds.values())) if isinstance(preds, dict) else preds
        y_pred = (np.asarray(scores, dtype=float) >= 0.5).astype(int)
        sensitive = payload.get("sensitive_feature") or payload.get("test_filenames") or []
        sensitive = np.asarray(_derive_groups(sensitive), dtype=object)
    else:
        records = payload if isinstance(payload, list) else payload.get("records", [])
        y_true = np.asarray([r["true_label"] for r in records], dtype=int)
        y_pred = np.asarray([r["predicted_label"] for r in records], dtype=int)
        sensitive = np.asarray([r.get("group", "all") for r in records], dtype=object)

    if len(sensitive) != len(y_true):
        # No usable sensitive feature: treat the whole set as one group so the
        # job still produces a report (all disparities are then 0 by construction).
        sensitive = np.full(len(y_true), "all", dtype=object)

    return y_true, y_pred, sensitive


def _derive_groups(values: list) -> list:
    """Derive a subgroup label from BreakHis-style filenames.

    The public datasets used here carry no demographic metadata, so
    magnification is used as an honest subgroup proxy. Real deployments should
    pass a genuine sensitive attribute instead.
    """
    groups = []
    for v in values:
        name = str(v)
        mag = "unknown"
        for candidate in ("40", "100", "200", "400"):
            if f"-{candidate}-" in name:
                mag = f"{candidate}X"
                break
        groups.append(mag)
    return groups


def class_imbalance(y_true: np.ndarray) -> float:
    """|P(y=1) - P(y=0)| - 0.0 means perfectly balanced."""
    if len(y_true) == 0:
        return 0.0
    p1 = float(np.mean(y_true == 1))
    return abs(p1 - (1.0 - p1))


def difference_in_proportions_of_labels(y_true: np.ndarray, sensitive: np.ndarray) -> float:
    """Max gap in positive-label rate between any two subgroups."""
    rates = [
        float(np.mean(y_true[sensitive == g] == 1))
        for g in np.unique(sensitive)
        if np.any(sensitive == g)
    ]
    return float(max(rates) - min(rates)) if len(rates) > 1 else 0.0


def compute(y_true, y_pred, sensitive, threshold: float) -> dict:
    if not _FAIRLEARN_AVAILABLE:
        raise RuntimeError(
            "fairlearn is not installed in this container. Add it to "
            "scripts/bias/requirements.txt or bake it into the processing image."
        )

    dp_diff = float(demographic_parity_difference(y_true, y_pred, sensitive_features=sensitive))
    try:
        eo_diff = float(equalized_odds_difference(y_true, y_pred, sensitive_features=sensitive))
    except ValueError:
        # A subgroup with no positive (or no negative) cases makes equalized
        # odds undefined; report 0.0 rather than failing the whole job.
        eo_diff = 0.0

    frame = MetricFrame(
        metrics={"selection_rate": selection_rate, "true_positive_rate": true_positive_rate},
        y_true=y_true,
        y_pred=y_pred,
        sensitive_features=sensitive,
    )

    per_group = {}
    for group in frame.by_group.index:
        row = frame.by_group.loc[group]
        mask = sensitive == group
        per_group[str(group)] = {
            "n": int(mask.sum()),
            "selection_rate": _safe_float(row.get("selection_rate")),
            "true_positive_rate": _safe_float(row.get("true_positive_rate")),
        }

    metrics = {
        "demographic_parity_difference": round(dp_diff, 4),
        "equal_opportunity_difference": round(eo_diff, 4),
        "class_imbalance": round(class_imbalance(y_true), 4),
        "difference_in_proportions_of_labels": round(
            difference_in_proportions_of_labels(y_true, sensitive), 4
        ),
        "per_group": per_group,
        "n_samples": len(y_true),
        "n_groups": len(per_group),
        "threshold": threshold,
    }
    # The pipeline gates on the largest disparity, so one number decides pass/fail.
    metrics["max_disparity"] = round(
        max(metrics["demographic_parity_difference"], metrics["equal_opportunity_difference"]), 4
    )
    metrics["passed"] = bool(metrics["max_disparity"] <= threshold)
    return metrics


def _safe_float(value) -> float | None:
    try:
        f = float(value)
    except (TypeError, ValueError):
        return None
    return None if np.isnan(f) else round(f, 4)


def main() -> int:
    parser = argparse.ArgumentParser(description="Fairlearn bias metrics for the fairness gate")
    parser.add_argument(
        "--evaluation-path",
        type=Path,
        default=Path("/opt/ml/processing/input/evaluation"),
        help="Directory holding the evaluation step's predictions JSON",
    )
    parser.add_argument(
        "--output-path",
        type=Path,
        default=Path("/opt/ml/processing/output"),
        help="Where bias_metrics.json is written",
    )
    parser.add_argument(
        "--sensitive-feature",
        default="magnification",
        help="Name of the sensitive attribute being analysed (reported, not used to select)",
    )
    parser.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD)
    args = parser.parse_args()

    candidates = sorted(args.evaluation_path.glob("*.json"))
    if not candidates:
        print(f"  ! no JSON found under {args.evaluation_path}", file=sys.stderr)
        return 1

    # Prefer a predictions file; fall back to the first JSON present.
    source = next((c for c in candidates if "prediction" in c.name.lower()), candidates[0])
    print(f"  reading {source}")

    y_true, y_pred, sensitive = load_predictions(source)
    metrics = compute(y_true, y_pred, sensitive, args.threshold)
    metrics["sensitive_feature"] = args.sensitive_feature

    args.output_path.mkdir(parents=True, exist_ok=True)
    out = args.output_path / "bias_metrics.json"
    out.write_text(json.dumps(metrics, indent=2))

    print(f"  ✓ {out}")
    print(f"    max_disparity={metrics['max_disparity']} threshold={args.threshold}")
    print(f"    groups={metrics['n_groups']} samples={metrics['n_samples']}")
    print(f"    passed={metrics['passed']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
