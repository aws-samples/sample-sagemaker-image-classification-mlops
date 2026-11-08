# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import base64
import io
import json
import logging
from types import SimpleNamespace

import boto3
import pytest
from botocore.response import StreamingBody
from botocore.stub import ANY, Stubber
from conftest import load_module
from moto import mock_aws
from PIL import Image

handler = load_module("stack-inference/lambda/inference_handler.py", "inference_handler")

REQUEST_ID = "3f1c2a9e-5b7d-4e2a-9c1f-0a1b2c3d4e5f"
BUCKET = "inference-results-test"


def _jpeg_b64(size=(64, 48)):
    buf = io.BytesIO()
    Image.new("RGB", size, (200, 120, 90)).save(buf, format="JPEG")
    return base64.b64encode(buf.getvalue()).decode()


def _body(obj):
    raw = json.dumps(obj).encode()
    return StreamingBody(io.BytesIO(raw), len(raw))


@pytest.fixture
def aws(monkeypatch):
    """moto for S3 and CloudWatch, a Stubber for sagemaker-runtime."""
    with mock_aws():
        s3 = boto3.client("s3")
        s3.create_bucket(Bucket=BUCKET)
        cloudwatch = boto3.client("cloudwatch")
        runtime = boto3.client("sagemaker-runtime")
        stubber = Stubber(runtime)
        clients = {"s3": s3, "cloudwatch": cloudwatch, "sagemaker-runtime": runtime}
        monkeypatch.setattr(handler.boto3, "client", lambda name, **_: clients[name])
        monkeypatch.setenv("ENDPOINT_NAME", "test-endpoint")
        monkeypatch.setenv("INFERENCE_BUCKET", BUCKET)
        monkeypatch.delenv("ALLOWED_ORIGIN", raising=False)
        monkeypatch.delenv("FLOW_DEFINITION_ARN", raising=False)
        monkeypatch.setenv("ENABLE_BEDROCK_HYBRID", "false")
        with stubber:
            yield SimpleNamespace(s3=s3, cloudwatch=cloudwatch, stubber=stubber)


def _context():
    return SimpleNamespace(aws_request_id=REQUEST_ID)


def _post(image):
    return {"httpMethod": "POST", "resource": "/predict", "body": json.dumps({"image": image})}


def _error_metric_count(cloudwatch):
    metrics = cloudwatch.list_metrics(MetricName="PredictionError")["Metrics"]
    return len(metrics)


def test_missing_image_is_400(aws):
    resp = handler.lambda_handler({"httpMethod": "POST", "body": json.dumps({})}, _context())
    assert resp["statusCode"] == 400


def test_invalid_base64_is_400(aws):
    resp = handler.lambda_handler(_post("@@not-base64@@"), _context())
    assert resp["statusCode"] == 400


def test_non_json_body_is_400(aws):
    resp = handler.lambda_handler({"httpMethod": "POST", "body": "{oops"}, _context())
    assert resp["statusCode"] == 400


def test_oversized_image_is_413(aws, monkeypatch):
    monkeypatch.setenv("MAX_IMAGE_BYTES", "100")
    resp = handler.lambda_handler(_post(_jpeg_b64()), _context())
    assert resp["statusCode"] == 413


def test_unknown_result_is_404(aws):
    event = {"httpMethod": "GET", "pathParameters": {"id": REQUEST_ID}}
    assert handler.lambda_handler(event, _context())["statusCode"] == 404


@pytest.mark.parametrize("bad_id", ["../../etc", "abc", "3F1C2A9E-5B7D-4E2A-9C1F-0A1B2C3D4E5F", ""])
def test_result_id_must_be_a_uuid(aws, bad_id):
    event = {"httpMethod": "GET", "pathParameters": {"id": bad_id}}
    assert handler.lambda_handler(event, _context())["statusCode"] == 400


