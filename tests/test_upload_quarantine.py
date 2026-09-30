# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""The upload quarantine Lambda keeps good images and moves the rest aside."""

import io
import json

import boto3
import pytest
from conftest import load_module
from mlops_common.constants import IMAGE_EXTENSIONS
from moto import mock_aws
from PIL import Image

quarantine = load_module(
    "stack-training/lambda/upload_quarantine/upload_quarantine.py", "upload_quarantine"
)

BUCKET = "example-raw-data"
PREFIX = "medical_image_data/"
QUARANTINE = "quarantine/"
MARKER = "medical_image_data/.batch_complete"
NAMESPACE = "example/DataQuality"


def _image(size=(224, 224), fmt="PNG") -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", size, (200, 120, 180)).save(buf, format=fmt)
    return buf.getvalue()


@pytest.fixture
def s3(monkeypatch):
    for key, value in {
        "IMAGE_PREFIX": PREFIX,
        "QUARANTINE_PREFIX": QUARANTINE,
        "MARKER_KEY": MARKER,
        "MIN_IMAGE_SIZE_PX": "112",
        "METRIC_NAMESPACE": NAMESPACE,
    }.items():
        monkeypatch.setenv(key, value)
    with mock_aws():
        client = boto3.client("s3", region_name="us-east-1")
        client.create_bucket(Bucket=BUCKET)
        cloudwatch = boto3.client("cloudwatch", region_name="us-east-1")
        monkeypatch.setattr(quarantine, "s3", client)
        monkeypatch.setattr(quarantine, "cloudwatch", cloudwatch)
        yield client


def _upload(s3, key, body):
    s3.put_object(Bucket=BUCKET, Key=key, Body=body)
    event = {
        "source": "aws.s3",
        "detail-type": "Object Created",
        "detail": {"bucket": {"name": BUCKET}, "object": {"key": key}},
    }
    return quarantine.lambda_handler(event, None)


def _keys(s3):
    return sorted(o["Key"] for o in s3.list_objects_v2(Bucket=BUCKET).get("Contents", []))


def _reason(s3, key):
    body = s3.get_object(Bucket=BUCKET, Key=f"{QUARANTINE}{key}.reason.json")["Body"].read()
    return json.loads(body)


def _quarantined_count():
    stats = quarantine.cloudwatch.list_metrics(Namespace=NAMESPACE, MetricName="QuarantinedImages")
    return len(stats["Metrics"])


def test_good_image_is_kept(s3):
    key = f"{PREFIX}breast_benign/SOB_B_A-14-22549AB-40-001.png"
    result = _upload(s3, key, _image())
    assert result["status"] == "kept"
    assert _keys(s3) == [key]
    assert _quarantined_count() == 0


def test_good_jpeg_is_kept(s3):
    key = f"{PREFIX}breast_malignant/SOB_M_DC-14-2523-40-001.jpg"
    assert _upload(s3, key, _image(fmt="JPEG"))["status"] == "kept"


def test_corrupt_image_is_quarantined(s3):
    key = f"{PREFIX}breast_benign/corrupt.png"
    truncated = _image()[:200]
    result = _upload(s3, key, truncated)
    assert result["status"] == "quarantined"
    assert _keys(s3) == [f"{QUARANTINE}{key}", f"{QUARANTINE}{key}.reason.json"]
    assert s3.get_object(Bucket=BUCKET, Key=f"{QUARANTINE}{key}")["Body"].read() == truncated
    record = _reason(s3, key)
    assert "does not open as an image" in record["reason"]
    assert record["source"] == f"s3://{BUCKET}/{key}"
    assert _quarantined_count() == 1


def test_too_small_image_is_quarantined(s3):
    key = f"{PREFIX}breast_malignant/tiny.png"
    result = _upload(s3, key, _image(size=(64, 300)))
    assert result["status"] == "quarantined"
    assert "64x300 px is below the 112 px minimum" in _reason(s3, key)["reason"]
    assert f"{PREFIX}breast_malignant/tiny.png" not in _keys(s3)


def test_non_image_is_quarantined(s3):
    key = f"{PREFIX}breast_benign/notes.txt"
    result = _upload(s3, key, b"not an image")
    assert result["status"] == "quarantined"
    assert "extension '.txt' is not one of" in _reason(s3, key)["reason"]


def test_non_image_with_image_extension_is_quarantined(s3):
    key = f"{PREFIX}breast_benign/fake.png"
    assert _upload(s3, key, b"%PDF-1.7 not a png")["status"] == "quarantined"
    assert "does not open as an image" in _reason(s3, key)["reason"]


def test_wrong_format_for_extension_is_quarantined(s3):
    key = f"{PREFIX}breast_benign/really-a-jpeg.png"
    assert _upload(s3, key, _image(fmt="JPEG"))["status"] == "quarantined"
    assert "content is JPEG" in _reason(s3, key)["reason"]


def test_marker_and_other_prefixes_are_ignored(s3):
    assert _upload(s3, MARKER, b"batch_id: 1")["status"] == "ignored"
    assert _upload(s3, "dvc-cache/ab/cdef", b"blob")["status"] == "ignored"
    assert _upload(s3, f"{QUARANTINE}{PREFIX}x.png", b"x")["status"] == "ignored"
    assert _quarantined_count() == 0


def test_object_already_gone_is_not_an_error(s3):
    event = {"detail": {"bucket": {"name": BUCKET}, "object": {"key": f"{PREFIX}gone.png"}}}
    assert quarantine.lambda_handler(event, None)["status"] == "gone"


def test_allowed_extensions_match_the_pipeline():
    assert set(quarantine.ALLOWED_FORMATS) == set(IMAGE_EXTENSIONS)
