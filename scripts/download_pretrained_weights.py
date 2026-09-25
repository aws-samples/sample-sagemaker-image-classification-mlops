#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""
Download pre-trained ImageNet weights for VGG16, DenseNet121, and EfficientNetV2M
and upload to S3 for use with network isolation.
"""

import os
import shutil
import tempfile

import boto3
from botocore.exceptions import ClientError
from tensorflow.keras.applications import VGG16, DenseNet121, EfficientNetV2M


def download_and_upload_weights(bucket_name):
    """Download ImageNet weights and upload to S3 if not already present."""
    s3 = boto3.client("s3")
    # Use tempfile.mkdtemp() instead of a hardcoded /tmp path: portable
    # across macOS / Linux / container runtimes, automatically unique per
    # invocation (no collisions between parallel runs), and silences
    # bandit B108 (hardcoded temp directory).
    weights_dir = tempfile.mkdtemp(prefix="pretrained_weights_")

    models = {
        "vgg16": lambda: VGG16(weights="imagenet", include_top=False, input_shape=(224, 224, 3)),
        "densenet121": lambda: DenseNet121(
            weights="imagenet", include_top=False, input_shape=(224, 224, 3)
        ),
        "efficientnet": lambda: EfficientNetV2M(
            weights="imagenet", include_top=False, input_shape=(224, 224, 3)
        ),
    }

    try:
        for name, model_fn in models.items():
            s3_key = f"pretrained-weights/{name}_weights.h5"

            # Skip if weights already uploaded - idempotent on repeat CI/CD runs.
            try:
                s3.head_object(Bucket=bucket_name, Key=s3_key)
                print(f"{name} weights already exist in S3, skipping")
                continue
            except ClientError as exc:
                # 404 = object missing, proceed with download. Anything else = re-raise.
                if exc.response.get("Error", {}).get("Code") not in ("404", "NoSuchKey"):
                    raise

            print(f"Downloading {name} weights...")
            model = model_fn()
            weights_path = os.path.join(weights_dir, f"{name}_weights.h5")
            model.save_weights(weights_path)

            print(f"Uploading {name} weights to S3...")
            s3.upload_file(weights_path, bucket_name, s3_key)
            print(f"{name} weights uploaded")

            os.remove(weights_path)
    finally:
        # Cleanup the whole temp directory even on failure.
        shutil.rmtree(weights_dir, ignore_errors=True)

    print("All weights processed successfully")


if __name__ == "__main__":
    import sys

    if len(sys.argv) != 2:
        print("Usage: python download_pretrained_weights.py <bucket-name>")
        sys.exit(1)

    download_and_upload_weights(sys.argv[1])
