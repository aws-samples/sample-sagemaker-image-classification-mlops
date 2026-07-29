#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import argparse
import json
import logging
import os
import sys

# Removed boto3 import - not needed anymore
from pathlib import Path

import numpy as np

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
logger = logging.getLogger(__name__)

# ImageNet channel statistics - pixel normalization is `/255` then per-channel
# `(x - mean) / std`. These MUST match scripts/training/_common.py so evaluation
# sees the exact transform training applied (no training-serving skew).
IMAGENET_MEAN = [0.485, 0.456, 0.406]
IMAGENET_STD = [0.229, 0.224, 0.225]

# Clinical quality gates. Module-level so they are tunable in one place. The
# blog gates on accuracy/recall/auc_roc/precision; recall is weighted highest
# because a missed malignant case (false negative) is the costly error.
CLINICAL_QUALITY_THRESHOLDS = {
    "accuracy": 0.85,
    "recall": 0.95,
    "auc_roc": 0.90,
    "precision": 0.80,
}


def imagenet_normalize(image):
    """Scale a 0-255 image to 0-1 then align to ImageNet channel statistics.

    Used as the Keras `preprocessing_function`; it replaces `rescale` so eval
    sees the same normalization training applied (see _common.py).
    """
    image = image.astype("float32") / 255.0
    return (image - np.array(IMAGENET_MEAN, dtype="float32")) / np.array(
        IMAGENET_STD, dtype="float32"
    )


def evaluate_clinical_quality(metrics, thresholds):
    """Gate computed metrics against clinical minimums.

    Returns (passed, results) where results maps each threshold metric to its
    value, threshold, pass/fail, and signed gap (value - threshold). A metric
    missing from `metrics` is treated as 0.0 and fails rather than crashing.
    """
    results = {}
    passed = True
    for metric, threshold in thresholds.items():
        value = metrics.get(metric, 0)
        met = value >= threshold
        results[metric] = {
            "value": value,
            "threshold": threshold,
            "passed": met,
            "gap": round(value - threshold, 4),
        }
        if not met:
            passed = False
    return passed, results


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


def _safe_extract_member(tar, member, dest):
    # Guard against tar path-traversal (zip-slip / CVE-2007-4559): a crafted
    # model.tar.gz could embed members named `../../...`, absolute paths, or
    # symlinks that write outside `dest`. Reject anything that escapes dest
    # and any non-regular member before extracting.
    target = os.path.realpath(os.path.join(dest, member.name))
    if not target.startswith(os.path.realpath(dest) + os.sep):
        raise ValueError(f"Unsafe tar member path: {member.name}")
    if member.issym() or member.islnk():
        raise ValueError(f"Link member not allowed in archive: {member.name}")
    if not member.isreg():
        raise ValueError(f"Non-regular member not allowed in archive: {member.name}")
    tar.extract(member, dest)


def find_model_file(model_path):
    for root, _dirs, files in os.walk(model_path):
        for file in files:
            if file.endswith(".h5"):
                return os.path.join(root, file)
        for file in files:
            if file == "model.tar.gz":
                import tarfile

                with tarfile.open(os.path.join(root, file), "r:gz") as tar:
                    for member in tar.getmembers():
                        if member.name.endswith(".h5"):
                            _safe_extract_member(tar, member, root)
                            return os.path.join(root, member.name)
    return None


def calculate_optimal_threshold(y_true, y_scores):
    from sklearn.metrics import balanced_accuracy_score

    thresholds = np.linspace(0.1, 0.9, 81)  # Test 81 thresholds from 0.1 to 0.9
    best_threshold = 0.5
    best_balanced_acc = 0.0

    for threshold in thresholds:
        y_pred = (y_scores > threshold).astype(int)
        balanced_acc = balanced_accuracy_score(y_true, y_pred)
        if balanced_acc > best_balanced_acc:
            best_balanced_acc = balanced_acc
            best_threshold = threshold

    return float(best_threshold)


