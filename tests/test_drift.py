# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import base64
import json
import math

import numpy as np
import pytest
from conftest import load_module

drift = load_module("scripts/drift/compute_drift.py", "compute_drift")


def test_psi_identical_distributions_is_zero():
    scores = list(np.linspace(0.0, 1.0, 1000))
    assert drift.population_stability_index(scores, scores, 10) == pytest.approx(0.0)


def test_psi_known_two_bin_value():
    # Live 80/20 vs baseline 50/50 over two bins:
    # (0.8-0.5)ln(0.8/0.5) + (0.2-0.5)ln(0.2/0.5)
    live = [0.25] * 80 + [0.75] * 20
    baseline = [0.25] * 50 + [0.75] * 50
    expected = 0.3 * math.log(0.8 / 0.5) + (-0.3) * math.log(0.2 / 0.5)
    assert drift.population_stability_index(live, baseline, 2) == pytest.approx(expected)


def test_psi_detects_a_large_shift():
    rng = np.random.default_rng(0)
    baseline = rng.beta(2, 5, 5000).tolist()  # mostly benign scores
    live = rng.beta(5, 2, 5000).tolist()  # mostly malignant scores
    assert drift.population_stability_index(live, baseline, 10) > 0.2


def test_psi_ignores_nan_and_non_numeric():
    baseline = [0.1, 0.4, 0.6, 0.9] * 25
    clean = [0.2, 0.3, 0.7] * 30
    dirty = [*clean, float("nan"), float("inf"), None, "x"]
    assert drift.population_stability_index(dirty, baseline, 10) == pytest.approx(
        drift.population_stability_index(clean, baseline, 10)
    )


def test_psi_with_no_usable_values_is_none():
    assert drift.population_stability_index([float("nan")], [0.5], 10) is None
    assert drift.population_stability_index([0.5], [], 10) is None


def test_psi_value_one_lands_in_last_bin():
    assert drift.population_stability_index([1.0], [0.99], 10) == pytest.approx(0.0)


def test_scores_from_capture_decodes_base64_output():
    def line(score):
        out = base64.b64encode(
            json.dumps({"predictions": [[score]], "threshold_used": 0.5}).encode()
        ).decode()
        return json.dumps({"captureData": {"endpointOutput": {"data": out, "encoding": "BASE64"}}})

    body = "\n".join([line(0.1), "garbage", line(0.9)])
    assert drift.scores_from_capture(body) == [0.1, 0.9]