def test_unknown_response_format_is_502_with_metric(aws):
    aws.stubber.add_response(
        "invoke_endpoint",
        {"Body": _body({"unexpected": 1}), "ContentType": "application/json"},
        {
            "EndpointName": "test-endpoint",
            "ContentType": "application/json",
            "Accept": "application/json",
            "Body": ANY,
            "InferenceId": REQUEST_ID,
        },
    )
    resp = handler.lambda_handler(_post(_jpeg_b64()), _context())
    assert resp["statusCode"] == 502
    assert _error_metric_count(aws.cloudwatch) == 1


def test_predict_200_passes_inference_id_and_stores_result(aws, caplog):
    image = _jpeg_b64()
    aws.stubber.add_response(
        "invoke_endpoint",
        {
            "Body": _body(
                {"predictions": [[0.45]], "predicted_class": [[1]], "threshold_used": 0.4}
            ),
            "ContentType": "application/json",
        },
        {
            "EndpointName": "test-endpoint",
            "ContentType": "application/json",
            "Accept": "application/json",
            "Body": ANY,
            "InferenceId": REQUEST_ID,
        },
    )
    with caplog.at_level(logging.INFO):
        resp = handler.lambda_handler(_post(image), _context())
    assert resp["statusCode"] == 200
    body = json.loads(resp["body"])
    # 0.45 >= the model's own threshold 0.4, so positive (a fixed 0.5 would say negative).
    assert body["prediction"] == "positive"
    assert body["probabilities"] == {"negative": pytest.approx(0.55), "positive": 0.45}
    assert body["threshold_used"] == 0.4
    assert body["request_id"] == REQUEST_ID
    assert "image_s3_uri" not in body

    # No image bytes or model output in the logs.
    assert image[:40] not in caplog.text
    assert "0.45" not in caplog.text

    obj = aws.s3.get_object(Bucket=BUCKET, Key=f"predictions/{REQUEST_ID}/input.jpg")
    assert obj["ContentType"] == "image/jpeg"

    got = handler.lambda_handler(
        {"httpMethod": "GET", "pathParameters": {"id": REQUEST_ID}}, _context()
    )
    assert got["statusCode"] == 200
    stored = json.loads(got["body"])
    assert stored["prediction"] == "positive"
    assert "image_s3_uri" not in stored


def test_no_cors_header_without_allowed_origin(aws):
    resp = handler.lambda_handler({"httpMethod": "POST", "body": "{}"}, _context())
    assert "Access-Control-Allow-Origin" not in resp["headers"]


def test_cors_header_uses_allowed_origin(aws, monkeypatch):
    monkeypatch.setenv("ALLOWED_ORIGIN", "https://app.example.com")
    resp = handler.lambda_handler({"httpMethod": "POST", "body": "{}"}, _context())
    assert resp["headers"]["Access-Control-Allow-Origin"] == "https://app.example.com"


# --- Explanations -----------------------------------------------------------

EXPLANATIONS = {
    "gradcam": {"method": "grad-cam", "grid_size": 14, "grid": [[0.0] * 14] * 14},
    "region_shapley": {
        "method": "region Shapley values estimated by antithetic permutation sampling"
    },
    "explain_ms": 3100,
}
BASE_KEYS = {
    "request_id",
    "prediction",
    "confidence",
    "probabilities",
    "positive_class",
    "threshold_used",
    "model_info",
    "routing",
}


@pytest.fixture
def runtime(aws, monkeypatch):
    """Record what the Lambda sends to the endpoint and answer with a fixed body."""
    sent = []
    answer = {"predictions": [[0.8]], "predicted_class": [[1]], "threshold_used": 0.5}

    def invoke_endpoint(**kwargs):
        sent.append(json.loads(kwargs["Body"]))
        return {"Body": _body(answer), "ContentType": "application/json"}

    fake = SimpleNamespace(invoke_endpoint=invoke_endpoint)
    clients = {"s3": aws.s3, "cloudwatch": aws.cloudwatch, "sagemaker-runtime": fake}
    monkeypatch.setattr(handler.boto3, "client", lambda name, **_: clients[name])
    monkeypatch.setenv("EXPLANATIONS_ENABLED", "true")
    monkeypatch.setenv("EXPLAIN_MAX_EVALS", "32")
    monkeypatch.setenv("EXPLAIN_TIME_BUDGET_MS", "5000")
    return SimpleNamespace(sent=sent, answer=answer)


