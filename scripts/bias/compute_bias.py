#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Fairness gate on the deployed ensemble (Part 4), with Fairlearn.

Reads ``predictions.json`` written by the ensemble step: the ensemble's test
scores, labels, the validation-tuned decision threshold and one sensitive
attribute value per image. Predictions are made at that threshold, so the gate
scores exactly the model that would be registered and deployed.

Writes ``bias_metrics.json``; the pipeline Condition step compares its
``max_disparity`` with the fairness_gate.max_disparity bar.

With fewer than two subgroups nothing can be compared and the result is
"not_evaluable". That fails the gate (max_disparity is written as 1.0) unless
``--allow-not-evaluable`` is passed, in which case it is written as 0.0 and
the report says the disparity was not measured.

Output (abridged):

    {
      "status": "evaluated" | "not_evaluable",
      "disparity_measured": true,
      "demographic_parity_difference": 0.03,
      "equalized_odds_difference": 0.04,
      "max_disparity": 0.04,
      "decision_threshold": 0.41,
      "per_group": {"40X": {"n": 120, "selection_rate": 0.51, ...}},
      "sensitive_feature": "magnification",
      "threshold": 0.10,
      "passed": true
    }
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

import numpy as np

# The step's code directory holds mlops_common next to this file; a local
# checkout has it one level up, in scripts/.
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from mlops_common.fairness import STATUS_NOT_EVALUABLE, compute_group_fairness

DEFAULT_THRESHOLD = 0.10
DEFAULT_ENSEMBLE_PATH = Path("/opt/ml/processing/input/ensemble")
# Written as max_disparity when fairness could not be measured and that is not
# allowed: above any sensible bar, so the Condition step fails.
NOT_EVALUABLE_DISPARITY = 1.0


def load_predictions(path: Path, sensitive_feature: str):
    """(y_true, scores, decision_threshold, groups or None) from predictions.json."""
    payload = json.loads(path.read_text())
    y_true = np.asarray(payload["labels"], dtype=int)
    scores = np.asarray(payload["scores"], dtype=float)
    threshold = float(payload["threshold"])
    if len(scores) != len(y_true):
        raise ValueError("scores and labels differ in length")
    groups = (payload.get("sensitive_features") or {}).get(sensitive_feature)
    if groups is not None and len(groups) != len(y_true):
        raise ValueError(f"sensitive feature '{sensitive_feature}' does not align with labels")
    return y_true, scores, threshold, groups


def class_imbalance(y_true: np.ndarray) -> float:
    """|P(y=1) - P(y=0)|; 0.0 means perfectly balanced."""
    if len(y_true) == 0:
        return 0.0
    p1 = float(np.mean(y_true == 1))
    return abs(p1 - (1.0 - p1))


def difference_in_proportions_of_labels(y_true: np.ndarray, groups: np.ndarray) -> float:
    """Max gap in positive-label rate between any two subgroups."""
    rates = [float(np.mean(y_true[groups == g] == 1)) for g in np.unique(groups)]
    return float(max(rates) - min(rates)) if len(rates) > 1 else 0.0


def evaluate(
    y_true,
    scores,
    decision_threshold: float,
    groups,
    max_disparity: float,
    allow_not_evaluable: bool = False,
) -> dict:
    """Gate result for one set of ensemble predictions."""
    y_true = np.asarray(y_true, dtype=int)
    y_pred = (np.asarray(scores, dtype=float) >= decision_threshold).astype(int)
    group_arr = np.asarray(groups if groups is not None else ["all"] * len(y_true), dtype=object)

    metrics = compute_group_fairness(
        y_true, y_pred, group_arr, max_disparity, allow_not_evaluable=allow_not_evaluable
    )
    metrics["decision_threshold"] = decision_threshold
    metrics["class_imbalance"] = round(class_imbalance(y_true), 4)
    metrics["difference_in_proportions_of_labels"] = round(
        difference_in_proportions_of_labels(y_true, group_arr), 4
    )
    measured = metrics["status"] != STATUS_NOT_EVALUABLE
    metrics["disparity_measured"] = measured
    if not measured:
        metrics["max_disparity"] = 0.0 if allow_not_evaluable else NOT_EVALUABLE_DISPARITY
    return metrics


def main() -> int:
    parser = argparse.ArgumentParser(description="Fairlearn fairness gate on the ensemble")
    parser.add_argument(
        "--ensemble-path",
        type=Path,
        default=DEFAULT_ENSEMBLE_PATH,
        help="Directory holding the ensemble step's predictions.json",
    )
    # Accepted so an older pipeline definition keeps working; the gate reads the
    # ensemble output, not per-model evaluation output.
    parser.add_argument("--evaluation-path", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--output-path", type=Path, default=Path("/opt/ml/processing/output"))
    parser.add_argument(
        "--sensitive-feature",
        default="magnification",
        help="Key under predictions.json sensitive_features to group by",
    )
    parser.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD)
    parser.add_argument(
        "--allow-not-evaluable",
        action="store_true",
        help="Pass the gate when fewer than two subgroups exist (disparity not measured)",
    )
    args = parser.parse_args()

    source = args.ensemble_path / "predictions.json"
    if not source.exists():
        print(f"predictions.json not found under {args.ensemble_path}", file=sys.stderr)
        return 1

    y_true, scores, decision_threshold, groups = load_predictions(source, args.sensitive_feature)
    if groups is None:
        print(f"no '{args.sensitive_feature}' attribute in predictions.json", file=sys.stderr)
    metrics = evaluate(
        y_true, scores, decision_threshold, groups, args.threshold, args.allow_not_evaluable
    )
    metrics["sensitive_feature"] = args.sensitive_feature

    args.output_path.mkdir(parents=True, exist_ok=True)
    out = args.output_path / "bias_metrics.json"
    out.write_text(json.dumps(metrics, indent=2))

    print(f"wrote {out}")
    print(
        f"status={metrics['status']} max_disparity={metrics['max_disparity']} "
        f"bar={args.threshold} decision_threshold={decision_threshold}"
    )
    print(f"groups={metrics['n_groups']} samples={metrics['n_samples']} passed={metrics['passed']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
