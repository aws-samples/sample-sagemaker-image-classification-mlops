# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import base64
import json

import pytest
from mlops_common.capture import decode_capture_payload, iter_capture_records, parse_capture_line
from mlops_common.scores import extract_score, extract_threshold

RESPONSE = {"predictions": [[0.83]], "predicted_class": [[1]], "threshold_used": 0.41}


def _b64(obj) -> str:
    return base64.b64encode(json.dumps(obj).encode()).decode()


def test_decode_base64_section():
    assert decode_capture_payload({"data": _b64(RESPONSE), "encoding": "BASE64"}) == RESPONSE


def test_decode_json_section():
    assert decode_capture_payload({"data": json.dumps(RESPONSE), "encoding": "JSON"}) == RESPONSE


def test_decode_passes_through_parsed_data():
    assert decode_capture_payload({"data": RESPONSE}) == RESPONSE


@pytest.mark.parametrize(
    "section",
    [
        {"data": "%%% not base64 %%%", "encoding": "BASE64"},
        {"data": base64.b64encode(b"\xff\xfe").decode(), "encoding": "BASE64"},
        {"data": _b64("x")[:-2] + "!!", "encoding": "BASE64"},
        {"data": "{not json", "encoding": "JSON"},
        {"encoding": "JSON"},
        None,
        "garbage",
    ],
)
def test_decode_garbage_returns_none(section):
    assert decode_capture_payload(section) is None


def _capture_line(response, inference_id="req-1", event_id="evt-1"):
    meta = {"eventId": event_id}
    if inference_id:
        meta["inferenceId"] = inference_id
    return json.dumps(
        {
            "captureData": {
                "endpointInput": {"data": _b64({"instances": []}), "encoding": "BASE64"},
                "endpointOutput": {"data": _b64(response), "encoding": "BASE64"},
            },
            "eventMetadata": meta,
        }
    )


def test_parse_capture_line_reads_inference_id_score_and_threshold():
    parsed = parse_capture_line(_capture_line(RESPONSE))
    assert parsed == {
        "inference_id": "req-1",
        "event_id": "evt-1",
        "score": 0.83,
        "threshold": 0.41,
    }


def test_iter_capture_records_skips_bad_lines():
    body = "\n".join(
        [
            _capture_line(RESPONSE),
            "not json",
            json.dumps({"captureData": {"endpointOutput": {"data": "@@", "encoding": "BASE64"}}}),
            _capture_line({"unexpected": True}),
            "",
            _capture_line(RESPONSE, inference_id=None, event_id="evt-2"),
        ]
    )
    records = list(iter_capture_records(body))
    assert [(r["inference_id"], r["event_id"]) for r in records] == [
        ("req-1", "evt-1"),
        (None, "evt-2"),
    ]


@pytest.mark.parametrize(
    ("payload", "expected"),
    [
        ({"predictions": [[0.7]], "threshold_used": 0.4}, 0.7),
        ({"predictions": [0.2]}, 0.2),
        ({"predictions": [[0.1, 0.9]]}, 0.9),
        ([{"predicted_class": "benign", "confidence": 0.8}], pytest.approx(0.2)),
        ([{"probabilities": {"malignant": 0.65}}], 0.65),
        ({"predictions": [[1.7]]}, 1.0),
        ({"predictions": [[float("nan")]]}, None),
        ({"something": "else"}, None),
        ("text", None),
        (True, None),
    ],
)
def test_extract_score(payload, expected):
    assert extract_score(payload) == expected


def test_extract_threshold():
    assert extract_threshold(RESPONSE) == 0.41
    assert extract_threshold([{"threshold_used": 0.3}]) == 0.3
    assert extract_threshold({"predictions": [[0.5]]}) is None