def _post_json(obj):
    return {"httpMethod": "POST", "resource": "/predict", "body": json.dumps(obj)}


def test_predict_without_explain_is_unchanged(runtime):
    resp = handler.lambda_handler(_post_json({"image": _jpeg_b64()}), _context())
    assert resp["statusCode"] == 200
    assert set(runtime.sent[0]) == {"instances"}
    assert set(json.loads(resp["body"])) == BASE_KEYS


def test_explain_false_is_the_same_as_absent(runtime):
    resp = handler.lambda_handler(_post_json({"image": _jpeg_b64(), "explain": False}), _context())
    assert set(runtime.sent[0]) == {"instances"}
    assert set(json.loads(resp["body"])) == BASE_KEYS


def test_explain_true_forwards_caps_and_returns_explanations(runtime):
    runtime.answer["explanations"] = EXPLANATIONS
    resp = handler.lambda_handler(_post_json({"image": _jpeg_b64(), "explain": True}), _context())
    assert resp["statusCode"] == 200
    assert runtime.sent[0]["explain"] == {
        "methods": ["gradcam", "region_shapley"],
        "max_evals": 32,
        "time_budget_ms": 5000,
    }
    body = json.loads(resp["body"])
    assert body["explanations"] == EXPLANATIONS
    assert set(body) == BASE_KEYS | {"explanations"}


def test_explain_method_subset_is_forwarded(runtime):
    runtime.answer["explanations"] = {"gradcam": EXPLANATIONS["gradcam"], "explain_ms": 300}
    handler.lambda_handler(
        _post_json({"image": _jpeg_b64(), "explain": {"methods": ["gradcam"]}}), _context()
    )
    assert runtime.sent[0]["explain"]["methods"] == ["gradcam"]


@pytest.mark.parametrize(
    "explain",
    ["yes", 1, {"methods": []}, {"methods": ["lime"]}, {"max_evals": 1000}, [True]],
)
def test_invalid_explain_is_400_without_calling_the_endpoint(runtime, explain):
    resp = handler.lambda_handler(
        _post_json({"image": _jpeg_b64(), "explain": explain}), _context()
    )
    assert resp["statusCode"] == 400
    assert runtime.sent == []


def test_explain_when_disabled_says_so(runtime, monkeypatch):
    monkeypatch.setenv("EXPLANATIONS_ENABLED", "false")
    resp = handler.lambda_handler(_post_json({"image": _jpeg_b64(), "explain": True}), _context())
    assert set(runtime.sent[0]) == {"instances"}
    assert json.loads(resp["body"])["explanations"] == {"status": "disabled"}


def test_explain_against_an_old_package_is_unavailable(runtime):
    resp = handler.lambda_handler(_post_json({"image": _jpeg_b64(), "explain": True}), _context())
    assert json.loads(resp["body"])["explanations"]["status"] == "unavailable"


def test_explanations_are_stored_with_the_prediction(runtime, aws):
    runtime.answer["explanations"] = EXPLANATIONS
    handler.lambda_handler(_post_json({"image": _jpeg_b64(), "explain": True}), _context())
    stored = json.loads(
        aws.s3.get_object(Bucket=BUCKET, Key=f"predictions/{REQUEST_ID}/prediction.json")[
            "Body"
        ].read()
    )
    assert stored["explanations"] == EXPLANATIONS


# --- Grad-CAM border check --------------------------------------------------


def _grid(cells, size=14):
    """A size x size Grad-CAM grid with 1.0 at the given (row, col) cells."""
    return [[1.0 if (r, c) in cells else 0.0 for c in range(size)] for r in range(size)]


