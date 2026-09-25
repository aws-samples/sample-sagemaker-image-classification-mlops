# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Binary metrics, decision-threshold selection and the clinical quality gate.

Threshold selection and gate scoring must use different data: the threshold is
tuned on the validation split and the gate is scored on the untouched test
split. Tuning on test and then gating on it reports an optimistic number.
"""

from __future__ import annotations

from collections.abc import Sequence

import numpy as np

# Clinical minimums the ensemble must clear on the test split. Recall has the
# highest bar because a missed malignant case is the costly error. The pipeline
# Condition step reads the same values from Terraform (clinical_quality_gate).
CLINICAL_QUALITY_THRESHOLDS = {
    "accuracy": 0.85,
    "recall": 0.95,
    "auc_roc": 0.90,
    "precision": 0.80,
}

THRESHOLD_GRID = np.round(np.linspace(0.05, 0.95, 91), 2)


def _confusion(y_true: np.ndarray, y_pred: np.ndarray) -> tuple[int, int, int, int]:
    tp = int(np.sum((y_true == 1) & (y_pred == 1)))
    tn = int(np.sum((y_true == 0) & (y_pred == 0)))
    fp = int(np.sum((y_true == 0) & (y_pred == 1)))
    fn = int(np.sum((y_true == 1) & (y_pred == 0)))
    return tp, tn, fp, fn


def _ratio(num: int, den: int) -> float:
    return float(num) / den if den else 0.0


def binary_metrics(y_true: Sequence[int], scores: Sequence[float], threshold: float) -> dict:
    """Accuracy, precision, recall, F1, balanced accuracy and AUC at threshold.

    A score >= threshold is a malignant call. ``auc_roc`` is None when the
    labels hold a single class (AUC is undefined there).
    """
    y_true = np.asarray(y_true, dtype=int)
    scores = np.asarray(scores, dtype=float)
    y_pred = (scores >= threshold).astype(int)
    tp, tn, fp, fn = _confusion(y_true, y_pred)
    precision = _ratio(tp, tp + fp)
    recall = _ratio(tp, tp + fn)
    specificity = _ratio(tn, tn + fp)
    auc = None
    if len(np.unique(y_true)) == 2:
        from sklearn.metrics import roc_auc_score

        auc = float(roc_auc_score(y_true, scores))
    return {
        "threshold": float(threshold),
        "n_samples": len(y_true),
        "accuracy": _ratio(tp + tn, len(y_true)),
        "precision": precision,
        "recall": recall,
        "specificity": specificity,
        "f1_score": _ratio(2 * tp, 2 * tp + fp + fn),
        "balanced_accuracy": (recall + specificity) / 2,
        "auc_roc": auc,
    }


def select_threshold(
    y_true: Sequence[int],
    scores: Sequence[float],
    min_recall: float | None = None,
) -> tuple[float, dict]:
    """Pick a decision threshold on VALIDATION data.

    Maximises balanced accuracy among thresholds whose recall is at least
    ``min_recall``. If no threshold reaches that recall, falls back to the
    highest-recall threshold (ties broken by balanced accuracy), and the
    returned info says so. Pass test data here and the gate is meaningless.
    """
    y_true = np.asarray(y_true, dtype=int)
    scores = np.asarray(scores, dtype=float)
    if len(y_true) == 0:
        return 0.5, {"reason": "no validation samples; default 0.5", "recall_target_met": False}

    candidates = [binary_metrics(y_true, scores, t) for t in THRESHOLD_GRID]
    eligible = candidates
    target_met = True
    if min_recall is not None:
        eligible = [m for m in candidates if m["recall"] >= min_recall]
        if not eligible:
            target_met = False
            best_recall = max(m["recall"] for m in candidates)
            eligible = [m for m in candidates if m["recall"] == best_recall]
    # Highest balanced accuracy; on ties prefer the lower threshold (more recall).
    best = max(eligible, key=lambda m: (m["balanced_accuracy"], -m["threshold"]))
    info = {
        "selected_on": "validation",
        "min_recall": min_recall,
        "recall_target_met": target_met,
        "validation_metrics": best,
    }
    return float(best["threshold"]), info


def evaluate_clinical_quality(
    metrics: dict[str, float | None], thresholds: dict[str, float]
) -> tuple[bool, dict]:
    """Gate metrics against clinical minimums.

    Returns (passed, results). A metric missing from ``metrics`` (or None)
    counts as 0.0 and fails rather than crashing.
    """
    results = {}
    passed = True
    for metric, threshold in thresholds.items():
        value = metrics.get(metric)
        value = 0.0 if value is None else float(value)
        met = value >= threshold
        results[metric] = {
            "value": value,
            "threshold": threshold,
            "passed": met,
            "gap": round(value - threshold, 4),
        }
        passed = passed and met
    return passed, results


def clinical_gate(test_metrics: dict, thresholds: dict[str, float] | None = None) -> dict:
    """Clinical gate on TEST metrics from ``binary_metrics``.

    AUC is dropped from the gate (and recorded as unavailable) only when it is
    undefined because the test split holds one class.
    """
    gate_thresholds = dict(thresholds or CLINICAL_QUALITY_THRESHOLDS)
    auc_available = test_metrics.get("auc_roc") is not None
    if not auc_available:
        gate_thresholds.pop("auc_roc", None)
    passed, results = evaluate_clinical_quality(test_metrics, gate_thresholds)
    return {
        "passed": passed,
        "scored_on": "test",
        "results": results,
        "auc_roc_available": auc_available,
        "thresholds": gate_thresholds,
    }
