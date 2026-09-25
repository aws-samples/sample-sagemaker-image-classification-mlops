#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Send labelled images straight to the SageMaker endpoint to seed data capture.

Useful for exercising the drift job before real traffic exists. Images go
through the same shared transform the inference Lambda uses
(scripts/mlops_common/preprocess.py), each call carries an InferenceId, and
predictions use the threshold the endpoint reports.

Usage:
  python ops-scripts/ops_generate_endpoint_traffic.py --profile <profile> \\
      --endpoint medical-image-classification-endpoint --requests 200
"""

from __future__ import annotations

import argparse
import json
import os
import random
import sys
import time
import uuid
from pathlib import Path

import boto3
from PIL import Image

sys.path.append(str(Path(__file__).resolve().parent.parent / "scripts"))
from mlops_common.preprocess import preprocess
from mlops_common.scores import extract_score, extract_threshold


def main() -> int:
    parser = argparse.ArgumentParser(description="Send traffic to the endpoint")
    parser.add_argument("--profile", required=True, help="AWS CLI profile to use")
    parser.add_argument("--endpoint", default="medical-image-classification-endpoint")
    parser.add_argument("--region", default=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))
    parser.add_argument("--requests", type=int, default=200, help="Number of requests to send")
    parser.add_argument(
        "--benign-dir", type=Path, default=Path("data/batch4_breakhis/breast_benign")
    )
    parser.add_argument(
        "--malignant-dir", type=Path, default=Path("data/batch4_breakhis/breast_malignant")
    )
    parser.add_argument("--sleep-sec", type=float, default=0.1, help="Pause between requests")
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    session = boto3.Session(profile_name=args.profile, region_name=args.region)
    rt = session.client("sagemaker-runtime")

    benign = sorted(args.benign_dir.glob("*.png"))[:500]
    malignant = sorted(args.malignant_dir.glob("*.png"))[:500]
    pool = [(p, 0) for p in benign] + [(p, 1) for p in malignant]
    random.Random(args.seed).shuffle(pool)  # nosec B311 - seeded test-traffic order, not security

    ok = errs = 0
    start = time.time()
    total = min(args.requests, len(pool))
    for i, (path, truth) in enumerate(pool[:total]):
        with Image.open(path) as img:
            model_input = preprocess(img)
        try:
            resp = rt.invoke_endpoint(
                EndpointName=args.endpoint,
                ContentType="application/json",
                Body=json.dumps({"instances": [model_input.tolist()]}),
                InferenceId=str(uuid.uuid4()),
            )
            result = json.loads(resp["Body"].read().decode())
            score = extract_score(result)
            threshold = extract_threshold(result)
            if score is None or threshold is None:
                raise ValueError("unrecognised endpoint response")
            pred = 1 if score >= threshold else 0
            ok += 1
            if (i + 1) % 25 == 0:
                rate = ok / (time.time() - start)
                print(
                    f"  [{i + 1}/{total}] ok={ok} err={errs} rate={rate:.1f}/s "
                    f"last score={score:.3f} threshold={threshold:.2f} pred={pred} truth={truth}"
                )
        except Exception as e:
            errs += 1
            if errs < 5:
                print(f"  error: {e}")
        time.sleep(args.sleep_sec)

    print(f"\nSent {total} requests ok={ok} err={errs} duration={time.time() - start:.1f}s")
    return 0 if errs == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
