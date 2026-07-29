#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import json
import logging

logger = logging.getLogger(__name__)


def send_training_metrics_to_cloudwatch(model_name, history):
    """Send training metrics to CloudWatch via JSON logs"""
    try:
        # Get final metrics
        final_accuracy = history.get("accuracy", [0])[-1]
        final_val_accuracy = history.get("val_accuracy", [0])[-1]
        final_loss = history.get("loss", [1])[-1]
        final_val_loss = history.get("val_loss", [1])[-1]
        final_precision = history.get("precision", [0])[-1] if "precision" in history else 0
        final_recall = history.get("recall", [0])[-1] if "recall" in history else 0
        final_val_precision = (
            history.get("val_precision", [0])[-1] if "val_precision" in history else 0
        )
        final_val_recall = history.get("val_recall", [0])[-1] if "val_recall" in history else 0

        # Dynamic model name mapping
        model_camel = model_name.replace("-", "").replace("_", "").title()

        # Log metrics using JSON format for CloudWatch metric filters
        logger.info(
            json.dumps(
                {
                    "metric_name": f"ModelTrainingAccuracy{model_camel}",
                    "metric_value": final_accuracy * 100,
                }
            )
        )
        logger.info(
            json.dumps(
                {
                    "metric_name": f"ModelValidationAccuracy{model_camel}",
                    "metric_value": final_val_accuracy * 100,
                }
            )
        )
        logger.info(
            json.dumps(
                {"metric_name": f"ModelTrainingLoss{model_camel}", "metric_value": final_loss}
            )
        )
        logger.info(
            json.dumps(
                {"metric_name": f"ModelValidationLoss{model_camel}", "metric_value": final_val_loss}
            )
        )
        logger.info(
            json.dumps(
                {
                    "metric_name": f"ModelTrainingPrecision{model_camel}",
                    "metric_value": final_precision * 100,
                }
            )
        )
        logger.info(
            json.dumps(
                {
                    "metric_name": f"ModelTrainingRecall{model_camel}",
                    "metric_value": final_recall * 100,
                }
            )
        )
        logger.info(
            json.dumps(
                {
                    "metric_name": f"ModelValidationPrecision{model_camel}",
                    "metric_value": final_val_precision * 100,
                }
            )
        )
        logger.info(
            json.dumps(
                {
                    "metric_name": f"ModelValidationRecall{model_camel}",
                    "metric_value": final_val_recall * 100,
                }
            )
        )
        logger.info(
            json.dumps(
                {
                    "metric_name": f"ModelEpochsCompleted{model_camel}",
                    "metric_value": len(history["accuracy"]),
                }
            )
        )
        logger.info(
            json.dumps(
                {
                    "metric_name": f"ModelOverfittingGap{model_camel}",
                    "metric_value": abs(final_accuracy - final_val_accuracy) * 100,
                }
            )
        )

        logger.info(f"✅ Published training metrics for {model_name} to CloudWatch")

    except Exception as e:
        logger.warning(f"⚠️ Failed to send training metrics: {e}")
