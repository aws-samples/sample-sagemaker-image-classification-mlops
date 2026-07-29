#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import glob
import json
import os

import boto3
import numpy as np
from PIL import Image


def test_accuracy():
    # Get endpoint name from environment or use default
    endpoint_name = os.environ.get(
        "SAGEMAKER_ENDPOINT_NAME", "medical-image-classification-endpoint"
    )
    region = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")

    sagemaker = boto3.client("sagemaker-runtime", region_name=region)

    # Get 50 images from each class - support multiple formats
    data_path = "../data"
    benign_images = (
        glob.glob(f"{data_path}/breast_benign/*.jpg")
        + glob.glob(f"{data_path}/breast_benign/*.jpeg")
        + glob.glob(f"{data_path}/breast_benign/*.png")
    )[:50]
    malignant_images = (
        glob.glob(f"{data_path}/breast_malignant/*.jpg")
        + glob.glob(f"{data_path}/breast_malignant/*.jpeg")
        + glob.glob(f"{data_path}/breast_malignant/*.png")
    )[:50]

    print(f"Testing with {len(benign_images)} benign and {len(malignant_images)} malignant images")
    print(f"Using endpoint: {endpoint_name}")

    correct = 0
    total = 0
    results = {"benign": {"correct": 0, "total": 0}, "malignant": {"correct": 0, "total": 0}}

    # Test benign images
    print("Testing benign images...")
    for _i, img_path in enumerate(benign_images):
        try:
            img = Image.open(img_path).convert("RGB").resize((224, 224))
            img_array = np.array(img, dtype=np.float32) / 255.0

            response = sagemaker.invoke_endpoint(
                EndpointName=endpoint_name,
                ContentType="application/json",
                Body=json.dumps({"instances": [img_array.tolist()]}),
            )

            result = json.loads(response["Body"].read().decode())
            score = result["predictions"][0][0]
            prediction = "malignant" if score > 0.5 else "benign"

            results["benign"]["total"] += 1
            total += 1
            if prediction == "benign":
                results["benign"]["correct"] += 1
                correct += 1

        except Exception as e:
            print(f"Error with {img_path}: {e}")

    # Test malignant images
    print("Testing malignant images...")
    for _i, img_path in enumerate(malignant_images):
        try:
            img = Image.open(img_path).convert("RGB").resize((224, 224))
            img_array = np.array(img, dtype=np.float32) / 255.0

            response = sagemaker.invoke_endpoint(
                EndpointName=endpoint_name,
                ContentType="application/json",
                Body=json.dumps({"instances": [img_array.tolist()]}),
            )

            result = json.loads(response["Body"].read().decode())
            score = result["predictions"][0][0]
            prediction = "malignant" if score > 0.5 else "benign"

            results["malignant"]["total"] += 1
            total += 1
            if prediction == "malignant":
                results["malignant"]["correct"] += 1
                correct += 1

        except Exception as e:
            print(f"Error with {img_path}: {e}")

    # Calculate metrics
    overall_accuracy = correct / total if total > 0 else 0
    benign_accuracy = (
        results["benign"]["correct"] / results["benign"]["total"]
        if results["benign"]["total"] > 0
        else 0
    )
    malignant_accuracy = (
        results["malignant"]["correct"] / results["malignant"]["total"]
        if results["malignant"]["total"] > 0
        else 0
    )

    print("\n📊 Accuracy Results:")
    print(f"Overall Accuracy: {overall_accuracy:.3f} ({correct}/{total})")
    print(
        f"Benign Accuracy: {benign_accuracy:.3f} ({results['benign']['correct']}/{results['benign']['total']})"
    )
    print(
        f"Malignant Accuracy: {malignant_accuracy:.3f} ({results['malignant']['correct']}/{results['malignant']['total']})"
    )


if __name__ == "__main__":
    test_accuracy()