RING = {(r, c) for r in range(14) for c in range(14) if min(r, c, 13 - r, 13 - c) == 0}
CENTRE = {(r, c) for r in range(5, 9) for c in range(5, 9)}


def _explained(runtime, grid):
    runtime.answer["explanations"] = {
        "gradcam": {"method": "grad-cam", "grid_size": len(grid), "grid": grid},
        "explain_ms": 300,
    }
    resp = handler.lambda_handler(_post_json({"image": _jpeg_b64(), "explain": True}), _context())
    assert resp["statusCode"] == 200
    return json.loads(resp["body"])


def test_border_attention_counts_the_outer_band():
    # With a 14x14 grid and a 10 percent band, only the outermost ring is border.
    assert handler.border_attention({"grid": _grid(RING)}, 0.1) == 1.0
    assert handler.border_attention({"grid": _grid(CENTRE)}, 0.1) == 0.0
    half = {(0, 0), (7, 7)}
    assert handler.border_attention({"grid": _grid(half)}, 0.1) == 0.5


@pytest.mark.parametrize(
    "gradcam",
    [
        None,
        {"status": "unavailable"},
        {"grid": []},
        {"grid": [[1.0, 0.0]]},
        {"grid": [[0.0] * 14] * 14},
        {"grid": [["x"] * 2] * 2},
    ],
)
def test_border_attention_without_a_usable_grid_is_none(gradcam):
    assert handler.border_attention(gradcam, 0.1) is None


def test_heatmap_on_the_border_is_flagged(runtime):
    body = _explained(runtime, _grid(RING))
    assert body["attention_on_border"] is True
    assert body["border_attention_fraction"] == 1.0
    assert set(body) == BASE_KEYS | {
        "explanations",
        "attention_on_border",
        "border_attention_fraction",
    }


def test_heatmap_on_the_subject_is_not_flagged(runtime):
    body = _explained(runtime, _grid(CENTRE))
    assert body["attention_on_border"] is False
    assert body["border_attention_fraction"] == 0.0


def test_border_band_and_threshold_come_from_the_environment(runtime, monkeypatch):
    # Second ring in, so border only with a band wider than one cell.
    inner_ring = {
        (r, c) for r in range(1, 13) for c in range(1, 13) if min(r, c, 13 - r, 13 - c) == 1
    }
    assert _explained(runtime, _grid(inner_ring))["attention_on_border"] is False
    monkeypatch.setenv("GRADCAM_BORDER_BAND", "0.2")
    assert _explained(runtime, _grid(inner_ring))["attention_on_border"] is True
    monkeypatch.setenv("GRADCAM_BORDER_THRESHOLD", "1.0")
    assert _explained(runtime, _grid(inner_ring))["attention_on_border"] is False


def test_no_border_flag_without_a_heatmap(runtime, monkeypatch):
    runtime.answer["explanations"] = {"region_shapley": {"method": "x"}, "explain_ms": 300}
    resp = handler.lambda_handler(_post_json({"image": _jpeg_b64(), "explain": True}), _context())
    assert "attention_on_border" not in json.loads(resp["body"])
    monkeypatch.setenv("EXPLANATIONS_ENABLED", "false")
    resp = handler.lambda_handler(_post_json({"image": _jpeg_b64(), "explain": True}), _context())
    assert "attention_on_border" not in json.loads(resp["body"])


def test_border_flag_is_stored_with_the_prediction(runtime, aws):
    _explained(runtime, _grid(RING))
    stored = json.loads(
        aws.s3.get_object(Bucket=BUCKET, Key=f"predictions/{REQUEST_ID}/prediction.json")[
            "Body"
        ].read()
    )
    assert stored["attention_on_border"] is True


# --- Image checks, class names, Amazon Bedrock and stored results ---------


def _image_b64(fmt, size=(64, 48)):
    buf = io.BytesIO()
    Image.new("RGB", size, (10, 20, 30)).save(buf, format=fmt)
    return base64.b64encode(buf.getvalue()).decode()


