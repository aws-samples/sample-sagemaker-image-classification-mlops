# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Scheduled drift detection over endpoint data-capture output (Part 3).

Runs as a scheduled Amazon SageMaker Processing job. Reads the malignant
probabilities the endpoint returned (data capture, endpointOutput) for the
last --lookback-hours, compares their distribution with the baseline score
distribution, and publishes a Population Stability Index (PSI) to CloudWatch.
The drift alarm and the EventBridge retraining rule read that metric.

This is prediction (output) drift: PSI over the score distribution in equal
bins on [0, 1]. It catches shifts that change what the model outputs; it does
not inspect the input pixels.

    PSI = sum over bins of (pct_live - pct_baseline) * ln(pct_live / pct_baseline)

Conventional reading: < 0.1 no meaningful shift, 0.1-0.2 moderate, > 0.2
significant. The alarm threshold is supplied by Terraform (drift_threshold).
Nothing is published without a baseline or with fewer than --min-samples live
scores, so quiet periods cannot raise a false alarm.
"""

from __future__ import annotations

import argparse
import json
import logging
import math
import os
import sys
from collections.abc import Iterable
from datetime import datetime, timedelta, timezone

import boto3

# The job's code directory holds mlops_common next to this file; a local
# checkout has it one level up, in scripts/.
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from mlops_common.capture import iter_capture_records
from mlops_common.s3io import iter_capture_keys
from mlops_common.scores import clamp01

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Defaults come from the environment when set (SageMaker Processing passes them
# through Environment), and are overridable per-run by the CLI flags below.
_ENV = os.environ.get

# Smoothing floor so an empty bin cannot make the log term diverge.
_EPSILON = 1e-4


def _clean(values: Iterable) -> list[float]:
    """Finite scores clipped to [0, 1]; NaN, inf and non-numbers are dropped."""
    out = []
    for v in values:
        if isinstance(v, bool):
            continue
        try:
            f = float(v)
        except (TypeError, ValueError):
            continue
        if math.isfinite(f):
            out.append(min(max(f, 0.0), 1.0))
    return out


def _histogram(values: list[float], bins: int) -> list[float]:
    """Fractional counts across `bins` equal-width bins over [0, 1]."""
    counts = [0] * bins
    for v in values:
        counts[min(int(v * bins), bins - 1)] += 1  # v == 1.0 lands in the last bin
    total = len(values) or 1
    return [c / total for c in counts]


def population_stability_index(live, baseline, bins: int = 10) -> float | None:
    """PSI between two score distributions; 0.0 means identical.

    Non-finite values are dropped first (a NaN would otherwise crash the bin
    index). Returns None when either side has no usable value.
    """
    live_clean = _clean(live)
    base_clean = _clean(baseline)
    if not live_clean or not base_clean:
        return None
    psi = 0.0
    for lp, bp in zip(_histogram(live_clean, bins), _histogram(base_clean, bins)):
        lp = max(lp, _EPSILON)
        bp = max(bp, _EPSILON)
        psi += (lp - bp) * math.log(lp / bp)
    return psi


def scores_from_capture(body: str) -> list[float]:
    """Malignant probabilities from one data-capture JSON Lines file."""
    return [record["score"] for record in iter_capture_records(body)]


def _load_baseline(s3, bucket: str, key: str) -> list[float]:
    """Load baseline scores from S3; an empty list if absent or unusable.

    Accepts either an explicit score list ({"scores": [...]}) or a
    statistics.json-style histogram, and reconstructs bin midpoints from the
    latter. An empty result means no PSI is published this run.
    """
    if not key:
        return []
    try:
        body = s3.get_object(Bucket=bucket, Key=key)["Body"].read().decode("utf8")
    except Exception as exc:
        logger.warning("baseline %s unavailable (%s); skipping this run", key, exc)
        return []

    doc = json.loads(body)
    # Preferred: an explicit score list. Fall back to a statistics.json-style
    # histogram, reconstructing bin midpoints from the buckets.
    if isinstance(doc, dict) and isinstance(doc.get("scores"), list):
        return _clean(doc["scores"])

    for feature in doc.get("features", []):
        dist = feature.get("numerical_statistics", {}).get("distribution", {})
        buckets = dist.get("kll", {}).get("buckets") or dist.get("buckets") or []
        rebuilt: list[float] = []
        for b in buckets:
            lower = clamp01(b.get("lower_bound", 0.0)) or 0.0
            upper = clamp01(b.get("upper_bound", 1.0)) or 1.0
            count = int(b.get("count", 0))
            rebuilt.extend([(lower + upper) / 2] * count)
        if rebuilt:
            return rebuilt

    logger.warning("baseline %s had no usable distribution", key)
    return []


def run(
    monitoring_bucket: str,
    capture_prefix: str,
    baseline_key: str,
    namespace: str,
    metric_name: str,
    endpoint_name: str,
    lookback_hours: int,
    min_samples: int,
    num_bins: int,
) -> int:
    if not monitoring_bucket or not namespace or not endpoint_name:
        logger.error("--monitoring-bucket, --metric-namespace and --endpoint-name are required")
        return 1

    s3 = boto3.client("s3")
    cloudwatch = boto3.client("cloudwatch")

    baseline = _load_baseline(s3, monitoring_bucket, baseline_key)
    if not baseline:
        # No baseline means no comparison is possible. Emit nothing so the alarm
        # stays in its configured missing-data state rather than reading 0.0 as
        # "healthy".
        logger.info("no baseline available; not publishing a metric")
        return 0

    since = datetime.now(timezone.utc) - timedelta(hours=lookback_hours)
    live: list[float] = []
    keys_read = 0
    for key in iter_capture_keys(s3, monitoring_bucket, capture_prefix, endpoint_name, since):
        try:
            body = s3.get_object(Bucket=monitoring_bucket, Key=key)["Body"].read().decode("utf8")
        except Exception as exc:
            logger.warning("skipping %s (%s)", key, exc)
            continue
        live.extend(scores_from_capture(body))
        keys_read += 1

    logger.info("read %d capture files, %d live scores", keys_read, len(live))

    if len(live) < min_samples:
        # Too little traffic to judge. Publishing a value here would produce
        # false drift alarms on quiet periods.
        logger.info("only %d samples (< %d); not publishing", len(live), min_samples)
        return 0

    psi = population_stability_index(live, baseline, num_bins)
    if psi is None:
        logger.info("no finite scores to compare; not publishing")
        return 0
    logger.info("PSI=%.4f over %d live vs %d baseline scores", psi, len(live), len(baseline))

    cloudwatch.put_metric_data(
        Namespace=namespace,
        MetricData=[
            {
                "MetricName": metric_name,
                "Dimensions": [{"Name": "EndpointName", "Value": endpoint_name}],
                "Value": psi,
                "Unit": "None",
                "Timestamp": datetime.now(timezone.utc),
            }
        ],
    )

    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Compute prediction-score PSI from endpoint data capture (Part 3)"
    )
    parser.add_argument("--monitoring-bucket", default=_ENV("MONITORING_BUCKET", ""))
    parser.add_argument("--capture-prefix", default=_ENV("DATA_CAPTURE_PREFIX", "data-capture"))
    parser.add_argument("--baseline-key", default=_ENV("BASELINE_KEY", ""))
    parser.add_argument("--metric-namespace", default=_ENV("METRIC_NAMESPACE", ""))
    parser.add_argument("--metric-name", default=_ENV("METRIC_NAME", "prediction_score_psi"))
    parser.add_argument("--endpoint-name", default=_ENV("ENDPOINT_NAME", ""))
    parser.add_argument("--lookback-hours", type=int, default=int(_ENV("LOOKBACK_HOURS", "24")))
    parser.add_argument("--min-samples", type=int, default=int(_ENV("MIN_SAMPLES", "30")))
    parser.add_argument("--num-bins", type=int, default=int(_ENV("NUM_BINS", "10")))
    args = parser.parse_args()

    return run(
        monitoring_bucket=args.monitoring_bucket,
        capture_prefix=args.capture_prefix,
        baseline_key=args.baseline_key,
        namespace=args.metric_namespace,
        metric_name=args.metric_name,
        endpoint_name=args.endpoint_name,
        lookback_hours=args.lookback_hours,
        min_samples=args.min_samples,
        num_bins=args.num_bins,
    )


if __name__ == "__main__":
    raise SystemExit(main())
