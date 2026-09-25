#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Evaluate each trained model.

Per model: the decision threshold is tuned on the VALIDATION split, then every
reported metric is scored on the TEST split at that threshold. The test split
never influences a threshold, a weight or a model choice.
"""

import argparse
import json
import logging
import os
import sys
from datetime import UTC, datetime
from pathlib import Path

import numpy as np

# The step's code directory holds mlops_common next to this file; a local
# checkout has it one level up, in scripts/.
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from mlops_common.breakhis import magnification
from mlops_common.datasets import list_labeled_images, predict_scores
from mlops_common.gates import (
    CLINICAL_QUALITY_THRESHOLDS,
    binary_metrics,
    clinical_gate,
    select_threshold,
)
from mlops_common.preprocess import MODEL_INPUT_SIZE
from mlops_common.safe_tar import find_model_file

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
logger = logging.getLogger(__name__)

DEFAULT_VALIDATION_DIR = "/opt/ml/processing/input/validation"


def sanitize_for_log(value):
    return str(value).replace("\n", "\\n").replace("\r", "\\r")


def safe_path_join(base_path, *paths):
    base = Path(base_path).resolve()
    result = base
    for path in paths:
        clean_path = str(path).replace("..", "").replace("/", "").replace("\\", "")
        result = result / clean_path
    if not str(result.resolve()).startswith(str(base)):
        raise ValueError(f"Path traversal attempt detected: {paths}")
    return str(result)


def _failed(reason):
    return {"accuracy": 0.0, "precision": 0.0, "recall": 0.0, "f1_score": 0.0, "error": reason}


def evaluate_single_model(model_name, model_path, val_items, test_items, input_size):
    """Threshold on validation, metrics on test. Returns (result, test_scores)."""
    import tensorflow as tf

    model_file = find_model_file(model_path)
    if not model_file:
        return _failed("Model file not found"), None
    try:
        model = tf.keras.models.load_model(model_file, compile=False)
        logger.info("Loaded %s from %s", model_name, model_file)

        def predict(batch):
            return model.predict(batch, verbose=0)

        val_scores = predict_scores(predict, [p for p, _ in val_items], input_size)
        test_scores = predict_scores(predict, [p for p, _ in test_items], input_size)
        val_labels = [label for _, label in val_items]
        test_labels = [label for _, label in test_items]

        threshold, selection = select_threshold(
            val_labels, val_scores, min_recall=CLINICAL_QUALITY_THRESHOLDS["recall"]
        )
        test_metrics = binary_metrics(test_labels, test_scores, threshold)
        result = {
            "accuracy": test_metrics["accuracy"],
            "precision": test_metrics["precision"],
            "recall": test_metrics["recall"],
            "f1_score": test_metrics["f1_score"],
            "auc": test_metrics["auc_roc"] or 0.0,
            "optimal_threshold": threshold,
            "threshold_selection": selection,
            "validation_metrics": binary_metrics(val_labels, val_scores, threshold),
            "model_path": model_file,
        }
        return result, test_scores
    except Exception as e:
        return _failed(sanitize_for_log(str(e))), None


def _mean(values):
    return float(np.mean(values)) if values else 0.0


def evaluate_models(models_path, data_path, validation_dir, output_path):
    logger.info("=== Model Evaluation Started ===")
    logger.info("Models path: %s", sanitize_for_log(models_path))
    logger.info("Validation path: %s", sanitize_for_log(validation_dir))
    logger.info("Test path: %s", sanitize_for_log(data_path))

    model_names = [
        n.strip()
        for n in os.environ.get("MODEL_NAMES", "vgg16,densenet121,efficientnet").split(",")
        if n.strip()
    ]
    val_items = list_labeled_images(validation_dir)
    test_items = list_labeled_images(data_path)
    logger.info("%d validation images, %d test images", len(val_items), len(test_items))
    if not val_items or not test_items:
        logger.error("Validation and test splits must both contain images")
        return False

    test_labels = [label for _, label in test_items]
    test_filenames = [os.path.relpath(p, data_path) for p, _ in test_items]

    evaluation_results = {}
    predictions_data = {}
    for model_name in model_names:
        model_path = safe_path_join(models_path, model_name)
        if not os.path.exists(model_path):
            evaluation_results[model_name] = _failed(
                f"Model file not found in {sanitize_for_log(model_path)}"
            )
            logger.warning("Model file not found for %s", sanitize_for_log(model_name))
            continue
        result, test_scores = evaluate_single_model(
            model_name, model_path, val_items, test_items, MODEL_INPUT_SIZE
        )
        evaluation_results[model_name] = result
        if test_scores is not None:
            predictions_data[model_name] = test_scores.tolist()
        if "error" not in result:
            logger.info(
                "Evaluated %s on test at validation threshold %.2f: Accuracy=%.3f, "
                "Recall=%.3f, AUC=%.3f",
                sanitize_for_log(model_name),
                result["optimal_threshold"],
                result["accuracy"],
                result["recall"],
                result["auc"],
            )

    successful_models = {
        name: r for name, r in evaluation_results.items() if "error" not in r and r["accuracy"] > 0
    }

    if successful_models:
        best_model = max(
            successful_models, key=lambda k: successful_models[k]["validation_metrics"]["accuracy"]
        )
        best_accuracy = successful_models[best_model]["accuracy"]
    else:
        best_model, best_accuracy = "none", 0.0
    avg_accuracy = _mean([m["accuracy"] for m in successful_models.values()])
    avg_precision = _mean([m["precision"] for m in successful_models.values()])
    avg_recall = _mean([m["recall"] for m in successful_models.values()])
    avg_f1 = _mean([m["f1_score"] for m in successful_models.values()])
    auc_values = [m["auc"] for m in successful_models.values() if m.get("auc", 0.0) > 0.0]
    avg_auc = _mean(auc_values) if auc_values else None

    os.makedirs(output_path, exist_ok=True)

    # Informational only: the registration gate is scored on the ensemble in
    # scripts/ensemble/ensemble_creator.py.
    gate = clinical_gate(
        {
            "accuracy": avg_accuracy,
            "recall": avg_recall,
            "precision": avg_precision,
            "auc_roc": avg_auc,
        }
    )
    evaluation_results["clinical_quality_gate"] = gate
    logger.info(
        "Mean single-model clinical gate on test: %s", "PASSED" if gate["passed"] else "FAILED"
    )

    try:
        from report_generator import ModelReportGenerator

        thresholds = [m["optimal_threshold"] for m in successful_models.values()]
        ModelReportGenerator(output_path).generate_all_reports(
            evaluation_results={
                "accuracy": avg_accuracy,
                "precision": avg_precision,
                "recall": avg_recall,
                "f1_score": avg_f1,
                "auc": avg_auc or 0.0,
                "clinical_quality_gate": gate,
                "num_samples": len(test_labels),
                "class_distribution": {
                    "benign": int(test_labels.count(0)),
                    "malignant": int(test_labels.count(1)),
                },
            },
            predictions_data=predictions_data,
            true_labels=test_labels,
            decision_threshold=_mean(thresholds) if thresholds else None,
            subgroup_labels=[magnification(f) or "unknown" for f in test_filenames],
        )
        logger.info("Generated all required reports for model registration")
    except Exception as e:
        logger.warning("Failed to generate reports: %s", sanitize_for_log(str(e)))

    with open(safe_path_join(output_path, "evaluation_results.json"), "w") as f:
        json.dump(evaluation_results, f, indent=2)

    if predictions_data:
        with open(safe_path_join(output_path, "predictions.json"), "w") as f:
            json.dump(
                {
                    "split": "test",
                    "predictions": predictions_data,
                    "thresholds": {
                        n: successful_models[n]["optimal_threshold"]
                        for n in predictions_data
                        if n in successful_models
                    },
                    "test_filenames": test_filenames,
                    "true_labels": test_labels,
                    "model_count": len(predictions_data),
                },
                f,
                indent=2,
            )

    def stat(key):
        values = [m[key] for m in successful_models.values()]
        return {
            "value": _mean(values),
            "standard_deviation": float(np.std(values)) if values else 0.0,
        }

    registry_metrics = {
        "binary_classification_metrics": {
            "accuracy": stat("accuracy"),
            "precision": stat("precision"),
            "recall": stat("recall"),
            "f1": stat("f1_score"),
        },
        "model_statistics": {
            "best_model": best_model,
            "best_accuracy": float(best_accuracy),
            "model_count": len(model_names),
            "successful_models": len(successful_models),
            "failed_models": len(model_names) - len(successful_models),
        },
        "individual_model_performance": successful_models,
        "clinical_quality_gate": gate,
    }
    with open(safe_path_join(output_path, "metrics.json"), "w") as f:
        json.dump(registry_metrics, f, indent=2)

    with open(safe_path_join(output_path, "summary.json"), "w") as f:
        json.dump(
            {
                "best_model": best_model,
                "best_accuracy": float(best_accuracy),
                "average_accuracy": avg_accuracy,
                "model_count": len(model_names),
                "successful_models": len(successful_models),
            },
            f,
            indent=2,
        )

    if not successful_models:
        logger.error("No models were successfully evaluated")
        return False

    # Performance history records for the dashboard tables.
    version = f"v{datetime.now(UTC).strftime('%Y%m%d.%H%M')}"
    for model_name, results in successful_models.items():
        logger.info(
            json.dumps(
                {
                    "metric_name": "PerformanceHistoryRecord",
                    "model": model_name,
                    "version": version,
                    "accuracy": round(results["accuracy"] * 100, 2),
                    "precision": round(results["precision"] * 100, 2),
                    "recall": round(results["recall"] * 100, 2),
                    "f1_score": round(results["f1_score"] * 100, 2),
                    "status": "Complete",
                }
            )
        )

    # JSON logs read by the CloudWatch metric filters.
    for name, value in (
        ("BestModelAccuracy", best_accuracy * 100),
        ("TotalModelCount", len(model_names)),
        ("EvaluationAccuracy", avg_accuracy * 100),
        ("EvaluationPrecision", avg_precision * 100),
        ("EvaluationRecall", avg_recall * 100),
        ("EvaluationF1Score", avg_f1 * 100),
        ("SuccessfulModelCount", len(successful_models)),
    ):
        logger.info(json.dumps({"metric_name": name, "metric_value": value}))

    logger.info(
        "Evaluated %d models; best on validation: %s (test accuracy %.3f)",
        len(successful_models),
        sanitize_for_log(best_model),
        best_accuracy,
    )
    return True


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--models-path", required=True)
    parser.add_argument("--data-path", required=True, help="Test split")
    parser.add_argument(
        "--validation-dir",
        default=DEFAULT_VALIDATION_DIR,
        help="Validation split, used only to tune each model's decision threshold",
    )
    parser.add_argument("--output-path", required=True)
    args = parser.parse_args()

    try:
        if not evaluate_models(
            args.models_path, args.data_path, args.validation_dir, args.output_path
        ):
            sys.exit(1)
    except Exception as e:
        logger.error("Evaluation failed: %s", sanitize_for_log(e))
        os.makedirs(args.output_path, exist_ok=True)
        with open(safe_path_join(args.output_path, "evaluation_error.json"), "w") as f:
            json.dump({"status": "failed", "error": sanitize_for_log(str(e))}, f, indent=2)
        sys.exit(1)