@pytest.mark.parametrize("fmt", ["BMP", "GIF", "TIFF"])
def test_formats_other_than_jpeg_and_png_are_400(aws, fmt):
    resp = handler.lambda_handler(_post(_image_b64(fmt)), _context())
    assert resp["statusCode"] == 400


def test_decode_rejects_bmp_before_decoding_pixels():
    with pytest.raises(ValueError):
        handler.decode_image(_image_b64("BMP"))


def test_decompression_bomb_warning_is_an_error(monkeypatch):
    monkeypatch.setattr(handler.Image, "MAX_IMAGE_PIXELS", 1000)
    with pytest.raises(ValueError, match="oversized"):
        handler.decode_image(_image_b64("PNG", size=(40, 40)))


def test_class_names_come_from_the_response_then_the_environment(monkeypatch):
    monkeypatch.delenv("CLASS_NAMES", raising=False)
    assert handler.class_names({"class_names": ["cat", "dog"]}) == ("cat", "dog")
    assert handler.class_names({}) == ("negative", "positive")
    monkeypatch.setenv("CLASS_NAMES", "ok, defect")
    assert handler.class_names({"class_names": "bad"}) == ("ok", "defect")


def test_prediction_uses_the_class_names_and_counts_positives(runtime):
    runtime.answer["class_names"] = ["cat", "dog"]
    resp = handler.lambda_handler(_post_json({"image": _jpeg_b64()}), _context())
    body = json.loads(resp["body"])
    assert body["prediction"] == "dog"
    assert body["positive_class"] == "dog"
    assert set(body["probabilities"]) == {"cat", "dog"}
    names = {m["MetricName"] for m in runtime_metrics(runtime)}
    assert "PositivePredictions" in names
    assert "NegativePredictions" not in names


def runtime_metrics(runtime):
    return handler.boto3.client("cloudwatch").list_metrics(
        Namespace="image-classification/ModelPerformance"
    )["Metrics"]


def test_bedrock_is_not_called_without_a_guardrail(monkeypatch):
    calls = []
    monkeypatch.delenv("BEDROCK_GUARDRAIL_ID", raising=False)
    monkeypatch.delenv("BEDROCK_GUARDRAIL_VERSION", raising=False)
    monkeypatch.setattr(handler.boto3, "client", lambda name, **_: calls.append(name))
    assert handler.bedrock_explain(_jpeg_b64(), "JPEG", "dog", 0.55) is None
    assert calls == []


def test_bedrock_call_carries_the_guardrail_and_a_neutral_prompt(monkeypatch):
    sent = {}

    def invoke_model(**kwargs):
        sent.update(kwargs)
        text = {"output": {"message": {"content": [{"text": "looks like a dog"}]}}}
        return {"body": io.BytesIO(json.dumps(text).encode())}

    monkeypatch.setenv("BEDROCK_GUARDRAIL_ID", "gr-123")
    monkeypatch.setenv("BEDROCK_GUARDRAIL_VERSION", "1")
    monkeypatch.setattr(
        handler.boto3, "client", lambda name, **_: SimpleNamespace(invoke_model=invoke_model)
    )
    assert handler.bedrock_explain(_jpeg_b64(), "JPEG", "dog", 0.55) == "looks like a dog"
    assert sent["guardrailIdentifier"] == "gr-123"
    assert sent["guardrailVersion"] == "1"
    prompt = json.loads(sent["body"])["messages"][0]["content"][1]["text"]
    assert "'dog'" in prompt and "human reviewer" in prompt


def test_stored_records_from_before_never_return_the_s3_uri(aws):
    record = {"request_id": REQUEST_ID, "prediction": "dog", "image_s3_uri": "s3://b/k"}
    aws.s3.put_object(Bucket=BUCKET, Key=handler.result_key(REQUEST_ID), Body=json.dumps(record))
    got = handler.lambda_handler(
        {"httpMethod": "GET", "pathParameters": {"id": REQUEST_ID}}, _context()
    )
    assert "image_s3_uri" not in json.loads(got["body"])
