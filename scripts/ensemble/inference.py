# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Weighted-ensemble handler for the SageMaker TensorFlow Serving container.

The ensemble package puts this file at code/inference.py. The container serves
every member SavedModel (<name>_model/1) in TensorFlow Serving and calls
``handler()`` for each /invocations request. The handler calls each member over
the local TensorFlow Serving REST API and combines the scores with the weights
in ensemble_config.json. It uses only the standard library and ``requests``
(which the container ships), because the handler process has no TensorFlow.

Request: ``{"instances": [image]}`` where image is the (224, 224, 3) normalised
array, plus an optional ``"explain"`` object (see ``explain()``).

Response without ``explain`` (unchanged from earlier packages):
``{"predictions": [[p]], "predicted_class": [[0|1]], "threshold_used": t}``.
With ``explain`` the same keys plus ``"explanations"``.
"""

from __future__ import annotations

import json
import os
import random
import time
from collections import deque
from urllib.parse import urlsplit

CONFIG_PATH = "/opt/ml/model/ensemble_config.json"

GRADCAM = "gradcam"
REGION_SHAPLEY = "region_shapley"
METHODS = (GRADCAM, REGION_SHAPLEY)

# Region Shapley: REGION_GRID x REGION_GRID regions, so 16 players. One
# permutation costs REGION_GRID**2 - 1 new evaluations; the empty and full
# coalitions are shared by all permutations.
REGION_GRID = 4
DEFAULT_MAX_EVALS = 32
MAX_EVALS_CAP = 64
DEFAULT_SEED = 0
# Explain time budget, counted from the start of the explain path. The region
# Shapley loop skips permutations that would overrun it (see region_shapley).
# The cap stays under the container's gunicorn worker timeout (30 s unless
# SAGEMAKER_GUNICORN_TIMEOUT_SECONDS raises it) and API Gateway's 29 s.
DEFAULT_TIME_BUDGET_MS = 5000
MAX_TIME_BUDGET_MS = 25000
# Grad-CAM top region: 4-connected cells at or above this share of the peak.
TOP_REGION_LEVEL = 0.5


class SignatureUnavailable(Exception):
    """The member SavedModel has no such signature (package built before explanations)."""


_config_cache = {}


def load_config(path=CONFIG_PATH):
    if path not in _config_cache:
        with open(path) as f:
            _config_cache[path] = json.load(f)
    return _config_cache[path]


def tfs_transport(rest_uri):
    """Return call(model_name, body_json) -> parsed response for the local TFS REST API."""
    import requests

    parts = urlsplit(rest_uri)
    base = f"{parts.scheme}://{parts.netloc}/v1/models"

    def call(model_name, body):
        resp = requests.post(
            f"{base}/{model_name}:predict",
            data=body,
            headers={"Content-Type": "application/json"},
            timeout=55,
        )
        if resp.status_code == 400 and "signature" in resp.text.lower():
            raise SignatureUnavailable(resp.text[:200])
        resp.raise_for_status()
        return resp.json()

    return call


def _member(model_name):
    return f"{model_name}_model"


def _first_scalar(value):
    while isinstance(value, list):
        value = value[0]
    return float(value)


def predict(image_json, config, call):
    """Weighted ensemble score for one image. image_json is json.dumps(image)."""
    body = '{"instances": [' + image_json + "]}"
    per_model = {}
    for name in config["models"]:
        per_model[name] = _first_scalar(call(_member(name), body)["predictions"])
    score = sum(w * per_model[n] for n, w in zip(config["models"], config["weights"]))
    return score, per_model


def _normalise(grid):
    peak = max(max(row) for row in grid)
    if peak <= 0.0:
        return [[0.0 for _ in row] for row in grid]
    return [[v / peak for v in row] for row in grid]


def top_region(grid, level=TOP_REGION_LEVEL):
    """4-connected cells >= level * peak around the peak, as a box in image fractions.

    Box is [x_min, y_min, x_max, y_max] in [0, 1] of the model input, which is
    the whole upload resized, so it maps onto the original image axes directly.
    """
    size = len(grid)
    peak_r, peak_c = max(
        ((r, c) for r in range(size) for c in range(size)), key=lambda rc: grid[rc[0]][rc[1]]
    )
    peak = grid[peak_r][peak_c]
    if peak <= 0.0:
        return None
    seen = {(peak_r, peak_c)}
    queue = deque([(peak_r, peak_c)])
    while queue:
        r, c = queue.popleft()
        for nr, nc in ((r - 1, c), (r + 1, c), (r, c - 1), (r, c + 1)):
            if (
                0 <= nr < size
                and 0 <= nc < size
                and (nr, nc) not in seen
                and grid[nr][nc] >= level * peak
            ):
                seen.add((nr, nc))
                queue.append((nr, nc))
    rows = [r for r, _ in seen]
    cols = [c for _, c in seen]
    return {
        "box": [
            round(min(cols) / size, 4),
            round(min(rows) / size, 4),
            round((max(cols) + 1) / size, 4),
            round((max(rows) + 1) / size, 4),
        ],
        "peak_cell": [peak_r, peak_c],
        "cells": len(seen),
    }


def gradcam(image_json, config, target, call):
    """Ensemble Grad-CAM: per-model maps normalised to max 1, averaged by weight."""
    body = '{"signature_name": "gradcam", "inputs": {"image": [' + image_json + "]}}"
    key = f"cam_{target}"
    combined = None
    for name, weight in zip(config["models"], config["weights"]):
        cam = _normalise(call(_member(name), body)["outputs"][key][0])
        if combined is None:
            combined = [[0.0] * len(cam) for _ in cam]
        for r, row in enumerate(cam):
            for c, v in enumerate(row):
                combined[r][c] += weight * v
    grid = _normalise(combined)
    return {
        "method": "grad-cam",
        "target": target,
        "layer": "feature map feeding global average pooling (last convolutional block)",
        "combination": "ensemble-weighted average of per-model maps, each scaled to max 1",
        "grid_size": len(grid),
        "grid": [[round(v, 3) for v in row] for row in grid],
        "top_region": top_region(grid),
    }


def _coalition_mask(members, grid):
    mask = [[0.0] * grid for _ in range(grid)]
    for p in members:
        mask[p // grid][p % grid] = 1.0
    return mask


def plan_permutations(n_players, max_evals, seed):
    """Antithetic permutation pairs that fit in max_evals ensemble evaluations."""
    per_perm = n_players - 1
    count = max(1, (max_evals - 2) // per_perm)
    rng = random.Random(seed)
    perms = []
    while len(perms) < count:
        perm = list(range(n_players))
        rng.shuffle(perm)
        perms.append(perm)
        if len(perms) < count:
            perms.append(perm[::-1])
    return perms


def region_shapley(image_json, config, call, max_evals, seed, deadline, grid=REGION_GRID):
    """Region Shapley values for the ensemble malignant probability, by permutation sampling.

    Players are the grid x grid regions; a region outside the coalition is set
    to the baseline (the ImageNet mean colour). Each complete permutation's
    marginal contributions telescope to f(full) - f(empty), so the values sum
    to that difference exactly (up to rounding) however many permutations run.
    One permutation is scored per batch (the first batch also scores the
    empty and full coalitions). A batch starts only if, at the per-evaluation
    time measured so far, it would finish before ``deadline``
    (time.monotonic()); the first always runs.
    """
    n = grid * grid
    perms = plan_permutations(n, max_evals, seed)

    def ensemble_scores(masks):
        body = (
            '{"signature_name": "region_scores", "inputs": {"image": ['
            + image_json
            + "], "
            + '"masks": '
            + json.dumps(masks)
            + "}}"
        )
        total = [0.0] * len(masks)
        for name, weight in zip(config["models"], config["weights"]):
            outputs = call(_member(name), body)["outputs"]
            # TensorFlow Serving drops the output name when a signature has one output.
            scores = outputs["scores"] if isinstance(outputs, dict) else outputs
            for i, s in enumerate(scores):
                total[i] += weight * float(s)
        return total

    phi = [0.0] * n
    used = 0
    evaluations = 0
    f_empty = f_full = None
    started = time.monotonic()
    for perm in perms:
        if used:
            per_eval = (time.monotonic() - started) / evaluations
            if time.monotonic() + per_eval * (n - 1) > deadline:
                break
        masks = [_coalition_mask(perm[: j + 1], grid) for j in range(n - 1)]
        if f_empty is None:
            masks = [_coalition_mask([], grid), _coalition_mask(range(n), grid), *masks]
        scores = ensemble_scores(masks)
        evaluations += len(masks)
        if f_empty is None:
            f_empty, f_full = scores[0], scores[1]
            scores = scores[2:]
        chain = [f_empty, *scores, f_full]
        for j, player in enumerate(perm):
            phi[player] += chain[j + 1] - chain[j]
        used += 1

    values = [v / used for v in phi]
    return {
        "method": "region Shapley values estimated by antithetic permutation sampling",
        "target": "malignant probability",
        "grid_size": grid,
        "values": [[round(values[r * grid + c], 4) for c in range(grid)] for r in range(grid)],
        "baseline": "ImageNet mean colour (0 after normalisation)",
        "baseline_score": round(f_empty, 4),
        "full_score": round(f_full, 4),
        "sum": round(sum(values), 4),
        "permutations": used,
        "evaluations": evaluations,
        "seed": seed,
    }


def _explain_options(raw):
    """Validated (methods, max_evals, time_budget_ms, seed) from the request's explain field."""
    if raw is True:
        raw = {}
    if not isinstance(raw, dict):
        raise ValueError("explain must be true or an object")
    methods = raw.get("methods", list(METHODS))
    if not isinstance(methods, list) or not methods or any(m not in METHODS for m in methods):
        raise ValueError(f"explain.methods must be a non-empty subset of {list(METHODS)}")
    max_evals = min(int(raw.get("max_evals", DEFAULT_MAX_EVALS)), MAX_EVALS_CAP)
    if max_evals < REGION_GRID * REGION_GRID + 1:
        raise ValueError(f"explain.max_evals must be at least {REGION_GRID * REGION_GRID + 1}")
    budget = min(int(raw.get("time_budget_ms", DEFAULT_TIME_BUDGET_MS)), MAX_TIME_BUDGET_MS)
    seed = int(raw.get("seed", DEFAULT_SEED))
    return methods, max_evals, budget, seed


