#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import argparse
import json
import os
import random
import time
from pathlib import Path

import boto3
import numpy as np
from PIL import Image


def main() -> int:
    parser = argparse.ArgumentParser(description="Send traffic to endpoint")
    parser.add_argument("--endpoint", default="medical-image-classification-endpoint")
    parser.add_argument("--region", default=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))
    parser.add_argument(
        "--requests", type=int, default=200, help="Number of inference requests to send"
    )
    parser.add_argument(
        "--benign-dir", type=Path, default=Path("data/batch4_breakhis/breast_benign")
    )
    parser.add_argument(
        "--malignant-dir", type=Path, default=Path("data/batch4_breakhis/breast_malignant")
    )
    parser.add_argument("--sleep-sec", type=float, default=0.1, help="Pause between requests")
    args = parser.parse_args()

    rt = boto3.client("sagemaker-runtime", region_name=args.region)

    benign = list(args.benign_dir.glob("*.png"))[:500]
    malignant = list(args.malignant_dir.glob("*.png"))[:500]
    pool = [(p, 0) for p in benign] + [(p, 1) for p in malignant]
    random.shuffle(pool)

    sent = 0
    ok = 0
    errs = 0
    start = time.time()

    for i in range(min(args.requests, len(pool))):
        path, truth = pool[i]
        img = Image.open(path).convert("RGB").resize((224, 224))
        arr = np.asarray(img, dtype=np.float32) / 255.0

        try:
            resp = rt.invoke_endpoint(
                EndpointName=args.endpoint,
                ContentType="application/json",
                Body=json.dumps({"instances": [arr.tolist()]}),
            )
            score = float(json.loads(resp["Body"].read().decode())["predictions"][0][0])
            pred = 1 if score > 0.5 else 0
            ok += 1
            if (i + 1) % 25 == 0:
                rate = ok / (time.time() - start)
                print(
                    f"  [{i + 1}/{args.requests}] ok={ok} err={errs} "
                    f"rate={rate:.1f}/s  last score={score:.3f} pred={pred} truth={truth}"
                )
        except Exception as e:
            errs += 1
            if errs < 5:
                print(f"  ✗ {e}")
        sent += 1
        time.sleep(args.sleep_sec)

    dur = time.time() - start
    print()
    print(f"✓ Sent {sent} requests  ok={ok} err={errs}  duration={dur:.1f}s")
    return 0 if errs == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
