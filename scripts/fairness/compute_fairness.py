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

Input layout in the monitoring bucket:

    data-capture/**/*.jsonl        endpoint capture (request_id + score)
    ground-truth/**/*.jsonl        {"request_id": ..., "label": 0|1,
                                    "group": "<subgroup>"}   (label required)

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
from datetime import UTC, datetime, timedelta
from pathlib import Path

import boto3

# Fairlearn is the metric engine. Guarded so a missing dependency fails with a
# clear message rather than a bare ImportError inside the container.
try:
    from fairlearn.metrics import (
        demographic_parity_difference,
        equalized_odds_difference,
    )

    _FAIRLEARN_AVAILABLE = True
except ImportError:  # pragma: no cover
    _FAIRLEARN_AVAILABLE = False

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_ENV = os.environ.get
DEFAULT_THRESHOLD = 0.10


def _clamp01(value) -> float | None:
    try:
        f = float(value)
    except (TypeError, ValueError):
        return None
    return min(max(f, 0.0), 1.0)


def _iter_keys(s3, bucket: str, prefix: str, since: datetime):
    """Yield .jsonl object keys under `prefix` modified since `since`."""
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            if obj["LastModified"] >= since and obj["Key"].endswith(".jsonl"):
                yield obj["Key"]


def _read_jsonl(s3, bucket: str, key: str) -> list[dict]:
    """Read one JSON Lines object, skipping malformed lines."""
    try:
        body = s3.get_object(Bucket=bucket, Key=key)["Body"].read().decode("utf8")
    # A single unreadable object must not abort the whole run.
    except Exception as exc:
        logger.warning("skipping %s (%s)", key, exc)
        return []
    out = []
    for line in body.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out


def _extract_score(payload) -> float | None:
    """Pull a single malignant probability out of a model response."""
    if isinstance(payload, dict):
        if "predictions" in payload:
            preds = payload["predictions"]
            first = preds[0] if isinstance(preds, list) and preds else preds
            if isinstance(first, list):
                return _clamp01(first[1] if len(first) == 2 else first[0])
            return _clamp01(first)
        for k in ("malignant_probability", "confidence", "probability", "score"):
            if k in payload:
                return _clamp01(payload[k])
    elif isinstance(payload, (int, float)):
        return _clamp01(payload)
    return None


def load_predictions(s3, bucket: str, prefix: str, since: datetime) -> dict[str, float]:
    """Map request_id -> predicted score from endpoint data capture."""
    scores: dict[str, float] = {}
    for key in _iter_keys(s3, bucket, prefix, since):
        for rec in _read_jsonl(s3, bucket, key):
            meta = rec.get("eventMetadata") or {}
            rid = meta.get("eventId") or rec.get("request_id")
            if not rid:
                continue
            raw = (rec.get("captureData") or {}).get("endpointOutput", {}).get("data")
            if raw is None:
                continue
            try:
                payload = json.loads(raw) if isinstance(raw, str) else raw
            except json.JSONDecodeError:
                continue
            score = _extract_score(payload)
            if score is not None:
                scores[str(rid)] = score
    return scores


def load_ground_truth(s3, bucket: str, prefix: str, since: datetime) -> dict[str, dict]:
    """Map request_id -> {label, group} from clinician-confirmed outcomes."""
    truth: dict[str, dict] = {}
    for key in _iter_keys(s3, bucket, prefix, since):
        for rec in _read_jsonl(s3, bucket, key):
            rid = rec.get("request_id") or rec.get("eventId")
            if rid is None or "label" not in rec:
                continue
            try:
                label = int(rec["label"])
            except (TypeError, ValueError):
                continue
            truth[str(rid)] = {"label": label, "group": str(rec.get("group", "all"))}
    return truth


