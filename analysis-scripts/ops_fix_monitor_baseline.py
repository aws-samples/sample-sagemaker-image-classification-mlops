#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import argparse
import json
import os

import boto3

BASELINE_S3_PREFIX = "monitoring/baselines/output-only"


STATISTICS = {
    "version": 0.0,
    "dataset": {
        "item_count": 10000,
    },
    "features": [
        {
            "name": "prediction_score",
            "inferred_type": "Fractional",
            "numerical_statistics": {
                "common": {
                    "num_present": 10000,
                    "num_missing": 0,
                },
                "mean": 0.50,
                "sum": 5000.0,
                "std_dev": 0.42,
                "min": 0.0,
                "max": 1.0,
                "distribution": {
                    "kll": {
                        "buckets": [
                            {"lower_bound": 0.00, "upper_bound": 0.10, "count": 3500},
                            {"lower_bound": 0.10, "upper_bound": 0.20, "count": 600},
                            {"lower_bound": 0.20, "upper_bound": 0.30, "count": 250},
                            {"lower_bound": 0.30, "upper_bound": 0.40, "count": 180},
                            {"lower_bound": 0.40, "upper_bound": 0.50, "count": 150},
                            {"lower_bound": 0.50, "upper_bound": 0.60, "count": 180},
                            {"lower_bound": 0.60, "upper_bound": 0.70, "count": 240},
                            {"lower_bound": 0.70, "upper_bound": 0.80, "count": 400},
                            {"lower_bound": 0.80, "upper_bound": 0.90, "count": 800},
                            {"lower_bound": 0.90, "upper_bound": 1.00, "count": 3700},
                        ],
                        "sketch": {"parameters": {"c": 0.64, "k": 2048.0}, "data": [[0.0, 1.0]]},
                    },
                },
            },
        },
    ],
}


CONSTRAINTS = {
    "version": 0.0,
    "features": [
        {
            "name": "prediction_score",
            "inferred_type": "Fractional",
            "completeness": 1.0,
            "num_constraints": {
                "is_non_negative": True,
            },
            "monitoringConfigOverrides": {},
        },
    ],
    "monitoring_config": {
        "evaluate_constraints": "Enabled",
        "emit_metrics": "Enabled",
        "datatype_check_threshold": 1.0,
        "domain_content_threshold": 1.0,
        "distribution_constraints": {
            "perform_comparison": "Enabled",
            "comparison_threshold": 0.5,
            "comparison_method": "Robust",
            "categorical_drift_method": "ChiSquared",
            "categorical_comparison_threshold": 0.1,
        },
    },
}


def main() -> int:
    parser = argparse.ArgumentParser(description="Upload synthetic Monitor baseline")
    parser.add_argument("--region", default=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))
    parser.add_argument("--bucket", default="medical-image-classification-dev-monitoring-51e179c7")
    args = parser.parse_args()

    s3 = boto3.client("s3", region_name=args.region)

    statistics_key = f"{BASELINE_S3_PREFIX}/statistics.json"
    constraints_key = f"{BASELINE_S3_PREFIX}/constraints.json"

    s3.put_object(
        Bucket=args.bucket,
        Key=statistics_key,
        Body=json.dumps(STATISTICS).encode(),
        ContentType="application/json",
    )
    s3.put_object(
        Bucket=args.bucket,
        Key=constraints_key,
        Body=json.dumps(CONSTRAINTS).encode(),
        ContentType="application/json",
    )

    stats_uri = f"s3://{args.bucket}/{statistics_key}"
    cons_uri = f"s3://{args.bucket}/{constraints_key}"
    print(f"✓ Uploaded statistics:  {stats_uri}")
    print(f"✓ Uploaded constraints: {cons_uri}")
    print()
    print("Next: update the two monitoring job definitions to reference these URIs:")
    print(f'  statistics_s3_uri   = "{stats_uri}"')
    print(f'  constraints_s3_uri  = "{cons_uri}"')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
