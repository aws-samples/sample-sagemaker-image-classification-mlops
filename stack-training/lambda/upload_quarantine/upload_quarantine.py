# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Upload quarantine: check each image as it lands in the raw-data bucket.

EventBridge invokes this Lambda for every Object Created event under the
training image prefix (IMAGE_PREFIX). The object is kept when it has an
allowed extension, opens with Pillow as the format that extension names, and
both sides are at least MIN_IMAGE_SIZE_PX. Otherwise it is moved out of the
training prefix: copied to QUARANTINE_PREFIX + <original key>, a
<key>.reason.json written next to it, and the original deleted. Each
quarantined file adds 1 to the QuarantinedImages metric.

The pipeline's validation step checks the same things again, so a file that
arrives while this Lambda is still behind is still caught before training.

Environment variables:
    IMAGE_PREFIX       Training image prefix, e.g. medical_image_data/
    QUARANTINE_PREFIX  Where failing files go, e.g. quarantine/ (outside IMAGE_PREFIX)
    MARKER_KEY         Batch-complete marker (key prefix) that starts the pipeline; never checked
    MIN_IMAGE_SIZE_PX  Minimum width and height in pixels (default 112)
    MAX_OBJECT_BYTES   Larger objects are quarantined unread (default 50 MiB)
    METRIC_NAMESPACE   CloudWatch namespace for QuarantinedImages
"""

from __future__ import annotations

import io
import json
import logging
import os
from datetime import UTC, datetime

import boto3
from botocore.exceptions import ClientError
from PIL import Image

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")
cloudwatch = boto3.client("cloudwatch")

# Extension -> the Pillow format it must decode as. The extensions match
# IMAGE_EXTENSIONS in scripts/mlops_common/constants.py, the only files the
# validation and preprocessing steps read.
ALLOWED_FORMATS = {".jpg": "JPEG", ".jpeg": "JPEG", ".png": "PNG"}
METRIC_NAME = "QuarantinedImages"


def _settings() -> dict:
    return {
        "image_prefix": os.environ.get("IMAGE_PREFIX", "medical_image_data/"),
        "quarantine_prefix": os.environ.get("QUARANTINE_PREFIX", "quarantine/"),
        "marker_key": os.environ.get("MARKER_KEY", ""),
        "min_size": int(os.environ.get("MIN_IMAGE_SIZE_PX", "112")),
        "max_bytes": int(os.environ.get("MAX_OBJECT_BYTES", str(50 * 1024 * 1024))),
        "namespace": os.environ.get("METRIC_NAMESPACE", "MLOps/DataQuality"),
    }


def check_image(key: str, body: bytes, min_size: int) -> str | None:
    """Why `body` fails the upload checks, or None when it passes."""
    extension = os.path.splitext(key)[1].lower()
    expected = ALLOWED_FORMATS.get(extension)
    if expected is None:
        allowed = ", ".join(sorted(ALLOWED_FORMATS))
        return f"extension '{extension or '(none)'}' is not one of {allowed}"
    try:
        with Image.open(io.BytesIO(body)) as img:
            img.verify()
        # verify() leaves the image unusable; reopen and decode the pixels so
        # truncated files fail too.
        with Image.open(io.BytesIO(body)) as img:
            actual = img.format
            img.load()
            width, height = img.size
    except Exception as exc:  # Pillow raises many types for malformed files
        return f"does not open as an image: {type(exc).__name__}: {exc}"
    if actual != expected:
        return f"content is {actual}, but extension '{extension}' expects {expected}"
    if min(width, height) < min_size:
        return f"{width}x{height} px is below the {min_size} px minimum side"
    return None


def quarantine_key(key: str, quarantine_prefix: str) -> str:
    return f"{quarantine_prefix}{key}"


def quarantine(bucket: str, key: str, etag: str, size: int, reason: str, settings: dict) -> str:
    """Copy the object under the quarantine prefix, record why, delete the original."""
    target = quarantine_key(key, settings["quarantine_prefix"])
    # CopySourceIfMatch: move exactly the object that was checked. A newer
    # upload under the same key fails the copy and gets its own event.
    # TaggingDirective REPLACE with no tags: uploads carry none, and it avoids
    # needing s3:GetObjectTagging on the source.
    s3.copy_object(
        Bucket=bucket,
        Key=target,
        CopySource={"Bucket": bucket, "Key": key},
        CopySourceIfMatch=etag,
        TaggingDirective="REPLACE",
    )
    record = {
        "source": f"s3://{bucket}/{key}",
        "quarantined_as": f"s3://{bucket}/{target}",
        "reason": reason,
        "etag": etag,
        "size_bytes": size,
        "min_image_size_px": settings["min_size"],
        "allowed_extensions": sorted(ALLOWED_FORMATS),
        "quarantined_at": datetime.now(UTC).isoformat(),
    }
    s3.put_object(
        Bucket=bucket,
        Key=f"{target}.reason.json",
        Body=json.dumps(record, indent=2).encode("utf8"),
        ContentType="application/json",
    )
    s3.delete_object(Bucket=bucket, Key=key)
    cloudwatch.put_metric_data(
        Namespace=settings["namespace"],
        MetricData=[
            {
                "MetricName": METRIC_NAME,
                "Dimensions": [{"Name": "Bucket", "Value": bucket}],
                "Value": 1,
                "Unit": "Count",
            }
        ],
    )
    return target


def lambda_handler(event, _context):
    settings = _settings()
    detail = event.get("detail", {})
    bucket = detail.get("bucket", {}).get("name", "")
    key = detail.get("object", {}).get("key", "")

    if not bucket or not key:
        logger.error("Event has no bucket or object key")
        return {"status": "ignored", "reason": "no bucket or key"}
    if (
        not key.startswith(settings["image_prefix"])
        or key.startswith(settings["quarantine_prefix"])
        or (settings["marker_key"] and key.startswith(settings["marker_key"]))
        or key.endswith("/")
    ):
        return {"status": "ignored", "key": key}

    try:
        obj = s3.get_object(Bucket=bucket, Key=key)
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") in ("NoSuchKey", "404"):
            # Already moved (a retried event) or replaced by a later sync.
            logger.info("s3://%s/%s is gone; nothing to check", bucket, key)
            return {"status": "gone", "key": key}
        raise
    etag = obj["ETag"]
    size = obj["ContentLength"]

    if size > settings["max_bytes"]:
        obj["Body"].close()
        reason = f"{size} bytes exceeds the {settings['max_bytes']} byte limit"
    else:
        reason = check_image(key, obj["Body"].read(), settings["min_size"])

    if reason is None:
        return {"status": "kept", "key": key}

    try:
        target = quarantine(bucket, key, etag, size, reason, settings)
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") == "PreconditionFailed":
            logger.info(
                "s3://%s/%s changed after the check; its new event re-checks it", bucket, key
            )
            return {"status": "changed", "key": key}
        raise
    logger.warning("Quarantined s3://%s/%s -> %s: %s", bucket, key, target, reason)
    return {"status": "quarantined", "key": key, "quarantine_key": target, "reason": reason}
