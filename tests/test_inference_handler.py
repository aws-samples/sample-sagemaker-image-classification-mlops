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
    # 0.45 >= the model's own threshold 0.4, so malignant (a fixed 0.5 would say benign).
    assert body["prediction"] == "malignant"
    assert body["threshold_used"] == 0.4
    assert body["request_id"] == REQUEST_ID

    # No image bytes or model output in the logs.
    assert image[:40] not in caplog.text
    assert "0.45" not in caplog.text

    obj = aws.s3.get_object(Bucket=BUCKET, Key=f"predictions/{REQUEST_ID}/input.jpg")
    assert obj["ContentType"] == "image/jpeg"

    got = handler.lambda_handler(
        {"httpMethod": "GET", "pathParameters": {"id": REQUEST_ID}}, _context()
    )
    assert got["statusCode"] == 200
    assert json.loads(got["body"])["prediction"] == "malignant"


def test_no_cors_header_without_allowed_origin(aws):
    resp = handler.lambda_handler({"httpMethod": "POST", "body": "{}"}, _context())
    assert "Access-Control-Allow-Origin" not in resp["headers"]


def test_cors_header_uses_allowed_origin(aws, monkeypatch):
    monkeypatch.setenv("ALLOWED_ORIGIN", "https://app.example.com")
    resp = handler.lambda_handler({"httpMethod": "POST", "body": "{}"}, _context())
    assert resp["headers"]["Access-Control-Allow-Origin"] == "https://app.example.com"