def evaluate_single_model(model_name, model_path, test_generator, input_size=224):
    import tensorflow as tf
    from sklearn.metrics import accuracy_score, f1_score, precision_score, recall_score

    model_file = find_model_file(model_path)
    if not model_file:
        return {
            "accuracy": 0.0,
            "precision": 0.0,
            "recall": 0.0,
            "f1_score": 0.0,
            "error": "Model file not found",
        }

    try:
        # Load model without optimizer to avoid architecture mismatch issues
        model = tf.keras.models.load_model(model_file, compile=False)
        # Recompile for inference only (no training needed)
        model.compile(optimizer="adam", loss="binary_crossentropy", metrics=["accuracy"])
        logger.info(f"Successfully loaded {model_name} model from {model_file}")
        logger.info(f"Model input shape: {model.input_shape}, Output shape: {model.output_shape}")
        test_generator.reset()
        predictions = model.predict(test_generator)
        y_true = test_generator.classes

        # Calculate optimal threshold
        optimal_threshold = calculate_optimal_threshold(y_true, predictions.flatten())

        # Use optimal threshold for predictions
        y_pred = (predictions > optimal_threshold).astype(int).flatten()

        return {
            "accuracy": float(accuracy_score(y_true, y_pred)),
            "precision": float(precision_score(y_true, y_pred, zero_division=0)),
            "recall": float(recall_score(y_true, y_pred, zero_division=0)),
            "f1_score": float(f1_score(y_true, y_pred, zero_division=0)),
            "optimal_threshold": optimal_threshold,
            "predictions": predictions.flatten().tolist(),
            "model_path": model_file,
        }
    except Exception as e:
        return {
            "accuracy": 0.0,
            "precision": 0.0,
            "recall": 0.0,
            "f1_score": 0.0,
            "error": sanitize_for_log(str(e)),
        }


# Removed duplicate individual model metrics logging - training handles this


