# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Parse SageMaker endpoint data-capture JSON Lines records."""

from __future__ import annotations

import base64
import binascii
import json
from collections.abc import Iterator
from typing import Any

from .scores import extract_score, extract_threshold


def decode_capture_payload(section: dict | None) -> Any:
    """Decode one captureData section (endpointInput or endpointOutput) to JSON.

    SageMaker stores the payload under ``data`` and says how in a sibling
    ``encoding`` field. For a JSON endpoint it is "BASE64", so ``data`` is
    base64-encoded JSON, not JSON text. Returns None for anything undecodable
    so one bad record never aborts a run.
    """
    if not isinstance(section, dict):
        return None
    raw = section.get("data")
    if raw is None:
        return None
    if isinstance(raw, (dict, list)):
        return raw
    if str(section.get("encoding", "")).upper() == "BASE64":
        try:
            raw = base64.b64decode(raw, validate=True).decode("utf8")
        except (binascii.Error, ValueError, TypeError, UnicodeDecodeError):
            return None
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return None


def parse_capture_line(line: str) -> dict | None:
    """One capture line to {inference_id, event_id, score, threshold}, or None.

    ``inference_id`` is the InferenceId the caller passed to InvokeEndpoint
    (the inference Lambda passes its request id); ``event_id`` is the id
    SageMaker generates. Joins with ground truth use inference_id first.
    """
    line = line.strip()
    if not line:
        return None
    try:
        record = json.loads(line)
    except json.JSONDecodeError:
        return None
    if not isinstance(record, dict):
        return None
    payload = decode_capture_payload((record.get("captureData") or {}).get("endpointOutput"))
    score = extract_score(payload) if payload is not None else None
    if score is None:
        return None
    meta = record.get("eventMetadata") or {}
    return {
        "inference_id": meta.get("inferenceId"),
        "event_id": meta.get("eventId"),
        "score": score,
        "threshold": extract_threshold(payload),
    }


def iter_capture_records(body: str) -> Iterator[dict]:
    """Parsed records from one capture file; malformed lines are skipped."""
    for line in body.splitlines():
        parsed = parse_capture_line(line)
        if parsed is not None:
            yield parsed