def explain(image_json, config, predicted_class, options, call):
    """Explanations for the predicted class. A method whose signature is missing reports why."""
    methods, max_evals, budget_ms, seed = options
    started = time.monotonic()
    target = "malignant" if predicted_class == 1 else "benign"
    out = {}
    if GRADCAM in methods:
        t0 = time.monotonic()
        try:
            out[GRADCAM] = gradcam(image_json, config, target, call)
            out[GRADCAM]["elapsed_ms"] = round((time.monotonic() - t0) * 1000)
        except SignatureUnavailable:
            out[GRADCAM] = {
                "status": "unavailable",
                "reason": "model package was built without the gradcam signature; retrain",
            }
    if REGION_SHAPLEY in methods:
        t0 = time.monotonic()
        try:
            out[REGION_SHAPLEY] = region_shapley(
                image_json, config, call, max_evals, seed, started + budget_ms / 1000.0
            )
            out[REGION_SHAPLEY]["elapsed_ms"] = round((time.monotonic() - t0) * 1000)
        except SignatureUnavailable:
            out[REGION_SHAPLEY] = {
                "status": "unavailable",
                "reason": "model package was built without the region_scores signature; retrain",
            }
    out["explain_ms"] = round((time.monotonic() - started) * 1000)
    return out


def run(request, config, call):
    """Handle one parsed request body and return the response dict."""
    image = request["instances"][0]
    image_json = json.dumps(image)
    threshold = float(config["optimal_threshold"])
    score, _ = predict(image_json, config, call)
    # >= matches the threshold selection in mlops_common.gates.
    predicted_class = int(score >= threshold)
    response = {
        "predictions": [[score]],
        "predicted_class": [[predicted_class]],
        "threshold_used": threshold,
    }
    if request.get("explain"):
        options = _explain_options(request["explain"])
        response["explanations"] = explain(image_json, config, predicted_class, options, call)
    return response


def handler(data, context):
    """SageMaker TensorFlow Serving container entry point."""
    request = json.loads(data.read().decode("utf-8"))
    config = load_config(os.environ.get("ENSEMBLE_CONFIG_PATH", CONFIG_PATH))
    response = run(request, config, tfs_transport(context.rest_uri))
    return json.dumps(response), "application/json"
