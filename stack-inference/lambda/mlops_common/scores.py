# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Read the malignant probability and decision threshold out of an endpoint response.

The ensemble handler (scripts/ensemble/inference.py) returns
``{"predictions": [[p]], "predicted_class": [[0|1]], "threshold_used": t}``.
Older list-shaped responses are still understood so a rollback to an earlier
model does not break the Lambda or the monitoring jobs. Anything else yields
None: callers must treat that as an error, never as a neutral 0.5.
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
    """Unwrap [[p]] / [p] to p. A two-element row is [p_benign, p_malignant]."""
    while isinstance(value, list) and value:
        if len(value) == 2 and not isinstance(value[0], list):
            return value[1]
        value = value[0]
    return value


def extract_score(payload: Any) -> float | None:
    """Malignant probability from one endpoint response, or None if unrecognised."""
    if isinstance(payload, dict):
        if "predictions" in payload:
            return clamp01(_first_scalar(payload["predictions"]))
        probabilities = payload.get("probabilities")
        if isinstance(probabilities, dict) and "malignant" in probabilities:
            return clamp01(probabilities["malignant"])
        if "predicted_class" in payload and "confidence" in payload:
            confidence = clamp01(payload["confidence"])
            if confidence is None:
                return None
            return confidence if payload["predicted_class"] == "malignant" else 1.0 - confidence
        for key in ("malignant_probability", "probability", "score"):
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
