# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Read the positive-class probability and decision threshold out of an endpoint response.

The ensemble handler (scripts/ensemble/inference.py) returns
``{"predictions": [[p]], "predicted_class": [[0|1]], "threshold_used": t}``.
List-shaped responses are understood too. Anything else yields None: callers
must treat that as an error, never as a neutral 0.5.
"""

from __future__ import annotations

from typing import Any


def clamp01(value: Any) -> float | None:
    """float(value) clipped to [0, 1]; None if not numeric or NaN."""
    if isinstance(value, bool):
        return None
    try:
        f = float(value)
    except (TypeError, ValueError):
        return None
    if f != f:  # NaN
        return None
    return min(max(f, 0.0), 1.0)


def _first_scalar(value: Any) -> Any:
    """Unwrap [[p]] / [p] to p. A two-element row is [p_negative, p_positive]."""
    while isinstance(value, list) and value:
        if len(value) == 2 and not isinstance(value[0], list):
            return value[1]
        value = value[0]
    return value


def extract_score(payload: Any) -> float | None:
    """Positive-class probability from one endpoint response, or None if unrecognised."""
    if isinstance(payload, dict):
        if "predictions" in payload:
            return clamp01(_first_scalar(payload["predictions"]))
        for key in ("positive_probability", "probability", "score"):
            if key in payload:
                return clamp01(payload[key])
        return None
    if isinstance(payload, list) and payload:
        first = payload[0]
        if isinstance(first, (dict, list)):
            return extract_score(first)
        return clamp01(first)
    return clamp01(payload)


def extract_threshold(payload: Any) -> float | None:
    """Decision threshold the model applied (``threshold_used``), or None."""
    if isinstance(payload, list) and payload and isinstance(payload[0], dict):
        payload = payload[0]
    if isinstance(payload, dict) and "threshold_used" in payload:
        return clamp01(payload["threshold_used"])
    return None
