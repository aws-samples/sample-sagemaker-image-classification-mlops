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

The API URL and key (x-api-key header) come from --api-url and --api-key, or
the API_URL and API_KEY environment variables, for example the stack-inference
outputs api_gateway_url and api_key_value.

Usage:
  export API_URL="$(terraform -chdir=stack-inference output -raw api_gateway_url)"
  export API_KEY="$(terraform -chdir=stack-inference output -raw api_key_value)"
  python ops-scripts/test_api.py --image-path data/my-images/<class>/<file>.png
  python ops-scripts/test_api.py --data-path data/my-images --count 5  # 5 random images per class
  python ops-scripts/test_api.py --image-path <file> --explain  # also print the explanation summary
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import random
import sys
from pathlib import Path

import requests
from PIL import Image

IMAGE_PATTERNS = ("*.jpg", "*.jpeg", "*.png")


def encode_image(image_path: Path) -> str:
    """Base64 of the file as stored. The Lambda applies the training transform
    itself, so resizing or re-encoding here would add a second, different one."""
    with Image.open(image_path) as img:
        img.verify()
    return base64.b64encode(image_path.read_bytes()).decode()


def call_api(
    api_url: str, image_b64: str, api_key: str | None, timeout: int = 30, explain: bool = False
) -> dict:
    """POST the image to /predict. Raises on non-2xx."""
    headers = {"x-api-key": api_key} if api_key else {}
    payload = {"image": image_b64, "explain": True} if explain else {"image": image_b64}
    response = requests.post(
        f"{api_url.rstrip('/')}/predict",
        json=payload,
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
    """Pick up to `count` random images from each class folder under data_path."""
    pairs: list[tuple[Path, str]] = []
    rng = random.SystemRandom()
    for class_dir in sorted(p for p in data_path.iterdir() if p.is_dir()):
        found = sorted(f for pattern in IMAGE_PATTERNS for f in class_dir.glob(pattern))
        if not found:
            print(f" No images found in {class_dir}")
            continue
        selected = rng.sample(found, min(count, len(found)))
        pairs.extend((p, class_dir.name) for p in selected)
    return pairs


def print_explanations(explanations: dict) -> None:
    """One line per method: where Grad-CAM points and the strongest region value."""
    if "status" in explanations:
        print(f"   Explanations: {explanations['status']}")
        return
    gradcam = explanations.get("gradcam", {})
    if gradcam.get("top_region"):
        print(f"   Grad-CAM ({gradcam['target']}): top region box {gradcam['top_region']['box']}")
    shapley = explanations.get("region_shapley", {})
    if "values" in shapley:
        flat = [(v, r, c) for r, row in enumerate(shapley["values"]) for c, v in enumerate(row)]
        value, row, col = max(flat, key=lambda t: abs(t[0]))
        print(
            f"   Region Shapley: strongest region row {row} col {col} = {value:+.4f}, "
            f"sum {shapley['sum']:+.4f} over {shapley['permutations']} permutation(s)"
        )
    print(f"   explain_ms={explanations.get('explain_ms')}")


def test_api(
    api_url: str,
    api_key: str | None,
    image_path: Path | None,
    count: int,
    data_path: Path,
    explain: bool = False,
) -> bool:
    """Run one or more API calls and report accuracy against ground truth."""
    if image_path:
        # Single-image mode: the class folder the image sits in is its label.
        pairs = [(image_path, image_path.parent.name)]
    else:
        pairs = gather_test_images(data_path, count)

    if not pairs:
        print("No test images to evaluate")
        return False

    print(f"API URL: {api_url}")
    print(f"Testing {len(pairs)} image(s) via the API\n")

    results = {label: {"correct": 0, "total": 0} for _, label in pairs}
    correct = total = 0
    errors = 0

    for img_path, true_label in pairs:
        print(f"{img_path.name} (true: {true_label})")
        try:
            result = call_api(api_url, encode_image(img_path), api_key, explain=explain)
        except (OSError, RuntimeError, requests.RequestException) as exc:
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
        if explain:
            print_explanations(result.get("explanations") or {"status": "missing"})
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
        for label, r in sorted(results.items()):
            if r["total"] > 0:
                acc = r["correct"] / r["total"]
                print(f"   {label} accuracy: {acc:.3f} ({r['correct']}/{r['total']})")
    if errors:
        print(f"    API errors: {errors}")

    return errors == 0 and total > 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Test the deployed inference API")
    parser.add_argument(
        "--api-url",
        default=os.environ.get("API_URL"),
        help="API Gateway invoke URL (e.g. https://abc.execute-api.us-east-1.amazonaws.com/prod). "
        "Defaults to $API_URL.",
    )
    parser.add_argument(
        "--api-key",
        default=os.environ.get("API_KEY"),
        help="API key sent as x-api-key. Defaults to $API_KEY.",
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
        help="Local dataset root with one folder per class",
    )
    parser.add_argument(
        "--explain",
        action="store_true",
        help='Send "explain": true and print a summary of the Grad-CAM and region Shapley output',
    )
    args = parser.parse_args()

    api_url = args.api_url
    if not api_url:
        print("No API URL. Pass --api-url or set API_URL (stack-inference output api_gateway_url).")
        return 1

    api_key = args.api_key
    if not api_key:
        print(
            "No API key found; the request is sent without x-api-key and fails if the key is required."
        )

    success = test_api(
        api_url, api_key, args.image_path, args.count, args.data_path, explain=args.explain
    )
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
