# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import json

import numpy as np
import pytest
from conftest import load_module
from mlops_common.gates import binary_metrics, clinical_gate, select_threshold

ensemble = load_module("scripts/ensemble/ensemble_creator.py", "ensemble_creator")


def test_select_threshold_meets_recall_target():
    labels = [0, 0, 0, 0, 1, 1, 1, 1]
    scores = [0.1, 0.2, 0.35, 0.6, 0.3, 0.7, 0.8, 0.9]
    threshold, info = select_threshold(labels, scores, min_recall=1.0)
    assert threshold <= 0.3
    assert info["recall_target_met"] is True
    assert binary_metrics(labels, scores, threshold)["recall"] == 1.0


def test_select_threshold_reports_unmet_recall_target():
    # 0.01 is below every grid threshold, so recall 1.0 is unreachable; the
    # fallback keeps the best achievable recall (0.5) instead.
    labels, scores = [0, 1, 1], [0.9, 0.01, 0.6]
    threshold, info = select_threshold(labels, scores, min_recall=1.0)
    assert info["recall_target_met"] is False
    assert binary_metrics(labels, scores, threshold)["recall"] == 0.5


def test_clinical_gate_drops_auc_only_when_undefined():
    single_class = binary_metrics([1, 1, 1], [0.9, 0.8, 0.7], 0.5)
    assert single_class["auc_roc"] is None
    gate = clinical_gate(single_class)
    assert "auc_roc" not in gate["thresholds"]
    assert gate["scored_on"] == "test"


class _FakeModel:
    pass


def _make_split(root, names_scores):
    for label_dir, names in names_scores.items():
        (root / label_dir).mkdir(parents=True)
        for name in names:
            (root / label_dir / name).write_bytes(b"")


def test_ensemble_tunes_on_validation_and_gates_on_test(tmp_path, monkeypatch, breakhis_name):
    """Validation and test disagree about the best threshold; the ensemble
    must take validation's and report test metrics at it."""
    val_dir, test_dir, eval_dir, out_dir = (tmp_path / d for d in ("val", "test", "eval", "out"))

    # Validation: malignant scores sit at 0.3-0.4, so a low threshold wins.
    val_scores = {}
    for i, s in enumerate([0.05, 0.1, 0.15, 0.2]):
        val_scores[f"breast_benign/{breakhis_name('B', 1, 40, i)}"] = s
    for i, s in enumerate([0.3, 0.32, 0.35, 0.4]):
        val_scores[f"breast_malignant/{breakhis_name('M', 2, 100, i)}"] = s
    # Test: separable only at a high threshold.
    test_scores = {}
    for i, s in enumerate([0.1, 0.5, 0.55, 0.6]):
        test_scores[f"breast_benign/{breakhis_name('B', 3, 40, i)}"] = s
    for i, s in enumerate([0.8, 0.85, 0.9, 0.95]):
        test_scores[f"breast_malignant/{breakhis_name('M', 4, 100, i)}"] = s

    for root, table in ((val_dir, val_scores), (test_dir, test_scores)):
        by_dir = {}
        for rel in table:
            d, n = rel.split("/")
            by_dir.setdefault(d, []).append(n)
        _make_split(root, by_dir)

    lookup = {str(val_dir / k): v for k, v in val_scores.items()}
    lookup.update({str(test_dir / k): v for k, v in test_scores.items()})

    def fake_predict_scores(_predict, paths, _size, batch_size=32):
        return np.asarray([lookup[p] for p in paths])

    monkeypatch.setattr(ensemble, "predict_scores", fake_predict_scores)
    monkeypatch.setattr(
        ensemble, "load_and_export_models", lambda *a: {"m1": _FakeModel(), "m2": _FakeModel()}
    )
    monkeypatch.setenv("MODEL_NAMES", "m1,m2")
    eval_dir.mkdir()
    (eval_dir / "evaluation_results.json").write_text(
        json.dumps(
            {
                "m1": {"accuracy": 0.2, "validation_metrics": {"accuracy": 0.9}},
                "m2": {"accuracy": 0.9, "validation_metrics": {"accuracy": 0.9}},
            }
        )
    )

    assert ensemble.create_ensemble(
        str(tmp_path / "models"), str(eval_dir), str(test_dir), str(val_dir), str(out_dir)
    )
    results = json.loads((out_dir / "ensemble_results.json").read_text())
    predictions = json.loads((out_dir / "predictions.json").read_text())

    val_labels = [0] * 4 + [1] * 4
    expected_threshold, _ = select_threshold(val_labels, list(val_scores.values()), min_recall=0.95)
    test_only_threshold, _ = select_threshold(
        [0] * 4 + [1] * 4, list(test_scores.values()), min_recall=0.95
    )
    assert expected_threshold != test_only_threshold
    assert results["decision_threshold"] == pytest.approx(expected_threshold)
    assert results["scored_on"] == "test"
    assert results["weights"] == {"m1": 0.5, "m2": 0.5}  # validation accuracy, not test

    test_metrics = binary_metrics([0] * 4 + [1] * 4, list(test_scores.values()), expected_threshold)
    assert results["ensemble_accuracy"] == pytest.approx(test_metrics["accuracy"])

    assert predictions["threshold"] == pytest.approx(expected_threshold)
    assert predictions["labels"] == [0] * 4 + [1] * 4
    assert predictions["scores"] == pytest.approx(list(test_scores.values()))
    assert predictions["sensitive_features"]["magnification"] == ["40X"] * 4 + ["100X"] * 4
    config = json.loads((out_dir / "ensemble_config.json").read_text())
    assert config["optimal_threshold"] == pytest.approx(expected_threshold)