def compute(y_true, y_pred, groups, threshold: float) -> dict:
    """Demographic parity + equalized odds across subgroups."""
    if not _FAIRLEARN_AVAILABLE:
        raise RuntimeError(
            "fairlearn is not installed in this container. Add it to "
            "scripts/fairness/requirements.txt or bake it into the image."
        )

    per_group: dict[str, dict] = {}
    for grp in sorted(set(groups)):
        idx = [i for i, g in enumerate(groups) if g == grp]
        n = len(idx)
        pos = sum(1 for i in idx if y_true[i] == 1)
        neg = n - pos
        flagged = sum(1 for i in idx if y_pred[i] == 1)
        tp = sum(1 for i in idx if y_true[i] == 1 and y_pred[i] == 1)
        per_group[grp] = {
            "n": n,
            "n_positive": pos,
            "selection_rate": round(flagged / n, 4) if n else None,
            # Recall is the clinically costly metric: a missed malignant case.
            # None when the group has no confirmed positives to measure against.
            "true_positive_rate": round(tp / pos, 4) if pos else None,
            # Only groups with both classes present can contribute to
            # equalized odds; see the filter below.
            "rates_measurable": bool(pos and neg),
        }

    # Demographic parity is a selection-rate comparison, so every group counts.
    dp = float(demographic_parity_difference(y_true, y_pred, sensitive_features=groups))

    # Equalized odds compares TPR and FPR, which need both classes present in a
    # group. Fairlearn does not raise on a group with no positives - it inherits
    # scikit-learn's zero_division default and reports recall 0.0, which reads
    # as a maximal disparity for a group that simply had no malignant cases in
    # the window. On a week of live traffic that is common, so those groups are
    # excluded from this term rather than allowed to fire the alarm daily. They
    # remain in per_group with rates_measurable = false so the exclusion is
    # visible, and they still count toward demographic parity above.
    keep = [i for i, g in enumerate(groups) if per_group[g]["rates_measurable"]]
    eo_groups = {groups[i] for i in keep}
    if len(eo_groups) >= 2:
        eo = float(
            equalized_odds_difference(
                [y_true[i] for i in keep],
                [y_pred[i] for i in keep],
                sensitive_features=[groups[i] for i in keep],
            )
        )
    else:
        # Fewer than two comparable groups: nothing to compare, so this term
        # contributes nothing. Demographic parity still carries the signal.
        eo = 0.0

    metrics = {
        "demographic_parity_difference": round(dp, 4),
        "equalized_odds_difference": round(eo, 4),
        "equalized_odds_groups": sorted(eo_groups),
        "per_group": per_group,
        "n_scored": len(y_true),
        "n_groups": len(per_group),
        "threshold": threshold,
    }
    metrics["max_disparity"] = round(max(dp, eo), 4)
    metrics["passed"] = bool(metrics["max_disparity"] <= threshold)
    return metrics


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
    if not monitoring_bucket or not namespace:
        logger.error("--monitoring-bucket and --metric-namespace are required")
        return 1

    s3 = boto3.client("s3")
    cloudwatch = boto3.client("cloudwatch")
    since = datetime.now(UTC) - timedelta(hours=lookback_hours)

    preds = load_predictions(s3, monitoring_bucket, capture_prefix, since)
    truth = load_ground_truth(s3, monitoring_bucket, ground_truth_prefix, since)
    logger.info("%d captured predictions, %d confirmed outcomes", len(preds), len(truth))

    # Score only predictions that already have a confirmed clinical outcome.
    joined = [(rid, preds[rid], truth[rid]) for rid in truth if rid in preds]
    if len(joined) < min_samples:
        # Publishing on a thin join would swing wildly day to day and raise
        # false fairness alarms, so emit nothing and let the alarm treat the
        # gap as non-breaching.
        logger.info("only %d joined records (< %d); not publishing", len(joined), min_samples)
        return 0

    y_pred = [1 if score >= 0.5 else 0 for _, score, _ in joined]
    y_true = [t["label"] for _, _, t in joined]
    groups = [t["group"] for _, _, t in joined]

    metrics = compute(y_true, y_pred, groups, threshold)
    metrics["endpoint_name"] = endpoint_name
    metrics["computed_at"] = datetime.now(UTC).isoformat()
    logger.info(
        "max_disparity=%.4f over %d records / %d groups (threshold %.2f) passed=%s",
        metrics["max_disparity"],
        metrics["n_scored"],
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
                "Timestamp": datetime.now(UTC),
            }
        ],
    )

    output_path.mkdir(parents=True, exist_ok=True)
    out = output_path / "fairness_metrics.json"
    out.write_text(json.dumps(metrics, indent=2))
    logger.info("wrote %s", out)
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
