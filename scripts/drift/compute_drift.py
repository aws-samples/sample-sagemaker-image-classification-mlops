# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Scheduled drift detection over endpoint data-capture output (Part 3).

Runs as a scheduled Amazon SageMaker Processing job. Reads the endpoint's
captured prediction scores from S3, compares their distribution against the
training baseline, and publishes a Population Stability Index (PSI) to
CloudWatch as a custom metric. The drift alarm and the EventBridge rule that
starts retraining both read that metric, so the closed loop is unchanged - only
the producer of the drift signal differs.

PSI is the standard statistic for numeric feature drift:

    PSI = sum over bins of (pct_live - pct_baseline) * ln(pct_live / pct_baseline)

Conventional reading: < 0.1 no meaningful shift, 0.1-0.2 moderate, > 0.2
significant. The alarm threshold is supplied by Terraform (drift_threshold).
"""

from __future__ import annotations

import argparse
import json
import logging
import math
import os
from datetime import UTC, datetime, timedelta

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Defaults come from the environment when set (SageMaker Processing passes them
# through Environment), and are overridable per-run by the CLI flags below.
_ENV = os.environ.get

# Smoothing floor so an empty bin cannot make the log term diverge.
_EPSILON = 1e-4


def _histogram(values: list[float], bins: int) -> list[float]:
    """Fractional counts of values across `bins` equal-width bins over [0, 1]."""
    counts = [0] * bins
    for v in values:
        idx = min(int(v * bins), bins - 1)  # v == 1.0 lands in the last bin
        counts[idx] += 1
    total = len(values) or 1
    return [c / total for c in counts]


def population_stability_index(live: list[float], baseline: list[float], bins: int) -> float:
    """PSI between two score distributions. 0.0 means identical."""
    live_pct = _histogram(live, bins)
    base_pct = _histogram(baseline, bins)
    psi = 0.0
    for lp, bp in zip(live_pct, base_pct):
        lp = max(lp, _EPSILON)
        bp = max(bp, _EPSILON)
        psi += (lp - bp) * math.log(lp / bp)
    return psi


def _iter_capture_keys(s3, bucket: str, prefix: str, since: datetime):
    """Yield data-capture object keys modified since `since`."""
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            if obj["LastModified"] >= since and obj["Key"].endswith(".jsonl"):
                yield obj["Key"]


def _scores_from_capture(body: str) -> list[float]:
    """Extract malignant probabilities from data-capture JSON Lines records.

    Capture format wraps the endpoint response under
    captureData.endpointOutput.data, which itself holds the model's JSON.
    Malformed lines are skipped rather than failing the whole run.
    """
    scores: list[float] = []
    for line in body.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
            raw = record["captureData"]["endpointOutput"]["data"]
            payload = json.loads(raw) if isinstance(raw, str) else raw
        except (json.JSONDecodeError, KeyError, TypeError):
            continue

        score = _extract_score(payload)
        if score is not None:
            scores.append(score)
    return scores


def _extract_score(payload) -> float | None:
    """Pull a single malignant probability out of a model response."""
    if isinstance(payload, dict):
        if "predictions" in payload:
            preds = payload["predictions"]
            first = preds[0] if isinstance(preds, list) and preds else preds
            if isinstance(first, list):
                return _clamp(first[1] if len(first) == 2 else first[0])
            return _clamp(first)
        for key in ("malignant_probability", "confidence", "probability", "score"):
            if key in payload:
                return _clamp(payload[key])
    elif isinstance(payload, (int, float)):
        return _clamp(payload)
    return None


def _clamp(value) -> float | None:
    try:
        f = float(value)
    except (TypeError, ValueError):
        return None
    return min(max(f, 0.0), 1.0)


def _load_baseline(s3, bucket: str, key: str) -> list[float]:
    """Load baseline scores, or synthesise a uniform baseline if absent.

    Accepts either an explicit score list or a statistics.json-style
    histogram, and reconstructs bin midpoints from the latter.
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
        return [s for s in (_clamp(v) for v in doc["scores"]) if s is not None]

    for feature in doc.get("features", []):
        dist = feature.get("numerical_statistics", {}).get("distribution", {})
        buckets = dist.get("kll", {}).get("buckets") or dist.get("buckets") or []
        rebuilt: list[float] = []
        for b in buckets:
            lower = _clamp(b.get("lower_bound", 0.0)) or 0.0
            upper = _clamp(b.get("upper_bound", 1.0)) or 1.0
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
    if not monitoring_bucket or not namespace:
        logger.error("--monitoring-bucket and --metric-namespace are required")
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

    since = datetime.now(UTC) - timedelta(hours=lookback_hours)
    live: list[float] = []
    keys_read = 0
    for key in _iter_capture_keys(s3, monitoring_bucket, capture_prefix, since):
        try:
            body = s3.get_object(Bucket=monitoring_bucket, Key=key)["Body"].read().decode("utf8")
        except Exception as exc:
            logger.warning("skipping %s (%s)", key, exc)
            continue
        live.extend(_scores_from_capture(body))
        keys_read += 1

    logger.info("read %d capture files, %d live scores", keys_read, len(live))

    if len(live) < min_samples:
        # Too little traffic to judge. Publishing a value here would produce
        # false drift alarms on quiet periods.
        logger.info("only %d samples (< %d); not publishing", len(live), min_samples)
        return 0

    psi = population_stability_index(live, baseline, num_bins)
    logger.info("PSI=%.4f over %d live vs %d baseline scores", psi, len(live), len(baseline))

    cloudwatch.put_metric_data(
        Namespace=namespace,
        MetricData=[
            {
                "MetricName": metric_name,
                "Dimensions": [{"Name": "EndpointName", "Value": endpoint_name}],
                "Value": psi,
                "Unit": "None",
                "Timestamp": datetime.now(UTC),
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
