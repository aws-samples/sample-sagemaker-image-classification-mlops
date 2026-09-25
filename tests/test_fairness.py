# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import json

import pytest
from conftest import load_module
from mlops_common.fairness import STATUS_EVALUATED, STATUS_NOT_EVALUABLE, compute_group_fairness

bias = load_module("scripts/bias/compute_bias.py", "compute_bias")
fairness_job = load_module("scripts/fairness/compute_fairness.py", "compute_fairness")


def test_single_group_is_not_evaluable_and_fails():
    result = compute_group_fairness([0, 1, 1, 0], [0, 1, 0, 0], ["all"] * 4, threshold=0.1)
    assert result["status"] == STATUS_NOT_EVALUABLE
    assert result["max_disparity"] is None
    assert result["passed"] is False


def test_single_group_passes_only_with_explicit_allow():
    result = compute_group_fairness(
        [0, 1], [0, 1], ["all", "all"], threshold=0.1, allow_not_evaluable=True
    )
    assert result["status"] == STATUS_NOT_EVALUABLE
    assert result["passed"] is True


def test_two_groups_demographic_parity():
    y_true = [0, 1, 0, 1, 0, 1, 0, 1]
    y_pred = [1, 1, 1, 1, 0, 1, 0, 0]
    groups = ["a"] * 4 + ["b"] * 4
    result = compute_group_fairness(y_true, y_pred, groups, threshold=0.1)
    assert result["status"] == STATUS_EVALUATED
    assert result["demographic_parity_difference"] == pytest.approx(0.75)
    assert result["max_disparity"] >= 0.75
    assert result["passed"] is False


def test_single_class_labels_do_not_crash():
    # No malignant case at all: equalized odds is undefined for every group and
    # left out; demographic parity is still measured.
    result = compute_group_fairness([0] * 6, [0, 1, 0, 0, 0, 0], ["a"] * 3 + ["b"] * 3, 0.5)
    assert result["status"] == STATUS_EVALUATED
    assert result["equalized_odds_difference"] is None
    assert result["demographic_parity_difference"] == pytest.approx(1 / 3, abs=1e-4)
    assert result["passed"] is True


def test_single_class_predictions_do_not_crash():
    result = compute_group_fairness([0, 1, 0, 1], [1, 1, 1, 1], ["a", "a", "b", "b"], 0.1)
    assert result["demographic_parity_difference"] == 0.0
    assert result["equalized_odds_difference"] == 0.0
    assert result["passed"] is True


def test_bias_gate_scores_at_the_ensemble_threshold():
    scores = [0.35, 0.45, 0.35, 0.45]
    labels = [0, 1, 0, 1]
    groups = ["40X", "40X", "100X", "100X"]
    # At 0.4 both groups flag exactly their malignant image: no disparity.
    at_tuned = bias.evaluate(labels, scores, 0.4, groups, max_disparity=0.1)
    assert at_tuned["decision_threshold"] == 0.4
    assert at_tuned["max_disparity"] == 0.0
    assert at_tuned["passed"] is True
    # At 0.5 nothing is flagged, so recall is 0 everywhere; the gate must use
    # the threshold it is given, not a fixed 0.5.
    at_half = bias.evaluate(labels, scores, 0.5, groups, max_disparity=0.1)
    assert at_half["per_group"]["40X"]["selection_rate"] == 0.0


def test_bias_gate_not_evaluable_fails_the_condition():
    result = bias.evaluate([0, 1], [0.2, 0.8], 0.5, None, max_disparity=0.1)
    assert result["status"] == STATUS_NOT_EVALUABLE
    assert result["disparity_measured"] is False
    assert result["max_disparity"] == bias.NOT_EVALUABLE_DISPARITY
    assert result["passed"] is False


def test_bias_gate_not_evaluable_allowed():
    result = bias.evaluate(
        [0, 1], [0.2, 0.8], 0.5, ["x", "x"], max_disparity=0.1, allow_not_evaluable=True
    )
    assert result["max_disparity"] == 0.0
    assert result["passed"] is True
    assert result["disparity_measured"] is False


def test_bias_reads_ensemble_predictions(tmp_path):
    payload = {
        "threshold": 0.4,
        "scores": [0.1, 0.9],
        "labels": [0, 1],
        "sensitive_features": {"magnification": ["40X", "100X"]},
    }
    path = tmp_path / "predictions.json"
    path.write_text(json.dumps(payload))
    _y_true, _scores, threshold, groups = bias.load_predictions(path, "magnification")
    assert threshold == 0.4
    assert groups == ["40X", "100X"]
    assert bias.load_predictions(path, "age")[3] is None


def test_live_join_uses_capture_threshold_and_skips_unknown():
    preds = {"r1": (0.45, 0.4), "r2": (0.45, 0.5), "r3": (0.9, None)}
    truth = {
        "r1": {"label": 1, "group": "a"},
        "r2": {"label": 1, "group": "b"},
        "r3": {"label": 1, "group": "a"},
        "r4": {"label": 0, "group": "b"},
    }
    y_true, y_pred, groups, skipped = fairness_job.join_predictions(preds, truth)
    assert (y_true, y_pred, groups, skipped) == ([1, 1], [1, 0], ["a", "b"], 1)
