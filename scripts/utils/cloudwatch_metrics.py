#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import json
import logging
import os
from datetime import UTC, datetime

import boto3
from botocore.exceptions import BotoCoreError, ClientError

logger = logging.getLogger(__name__)


class CloudWatchMetrics:
    """Publish metrics to Amazon CloudWatch and log them for the metric filters."""

    def __init__(self, project_name=None):
        self.project_name = project_name or os.environ.get("PROJECT_NAME", "image-classification")
        try:
            self.cloudwatch = boto3.client("cloudwatch")
        except BotoCoreError as e:
            # No region or credentials (a local run): metrics are only logged.
            self.cloudwatch = None
            logger.warning(f"CloudWatch client not available: {e}")

    def send_metric(self, metric_name, value, unit="Count", namespace=None):
        """Publish one metric (best effort) and log it as a JSON line."""
        try:
            if self.cloudwatch:
                namespace = namespace or f"{self.project_name}/Training"
                self.cloudwatch.put_metric_data(
                    Namespace=namespace,
                    MetricData=[
                        {
                            "MetricName": metric_name,
                            "Value": float(value),
                            "Unit": unit,
                            "Timestamp": datetime.now(UTC),
                        }
                    ],
                )

            # Always log for CloudWatch Logs metric filters
            logger.info(
                json.dumps(
                    {"metric_name": metric_name, "metric_value": float(value), "metric_unit": unit}
                )
            )

        except (ClientError, BotoCoreError, TypeError, ValueError) as e:
            logger.warning(f"Failed to send metric {metric_name}: {type(e).__name__}")

    def log_training_progress(self, step, total_steps, loss=None, accuracy=None, model_name=None):
        """Publish step, progress and optional loss and accuracy."""
        progress = (step / total_steps) * 100 if total_steps > 0 else 0

        self.send_metric("TrainingStep", step)
        self.send_metric("TrainingProgress", progress, "Percent")

        if loss is not None:
            self.send_metric("TrainingLoss", loss, "None")
        if accuracy is not None:
            self.send_metric("TrainingAccuracy", accuracy, "Percent")
        if model_name:
            self.send_metric(f"{model_name}Progress", progress, "Percent")
