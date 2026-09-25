#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Ongoing fairness monitoring over live endpoint predictions (Part 4).

Runs as a daily Amazon SageMaker Processing job started by EventBridge
Scheduler. Joins the endpoint's captured predictions with the confirmed
diagnostic outcomes clinicians supply, computes demographic parity and
equalized-odds differences per subgroup with Fairlearn, and publishes the
largest disparity to CloudWatch beside the drift metric from Part 3.

Why live monitoring in addition to the in-pipeline gate: the training-time
BiasCheck step (scripts/bias/compute_bias.py) proves a model was fair on the
test split. It cannot see a population shift after deployment - a hospital
network adding a site with a different demographic mix can raise the
false-negative rate for that group while aggregate accuracy looks unchanged.

Ground truth arrives on its own cadence (pathology results, follow-up reads),
so only predictions that already have a confirmed label are scored. A prediction
with no matching label is skipped, never guessed.

Join key: the inference Lambda passes its request id as InvokeEndpoint
InferenceId, which data capture records as eventMetadata.inferenceId, and
returns the same request_id to the caller. Clinicians upload outcomes keyed by
that request_id. Each prediction is scored at the decision threshold the
endpoint reported (threshold_used), not at 0.5.

Input layout in the monitoring bucket:

    data-capture/<endpoint>/<variant>/yyyy/mm/dd/hh/*.jsonl   endpoint capture
    ground-truth/**/*.jsonl        {"request_id": ..., "label": 0|1,
                                    "group": "<subgroup>"}   (label required)

With fewer than two subgroups in the joined window nothing can be compared:
the report is written with status "not_evaluable" and no metric is published.

Output: one CloudWatch metric (default ``fairness_max_disparity``) plus a JSON
summary written to the processing output path for the audit trail.

The published metric is the larger of the two differences, mirroring how the
in-pipeline gate scores a candidate, so a deployed model is held to the bar it
registered under. Note the standard caveat on demographic parity: it compares
selection rates only, so a genuine difference in disease prevalence between
subgroups registers as disparity even when the model is accurate on both. Read
``per_group`` before concluding a breach is a model defect, and tune
``--threshold`` to the subgroup prevalence actually seen in production.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import boto3

# The job's code directory holds mlops_common next to this file; a local
# checkout has it one level up, in scripts/.
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from mlops_common.capture import iter_capture_records
from mlops_common.fairness import STATUS_NOT_EVALUABLE, compute_group_fairness
from mlops_common.s3io import iter_capture_keys, iter_keys

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_ENV = os.environ.get
DEFAULT_THRESHOLD = 0.10


def _read_text(s3, bucket: str, key: str) -> str:
    try:
        return s3.get_object(Bucket=bucket, Key=key)["Body"].read().decode("utf8")
    # A single unreadable object must not abort the whole run.
    except Exception as exc:
        logger.warning("skipping %s (%s)", key, exc)
        return ""


def _read_jsonl(s3, bucket: str, key: str) -> list:
    """Read one JSON Lines object, skipping malformed lines."""
    out = []
    for line in _read_text(s3, bucket, key).splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out


def load_predictions(
    s3, bucket: str, prefix: str, endpoint_name: str, since: datetime
) -> dict[str, tuple[float, float | None]]:
    """Map inference id -> (score, threshold_used) from endpoint data capture.

    Keyed on eventMetadata.inferenceId (the Lambda request id); falls back to
    SageMaker's eventId for callers that did not pass an InferenceId.
    """
    preds: dict[str, tuple[float, float | None]] = {}
    for key in iter_capture_keys(s3, bucket, prefix, endpoint_name, since):
        for record in iter_capture_records(_read_text(s3, bucket, key)):
            rid = record["inference_id"] or record["event_id"]
            if rid:
                preds[str(rid)] = (record["score"], record["threshold"])
    return preds


def load_ground_truth(s3, bucket: str, prefix: str, since: datetime) -> dict[str, dict]:
    """Map request_id -> {label, group} from clinician-confirmed outcomes."""
    truth: dict[str, dict] = {}
    for key in iter_keys(s3, bucket, prefix, since=since, suffix=".jsonl"):
        for rec in _read_jsonl(s3, bucket, key):
            rid = rec.get("request_id") or rec.get("inferenceId")
            if rid is None or "label" not in rec:
                continue
            try:
                label = int(rec["label"])
            except (TypeError, ValueError):
                continue
            truth[str(rid)] = {"label": label, "group": str(rec.get("group", "all"))}
    return truth