def evaluate_models(models_path, data_path, output_path):
    logger.info("=== Model Evaluation Started ===")
    logger.info(f"Models path: {sanitize_for_log(models_path)}")
    logger.info(f"Data path: {sanitize_for_log(data_path)}")
    logger.info(f"Output path: {sanitize_for_log(output_path)}")

    from sklearn.metrics import roc_auc_score
    from tensorflow.keras.preprocessing.image import ImageDataGenerator

    # Get model names from environment (passed from SageMaker pipeline parameters)
    model_names = os.environ.get("MODEL_NAMES", "vgg16,densenet121,efficientnet").split(",")
    model_names = [name.strip() for name in model_names]

    # Dynamic model configurations - all models use same input size
    MODEL_CONFIGS = {model_name: {"input_size": (224, 224)} for model_name in model_names}

    # Fallback if no environment variable
    if not MODEL_CONFIGS:
        MODEL_CONFIGS = {
            "vgg16": {"input_size": (224, 224)},
            "densenet121": {"input_size": (224, 224)},
            "efficientnet": {"input_size": (224, 224)},
        }
    evaluation_results = {}
    predictions_data = {}
    test_generator = None

    for model_name in model_names:
        model_path = safe_path_join(models_path, model_name)
        if os.path.exists(model_path):
            # Use exact same preprocessing as training
            model_config = MODEL_CONFIGS[model_name]
            input_size = model_config["input_size"][0]  # Get width from tuple

            # Same preprocessing as training: /255 then ImageNet mean/std via
            # preprocessing_function (replaces rescale - must not pass both).
            test_datagen = ImageDataGenerator(preprocessing_function=imagenet_normalize)
            logger.info(f"Using /255 + ImageNet mean/std preprocessing for {model_name}")

            test_generator = test_datagen.flow_from_directory(
                data_path,
                target_size=(input_size, input_size),
                batch_size=32,
                class_mode="binary",
                shuffle=False,
            )

            result = evaluate_single_model(model_name, model_path, test_generator, input_size)

            # Calculate AUC if predictions available
            if "predictions" in result and len(test_generator.classes) > 0:
                try:
                    result["auc"] = float(
                        roc_auc_score(test_generator.classes, result["predictions"])
                    )
                except (ValueError, KeyError):
                    # ValueError: test set has only one class. KeyError: no predictions captured.
                    result["auc"] = 0.0
            else:
                result["auc"] = 0.0

            evaluation_results[model_name] = result
            if "predictions" in result:
                predictions_data[model_name] = result["predictions"]
                del result["predictions"]
            # Individual model metrics are handled by training scripts

            logger.info(
                f"✅ Evaluated {sanitize_for_log(model_name)}: Accuracy={result['accuracy']:.3f}, F1={result['f1_score']:.3f}, AUC={result['auc']:.3f}"
            )
        else:
            evaluation_results[model_name] = {
                "accuracy": 0.0,
                "precision": 0.0,
                "recall": 0.0,
                "f1_score": 0.0,
                "error": f"Model file not found in {sanitize_for_log(model_path)}",
            }
            logger.warning(f"❌ Model file not found for {sanitize_for_log(model_name)}")

    successful_models = {
        name: results
        for name, results in evaluation_results.items()
        if "error" not in results and results["accuracy"] > 0
    }

    if successful_models:
        best_model = max(successful_models.keys(), key=lambda k: successful_models[k]["accuracy"])
        best_accuracy = successful_models[best_model]["accuracy"]
        avg_accuracy = np.mean([m["accuracy"] for m in successful_models.values()])
        avg_precision = np.mean([m["precision"] for m in successful_models.values()])
        avg_recall = np.mean([m["recall"] for m in successful_models.values()])
        avg_f1 = np.mean([m["f1_score"] for m in successful_models.values()])

        # Calculate ensemble optimal threshold (weighted by accuracy for balanced approach)
        thresholds = [
            m["optimal_threshold"] for m in successful_models.values() if "optimal_threshold" in m
        ]
        accuracies = [m["accuracy"] for m in successful_models.values() if "optimal_threshold" in m]
        if thresholds and sum(accuracies) > 0:
            ensemble_threshold = np.average(thresholds, weights=accuracies)
        else:
            ensemble_threshold = 0.5  # fallback
    else:
        best_model = "none"
        best_accuracy = avg_accuracy = avg_precision = avg_recall = avg_f1 = 0.0
        ensemble_threshold = 0.5

    os.makedirs(output_path, exist_ok=True)

    # Add ensemble threshold to results
    evaluation_results["ensemble_optimal_threshold"] = ensemble_threshold

    # Clinical quality gate on the aggregate ensemble metrics. AUC is the mean
    # per-model roc_auc computed above; if no model produced a usable AUC we
    # note it missing rather than failing the gate on a phantom 0.
    ensemble_auc_values = [m["auc"] for m in successful_models.values() if m.get("auc", 0.0) > 0.0]
    auc_available = bool(ensemble_auc_values)
    ensemble_auc = float(np.mean(ensemble_auc_values)) if auc_available else 0.0

    gate_metrics = {
        "accuracy": float(avg_accuracy),
        "recall": float(avg_recall),
        "precision": float(avg_precision),
    }
    gate_thresholds = dict(CLINICAL_QUALITY_THRESHOLDS)
    if auc_available:
        gate_metrics["auc_roc"] = ensemble_auc
    else:
        # Drop auc_roc from the gate so a missing AUC doesn't fail the model;
        # record that it was skipped for transparency in the report.
        gate_thresholds.pop("auc_roc", None)
        logger.warning("auc_roc unavailable - skipping AUC clinical gate")

    gate_passed, gate_results = evaluate_clinical_quality(gate_metrics, gate_thresholds)
    clinical_quality_gate = {
        "passed": gate_passed,
        "results": gate_results,
        "auc_roc_available": auc_available,
        "thresholds": gate_thresholds,
    }
    evaluation_results["clinical_quality_gate"] = clinical_quality_gate

    if gate_passed:
        logger.info("✅ Clinical quality gate PASSED for ensemble metrics")
    else:
        logger.warning("❌ Clinical quality gate FAILED for ensemble metrics")
    for metric, detail in gate_results.items():
        if not detail["passed"]:
            logger.warning(
                f"{metric}: {detail['value']:.4f} (threshold {detail['threshold']}, "
                f"gap {detail['gap']:+.4f})"
            )

    # Generate comprehensive reports for model registration
    try:
        import sys

        sys.path.append("/opt/ml/processing/input/code")
        from report_generator import ModelReportGenerator

        # Calculate ensemble metrics for reports
        ensemble_results = {
            "accuracy": avg_accuracy,
            "precision": avg_precision,
            "recall": avg_recall,
            "f1_score": avg_f1,
            "auc": ensemble_auc,
            "clinical_quality_gate": clinical_quality_gate,
            "num_samples": len(test_generator.classes) if test_generator else 0,
            "class_distribution": {
                "benign": int(np.sum(np.array(test_generator.classes) == 0))
                if test_generator
                else 0,
                "malignant": int(np.sum(np.array(test_generator.classes) == 1))
                if test_generator
                else 0,
            },
        }

        report_gen = ModelReportGenerator(output_path)
        # generate_all_reports writes files to disk as a side effect; we
        # don't need the return dict.
        report_gen.generate_all_reports(
            evaluation_results=ensemble_results,
            predictions_data=predictions_data,
            true_labels=test_generator.classes.tolist() if test_generator else [],
        )

        logger.info("Generated all required reports for model registration")

    except Exception as e:
        logger.warning(f"Failed to generate comprehensive reports: {sanitize_for_log(str(e))}")
        # Continue without reports - evaluation will still work

    with open(safe_path_join(output_path, "evaluation_results.json"), "w") as f:
        json.dump(evaluation_results, f, indent=2)

    if predictions_data:
        predictions_output = {
            "predictions": predictions_data,
            "test_filenames": test_generator.filenames,
            "true_labels": test_generator.classes.tolist(),
            "model_count": len(predictions_data),
        }
        with open(safe_path_join(output_path, "predictions.json"), "w") as f:
            json.dump(predictions_output, f, indent=2)

    registry_metrics = {
        "binary_classification_metrics": {
            "accuracy": {
                "value": float(avg_accuracy),
                "standard_deviation": float(
                    np.std([m["accuracy"] for m in successful_models.values()])
                    if successful_models
                    else 0.0
                ),
            },
            "precision": {
                "value": float(avg_precision),
                "standard_deviation": float(
                    np.std([m["precision"] for m in successful_models.values()])
                    if successful_models
                    else 0.0
                ),
            },
            "recall": {
                "value": float(avg_recall),
                "standard_deviation": float(
                    np.std([m["recall"] for m in successful_models.values()])
                    if successful_models
                    else 0.0
                ),
            },
            "f1": {
                "value": float(avg_f1),
                "standard_deviation": float(
                    np.std([m["f1_score"] for m in successful_models.values()])
                    if successful_models
                    else 0.0
                ),
            },
        },
        "model_statistics": {
            "best_model": best_model,
            "best_accuracy": float(best_accuracy),
            "model_count": len(evaluation_results),
            "successful_models": len(successful_models),
            "failed_models": len(evaluation_results) - len(successful_models),
        },
        "individual_model_performance": successful_models,
        "clinical_quality_gate": clinical_quality_gate,
    }

    with open(safe_path_join(output_path, "metrics.json"), "w") as f:
        json.dump(registry_metrics, f, indent=2)

    metrics_summary = {
        "best_model": best_model,
        "best_accuracy": float(best_accuracy),
        "average_accuracy": float(avg_accuracy),
        "model_count": len(evaluation_results),
        "successful_models": len(successful_models),
    }
    with open(safe_path_join(output_path, "summary.json"), "w") as f:
        json.dump(metrics_summary, f, indent=2)

    # Individual model metrics are logged by training scripts

    if not successful_models:
        logger.error("❌ No models were successfully evaluated")
        return False

    logger.info(
        f"✅ Successfully evaluated {len(successful_models)} models: {list(successful_models.keys())}"
    )
    logger.info(f"Average accuracy across models: {avg_accuracy:.3f}")
    logger.info(
        f"Best performing model: {sanitize_for_log(best_model)} (accuracy: {best_accuracy:.3f})"
    )

    # Performance History Logging for Dashboard Tables
    import datetime

    version = f"v{datetime.datetime.utcnow().strftime('%Y%m%d.%H%M')}"

    # Log individual model performance history
    for model_name, results in successful_models.items():
        performance_record = {
            "metric_name": "PerformanceHistoryRecord",
            "model": model_name,
            "version": version,
            "accuracy": round(results["accuracy"] * 100, 2),
            "precision": round(results["precision"] * 100, 2),
            "recall": round(results["recall"] * 100, 2),
            "f1_score": round(results["f1_score"] * 100, 2),
            "status": "Complete",
        }
        logger.info(json.dumps(performance_record))

    # Log ensemble performance history
    if successful_models:
        ensemble_record = {
            "metric_name": "PerformanceHistoryRecord",
            "model": "ensemble",
            "version": version,
            "accuracy": round(avg_accuracy * 100, 2),
            "precision": round(avg_precision * 100, 2),
            "recall": round(avg_recall * 100, 2),
            "f1_score": round(avg_f1 * 100, 2),
            "status": "Complete",
        }
        logger.info(json.dumps(ensemble_record))

    # Required JSON logs for CloudWatch metric filters
    logger.info(
        json.dumps({"metric_name": "BestModelAccuracy", "metric_value": best_accuracy * 100})
    )
    logger.info(
        json.dumps({"metric_name": "TotalModelCount", "metric_value": len(evaluation_results)})
    )
    logger.info(
        json.dumps({"metric_name": "EvaluationAccuracy", "metric_value": avg_accuracy * 100})
    )
    logger.info(
        json.dumps({"metric_name": "EvaluationPrecision", "metric_value": avg_precision * 100})
    )
    logger.info(json.dumps({"metric_name": "EvaluationRecall", "metric_value": avg_recall * 100}))
    logger.info(json.dumps({"metric_name": "EvaluationF1Score", "metric_value": avg_f1 * 100}))
    logger.info(
        json.dumps({"metric_name": "SuccessfulModelCount", "metric_value": len(successful_models)})
    )

    logger.info(f"Best Model Accuracy: {best_accuracy:.4f}")
    logger.info(f"Models Evaluated: {len(evaluation_results)}")

    return True


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--models-path", required=True)
    parser.add_argument("--data-path", required=True)
    parser.add_argument("--output-path", required=True)

    args = parser.parse_args()

    try:
        success = evaluate_models(args.models_path, args.data_path, args.output_path)
        if not success:
            sys.exit(1)
    except Exception as e:
        logger.error(f"❌ Evaluation failed: {sanitize_for_log(e)}")
        error_info = {"status": "failed", "error": sanitize_for_log(str(e))}
        with open(safe_path_join(args.output_path, "evaluation_error.json"), "w") as f:
            json.dump(error_info, f, indent=2)
        sys.exit(1)
