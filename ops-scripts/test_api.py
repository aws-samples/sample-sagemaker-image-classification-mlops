#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""
End-to-end check of the deployed inference API.

Calls the real API Gateway `/predict` endpoint with base64-encoded images
from the local dataset and verifies that:
  - API returns 200
  - Response contains prediction + confidence
  - Predicted class matches the known ground-truth label

This is the script the README points at for smoke-testing after deploy.
It does NOT bypass the API to hit SageMaker directly (earlier versions did,
which made it useless for validating the API path).

The API requires an API key (x-api-key header). It comes from --api-key, the
API_KEY environment variable, or `terraform output -raw api_key_value` in
stack-inference, in that order.

Usage:
  python ops-scripts/test_api.py                              # pulls API URL and key from terraform output
  API_KEY="$(terraform -chdir=stack-inference output -raw api_key_value)" python ops-scripts/test_api.py
  python ops-scripts/test_api.py --api-url https://<...>/prod --image-path data/test/breast_benign_0338.jpg
  python ops-scripts/test_api.py --count 5                    # test 5 random images from each class
"""

from __future__ import annotations

import argparse
import base64
import glob
import json
import os
import random
import subprocess  # nosec B404 - runs only the terraform CLI with a fixed argument list
import sys
from pathlib import Path

import requests
from PIL import Image


def terraform_output(name: str) -> str | None:
    """Read one raw output from the inference root."""
    project_root = Path(__file__).resolve().parent.parent
    tf_dir = project_root / "stack-inference"
    try:
        result = subprocess.run(  # nosec B603 B607 - fixed argv, no shell; terraform from PATH
            ["terraform", "output", "-raw", name],
            cwd=tf_dir,
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except FileNotFoundError:
        print("terraform CLI not found on PATH")
    return None


def encode_image(image_path: Path) -> str:
    """Base64 of the file as stored. The Lambda applies the training transform
    itself, so resizing or re-encoding here would add a second, different one."""
    with Image.open(image_path) as img:
        img.verify()
    return base64.b64encode(image_path.read_bytes()).decode()


def call_api(api_url: str, image_b64: str, api_key: str | None, timeout: int = 30) -> dict:
    """POST the image to /predict. Raises on non-2xx."""
    headers = {"x-api-key": api_key} if api_key else {}
    response = requests.post(
        f"{api_url.rstrip('/')}/predict",
        json={"image": image_b64},
        headers=headers,
        timeout=timeout,
    )
    if response.status_code != 200:
        raise RuntimeError(f"API returned HTTP {response.status_code}: {response.text[:500]}")

    try:
        return response.json()
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"API response is not valid JSON: {response.text[:500]}") from exc


def gather_test_images(data_path: Path, count: int) -> list[tuple[Path, str]]:
    """Pick up to `count` random images from each class under data/breast_*/."""
    extensions = ("*.jpg", "*.jpeg", "*.png")
    pairs: list[tuple[Path, str]] = []

    for label, subdir in (("benign", "breast_benign"), ("malignant", "breast_malignant")):
        found: list[str] = []
        for ext in extensions:
            found.extend(glob.glob(str(data_path / subdir / ext)))
        if not found:
            print(f" No images found in {data_path / subdir}")
            continue
        selected = random.sample(found, min(count, len(found)))  # nosec B311 - picks test images, not security
        pairs.extend((Path(p), label) for p in selected)

    return pairs


def test_api(
    api_url: str, api_key: str | None, image_path: Path | None, count: int, data_path: Path
) -> bool:
    """Run one or more API calls and report accuracy against ground truth."""
    if image_path:
        # Single-image mode - infer label from the filename
        label = "malignant" if "malignant" in image_path.name else "benign"
        pairs = [(image_path, label)]
    else:
        pairs = gather_test_images(data_path, count)

    if not pairs:
        print("No test images to evaluate")
        return False

    print(f"API URL: {api_url}")
    print(f"Testing {len(pairs)} image(s) via the API\n")

    results = {"benign": {"correct": 0, "total": 0}, "malignant": {"correct": 0, "total": 0}}
    correct = total = 0
    errors = 0

    for img_path, true_label in pairs:
        print(f"{img_path.name} (true: {true_label})")
        try:
            result = call_api(api_url, encode_image(img_path), api_key)
        except Exception as exc:
            print(f"   API call failed: {exc}")
            errors += 1
            continue

        prediction = result.get("prediction")
        confidence = result.get("confidence")
        if prediction is None or confidence is None:
            print(f"   Malformed response: {result}")
            errors += 1
            continue

        threshold = result.get("threshold_used")
        threshold_text = (
            f"  threshold={threshold:.3f}" if isinstance(threshold, (int, float)) else ""
        )
        print(f"   Predicted: {prediction}  confidence={confidence:.3f}{threshold_text}")
        results[true_label]["total"] += 1
        total += 1
        if prediction == true_label:
            results[true_label]["correct"] += 1
            correct += 1
            print("   Correct")
        else:
            print("   Wrong")

    print("\nAPI Test Results:")
    if total > 0:
        overall = correct / total
        print(f"   Overall Accuracy: {overall:.3f} ({correct}/{total})")
        for label in ("benign", "malignant"):
            r = results[label]
            if r["total"] > 0:
                acc = r["correct"] / r["total"]
                print(f"   {label.capitalize()} Accuracy: {acc:.3f} ({r['correct']}/{r['total']})")
    if errors:
        print(f"    API errors: {errors}")

    return errors == 0 and total > 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Test the deployed inference API")
    parser.add_argument(
        "--api-url",
        help="API Gateway invoke URL (e.g. https://abc.execute-api.us-east-1.amazonaws.com/prod). "
        "Defaults to `terraform output -raw api_gateway_url`.",
    )
    parser.add_argument(
        "--api-key",
        help="API key sent as x-api-key. Defaults to $API_KEY, then "
        "`terraform output -raw api_key_value`.",
    )
    parser.add_argument(
        "--image-path",
        type=Path,
        help="Single image to test. When omitted, samples random images from --data-path.",
    )
    parser.add_argument(
        "--count",
        type=int,
        default=2,
        help="Images per class to sample when --image-path is not given",
    )
    parser.add_argument(
        "--data-path",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "data",
        help="Local dataset root (expects breast_benign/ and breast_malignant/ subdirs)",
    )
    args = parser.parse_args()

    api_url = args.api_url or terraform_output("api_gateway_url")
    if not api_url:
        print("Could not determine API URL. Pass --api-url or run from a deployed project.")
        return 1

    api_key = args.api_key or os.environ.get("API_KEY") or terraform_output("api_key_value")
    if not api_key:
        print(
            "No API key found; the request is sent without x-api-key and fails if the key is required."
        )

    success = test_api(api_url, api_key, args.image_path, args.count, args.data_path)
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