def join_predictions(preds: dict, truth: dict) -> tuple[list, list, list, int]:
    """(y_true, y_pred, groups, skipped) for predictions with a confirmed outcome.

    Each prediction uses the threshold the endpoint applied. Records whose
    capture carries no threshold are skipped and counted rather than guessed.
    """
    y_true, y_pred, groups = [], [], []
    skipped = 0
    for rid, outcome in truth.items():
        if rid not in preds:
            continue
        score, decision_threshold = preds[rid]
        if decision_threshold is None:
            skipped += 1
            continue
        y_true.append(outcome["label"])
        y_pred.append(1 if score >= decision_threshold else 0)
        groups.append(outcome["group"])
    return y_true, y_pred, groups, skipped


def run(
    monitoring_bucket: str,
    capture_prefix: str,
    ground_truth_prefix: str,
    namespace: str,
    metric_name: str,
    endpoint_name: str,
    lookback_hours: int,
    min_samples: int,
    threshold: float,
    output_path: Path,
) -> int:
    if not monitoring_bucket or not namespace or not endpoint_name:
        logger.error("--monitoring-bucket, --metric-namespace and --endpoint-name are required")
        return 1

    s3 = boto3.client("s3")
    cloudwatch = boto3.client("cloudwatch")
    since = datetime.now(timezone.utc) - timedelta(hours=lookback_hours)

    preds = load_predictions(s3, monitoring_bucket, capture_prefix, endpoint_name, since)
    truth = load_ground_truth(s3, monitoring_bucket, ground_truth_prefix, since)
    logger.info("%d captured predictions, %d confirmed outcomes", len(preds), len(truth))

    y_true, y_pred, groups, skipped = join_predictions(preds, truth)
    if skipped:
        logger.warning("%d joined records had no threshold_used in capture; skipped", skipped)
    if len(y_true) < min_samples:
        # Publishing on a thin join would swing wildly day to day and raise
        # false fairness alarms, so emit nothing and let the alarm treat the
        # gap as non-breaching.
        logger.info("only %d joined records (< %d); not publishing", len(y_true), min_samples)
        return 0

    metrics = compute_group_fairness(y_true, y_pred, groups, threshold)
    metrics["endpoint_name"] = endpoint_name
    metrics["computed_at"] = datetime.now(timezone.utc).isoformat()

    output_path.mkdir(parents=True, exist_ok=True)
    out = output_path / "fairness_metrics.json"
    out.write_text(json.dumps(metrics, indent=2))
    logger.info("wrote %s", out)

    if metrics["status"] == STATUS_NOT_EVALUABLE:
        logger.warning("fairness not evaluable: %s; not publishing", metrics["reason"])
        return 0

    logger.info(
        "max_disparity=%.4f over %d records / %d groups (threshold %.2f) passed=%s",
        metrics["max_disparity"],
        metrics["n_samples"],
        metrics["n_groups"],
        threshold,
        metrics["passed"],
    )
    cloudwatch.put_metric_data(
        Namespace=namespace,
        MetricData=[
            {
                "MetricName": metric_name,
                "Dimensions": [{"Name": "EndpointName", "Value": endpoint_name}],
                "Value": metrics["max_disparity"],
                "Unit": "None",
                "Timestamp": datetime.now(timezone.utc),
            }
        ],
    )
    return 0


def main() -> int:
    p = argparse.ArgumentParser(
        description="Daily fairness monitoring over live endpoint predictions (Part 4)"
    )
    p.add_argument("--monitoring-bucket", default=_ENV("MONITORING_BUCKET", ""))
    p.add_argument("--capture-prefix", default=_ENV("DATA_CAPTURE_PREFIX", "data-capture"))
    p.add_argument("--ground-truth-prefix", default=_ENV("GROUND_TRUTH_PREFIX", "ground-truth"))
    p.add_argument("--metric-namespace", default=_ENV("METRIC_NAMESPACE", ""))
    p.add_argument("--metric-name", default=_ENV("METRIC_NAME", "fairness_max_disparity"))
    p.add_argument("--endpoint-name", default=_ENV("ENDPOINT_NAME", ""))
    p.add_argument("--lookback-hours", type=int, default=int(_ENV("LOOKBACK_HOURS", "168")))
    p.add_argument("--min-samples", type=int, default=int(_ENV("MIN_SAMPLES", "50")))
    p.add_argument("--threshold", type=float, default=float(_ENV("THRESHOLD", DEFAULT_THRESHOLD)))
    p.add_argument("--output-path", type=Path, default=Path("/opt/ml/processing/output"))
    args = p.parse_args()

    return run(
        monitoring_bucket=args.monitoring_bucket,
        capture_prefix=args.capture_prefix,
        ground_truth_prefix=args.ground_truth_prefix,
        namespace=args.metric_namespace,
        metric_name=args.metric_name,
        endpoint_name=args.endpoint_name,
        lookback_hours=args.lookback_hours,
        min_samples=args.min_samples,
        threshold=args.threshold,
        output_path=args.output_path,
    )


if __name__ == "__main__":
    raise SystemExit(main())
