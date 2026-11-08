# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
"""Synthetic test traffic for the inference function (test_traffic.tf).

Each run sends a random number of training images from the raw-data bucket to
the inference Lambda, shaped like the API Gateway proxy event it receives, so
data capture, the drift job and the fairness job have recent predictions to
work on. Test deployments only.
"""

import base64
import json
import logging
import os
import random
import time

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")
lambda_client = boto3.client("lambda")
# The OS generator keeps scanners quiet; nothing here needs to be unpredictable.
_rng = random.SystemRandom()

RAW_BUCKET = os.environ["RAW_BUCKET"]
RAW_PREFIX = os.environ.get("RAW_PREFIX", "images/")
TARGET_FUNCTION = os.environ["TARGET_FUNCTION"]
MAX_REQUESTS = int(os.environ.get("MAX_REQUESTS", "5"))
EXPLAIN_RATE = float(os.environ.get("EXPLAIN_RATE", "0.1"))
MAX_GAP_SECONDS = float(os.environ.get("MAX_GAP_SECONDS", "20"))
IMAGE_EXTENSIONS = (".jpg", ".jpeg", ".png")

_keys: list[str] = []


def _image_keys() -> list[str]:
    """JPEG and PNG keys under the prefix, listed once per container."""
    if not _keys:
        paginator = s3.get_paginator("list_objects_v2")
        for page in paginator.paginate(Bucket=RAW_BUCKET, Prefix=RAW_PREFIX):
            for obj in page.get("Contents", []):
                key = obj["Key"]
                if key.lower().endswith(IMAGE_EXTENSIONS):
                    _keys.append(key)
    return _keys


def _predict(key: str, explain: bool) -> int:
    image = s3.get_object(Bucket=RAW_BUCKET, Key=key)["Body"].read()
    body = {"image": base64.b64encode(image).decode()}
    if explain:
        body["explain"] = True
    event = {
        "httpMethod": "POST",
        "resource": "/predict",
        "path": "/predict",
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }
    resp = lambda_client.invoke(FunctionName=TARGET_FUNCTION, Payload=json.dumps(event).encode())
    result = json.loads(resp["Payload"].read() or b"{}")
    return int(result.get("statusCode", 0))


def lambda_handler(event, context):
    keys = _image_keys()
    if not keys:
        logger.warning(json.dumps({"sent": 0, "reason": "no images under the prefix"}))
        return {"sent": 0}

    count = _rng.randint(1, max(1, MAX_REQUESTS))
    statuses = []
    for i in range(count):
        if i:
            time.sleep(_rng.uniform(0, MAX_GAP_SECONDS))
        statuses.append(_predict(_rng.choice(keys), _rng.random() < EXPLAIN_RATE))

    summary = {"sent": count, "ok": sum(1 for s in statuses if s == 200), "statuses": statuses}
    logger.info(json.dumps(summary))
    return summary
