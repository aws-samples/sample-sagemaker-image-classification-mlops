#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import argparse
import json
import logging
import os
import sys
import tarfile
from pathlib import Path

import boto3
import numpy as np
import tensorflow as tf
from sklearn.metrics import (
    accuracy_score,
    f1_score,
    precision_score,
    recall_score,
    roc_auc_score,
)
from tensorflow.keras.preprocessing.image import ImageDataGenerator

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger(__name__)

# ImageNet channel statistics - pixel normalization is `/255` then per-channel
# `(x - mean) / std`. These MUST match scripts/training/_common.py so the
# ensemble sees the exact transform training applied (no training-serving skew).
IMAGENET_MEAN = [0.485, 0.456, 0.406]
IMAGENET_STD = [0.229, 0.224, 0.225]

# Clinical quality gates - module-level so they are tunable in one place.
# Recall is weighted highest: a missed malignant case is the costly error.
CLINICAL_QUALITY_THRESHOLDS = {
    "accuracy": 0.85,
    "recall": 0.95,
    "auc_roc": 0.90,
    "precision": 0.80,
}


def imagenet_normalize(image):
    """Scale a 0-255 image to 0-1 then align to ImageNet channel statistics.

    Used as the Keras `preprocessing_function`; it replaces `rescale` so the
    ensemble sees the same normalization training applied (see _common.py).
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


_cloudwatch_client = None


def get_cloudwatch_client():
    global _cloudwatch_client
    if _cloudwatch_client is None:
        region = os.environ.get("AWS_REGION", "us-east-1")
        _cloudwatch_client = boto3.client("cloudwatch", region_name=region)
    return _cloudwatch_client


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
    for root, _, files in os.walk(model_path):
        for file in files:
            if file.endswith(".h5"):
                return os.path.join(root, file)
        for file in files:
            if file == "model.tar.gz":
                with tarfile.open(os.path.join(root, file), "r:gz") as tar:
                    for member in tar.getmembers():
                        if member.name.endswith(".h5"):
                            _safe_extract_member(tar, member, root)
                            return os.path.join(root, member.name)
    return None


def load_and_copy_models(models_path, output_path, model_names):
    copied_models = []
    loaded_models = {}

    for model_name in model_names:
        model_file = find_model_file(safe_path_join(models_path, model_name))
        if model_file:
            try:
                model = tf.keras.models.load_model(model_file)
                saved_dir = safe_path_join(output_path, f"{model_name}_model", "1")
                os.makedirs(saved_dir, exist_ok=True)
                # Keras 3 (TF 2.16+) removed save_format='tf'; use export() for
                # SavedModel format which is required by SageMaker TF Serving.
                if hasattr(model, "export"):
                    model.export(saved_dir)
                else:
                    # Fallback for Keras 2 / older TF versions
                    model.save(saved_dir, save_format="tf")
                copied_models.append(model_name)
                loaded_models[model_name] = model
                logger.info(f"✅ Loaded and copied {sanitize_for_log(model_name)}")
            except Exception as e:
                logger.warning(
                    f"❌ Failed to process {sanitize_for_log(model_name)}: {sanitize_for_log(e)}"
                )

    return copied_models, loaded_models


def calculate_weights(copied_models, evaluation_path):
    eval_file = safe_path_join(evaluation_path, "evaluation_results.json")
    if os.path.exists(eval_file):
        with open(eval_file) as f:
            eval_results = json.load(f)

        # Filter out models with accuracy of 0.0
        valid_models = []
        accuracies = []

        for model_name in copied_models:
            accuracy = eval_results.get(model_name, {}).get("accuracy", 0.0)
            if accuracy > 0.0:
                valid_models.append(model_name)
                accuracies.append(accuracy)

        if valid_models and sum(accuracies) > 0:
            total_accuracy = sum(accuracies)
            weights = [acc / total_accuracy for acc in accuracies]
            # Get optimal threshold from evaluation
            optimal_threshold = eval_results.get("ensemble_optimal_threshold", 0.5)
            return valid_models, weights, optimal_threshold

    # Fallback: use all models with equal weights
    return copied_models, [1.0 / len(copied_models)] * len(copied_models), 0.5


def create_ensemble_package(output_path, copied_models, weights, optimal_threshold):
    try:
        config = {
            "models": copied_models,
            "weights": weights,
            "ensemble_method": "weighted_average",
            "optimal_threshold": optimal_threshold,
        }

        with open(safe_path_join(output_path, "ensemble_config.json"), "w") as f:
            json.dump(config, f, indent=2)

        # Copy inference script
        script_dir = os.path.dirname(__file__)
        inference_src = os.path.join(script_dir, "inference.py")
        inference_dst = safe_path_join(output_path, "inference.py")

        if os.path.exists(inference_src):
            import shutil

            shutil.copy2(inference_src, inference_dst)
        else:
            logger.warning("inference.py not found, creating basic version")
            with open(inference_dst, "w") as f:
                f.write("# Basic inference script - replace with full implementation\n")

        with open(safe_path_join(output_path, "requirements.txt"), "w") as f:
            # Must match scripts/ensemble/requirements.txt exactly - TF 2.19
            # wheels require numpy<2.2, so numpy is pinned at 2.1.3 rather
            # than the latest 2.4.x. When we bump to a newer DLC the two
            # files must move together.
            f.write("tensorflow==2.19.0\nnumpy==2.1.3\n")

        # Create tar.gz at root level for SageMaker Model Registry
        model_tar_path = safe_path_join(output_path, "model.tar.gz")
        with tarfile.open(model_tar_path, "w:gz") as tar:
            tar.add(
                safe_path_join(output_path, "ensemble_config.json"), arcname="ensemble_config.json"
            )
            tar.add(inference_dst, arcname="inference.py")
            tar.add(safe_path_join(output_path, "requirements.txt"), arcname="requirements.txt")

            for model_name in copied_models:
                model_dir = safe_path_join(output_path, f"{model_name}_model")
                for root, _, files in os.walk(model_dir):
                    for file in files:
                        file_path = os.path.join(root, file)
                        arcname = os.path.relpath(file_path, output_path)
                        tar.add(file_path, arcname=arcname)

        logger.info(f"Created model.tar.gz at: {model_tar_path}")

        # Verify the tar.gz file exists
        if os.path.exists(model_tar_path):
            logger.info(
                f"✅ model.tar.gz created successfully ({os.path.getsize(model_tar_path)} bytes)"
            )
            return True
        else:
            logger.error("❌ Failed to create model.tar.gz")
            return False

    except Exception as e:
        logger.error(f"❌ Error creating ensemble package: {sanitize_for_log(e)}")
        return False


def test_ensemble(loaded_models, weights, data_path, optimal_threshold=0.5):
    if not os.path.exists(data_path):
        logger.warning(f"Test data path does not exist: {sanitize_for_log(data_path)}")
        return {
            "ensemble_accuracy": 0.0,
            "ensemble_precision": 0.0,
            "ensemble_recall": 0.0,
            "ensemble_f1": 0.0,
            "ensemble_auc": 0.0,
        }

    try:
        # Same preprocessing as training: /255 then ImageNet mean/std via
        # preprocessing_function (replaces rescale - must not pass both).
        test_gen = ImageDataGenerator(
            preprocessing_function=imagenet_normalize
        ).flow_from_directory(
            data_path, target_size=(224, 224), batch_size=32, class_mode="binary", shuffle=False
        )

        ensemble_preds = None
        for i, (_model_name, model) in enumerate(loaded_models.items()):
            test_gen.reset()
            preds = model.predict(test_gen, verbose=0) * weights[i]
            ensemble_preds = preds if ensemble_preds is None else ensemble_preds + preds

        y_scores = ensemble_preds.flatten()
        y_pred = (ensemble_preds > optimal_threshold).astype(int).flatten()
        y_true = test_gen.classes

        try:
            ensemble_auc = float(roc_auc_score(y_true, y_scores))
        except ValueError:
            # Single-class test set - AUC is undefined; treat as unavailable.
            ensemble_auc = 0.0

        return {
            "ensemble_accuracy": float(accuracy_score(y_true, y_pred)),
            "ensemble_precision": float(precision_score(y_true, y_pred, zero_division=0)),
            "ensemble_recall": float(recall_score(y_true, y_pred, zero_division=0)),
            "ensemble_f1": float(f1_score(y_true, y_pred, zero_division=0)),
            "ensemble_auc": ensemble_auc,
        }
    except Exception as e:
        logger.error(f"Ensemble testing failed: {sanitize_for_log(e)}")
        return {
            "ensemble_accuracy": 0.0,
            "ensemble_precision": 0.0,
            "ensemble_recall": 0.0,
            "ensemble_f1": 0.0,
            "ensemble_auc": 0.0,
        }


def create_ensemble(models_path, evaluation_path, data_path, output_path):
    logger.info("=== Ensemble Creation Started ===")
    logger.info(f"Models path: {sanitize_for_log(models_path)}")
    logger.info(f"Evaluation path: {sanitize_for_log(evaluation_path)}")
    logger.info(f"Data path: {sanitize_for_log(data_path)}")
    logger.info(f"Output path: {sanitize_for_log(output_path)}")

    # Get model names from environment for consistency
    model_names = os.environ.get("MODEL_NAMES", "vgg16,densenet121,efficientnet").split(",")
    model_names = [name.strip() for name in model_names]
    os.makedirs(output_path, exist_ok=True)

    # Load and copy models (single pass)
    copied_models, loaded_models = load_and_copy_models(models_path, output_path, model_names)

    if not copied_models:
        logger.error("❌ No models copied")
        return False

    # Load evaluation results for training history
    evaluation_results = {}
    eval_file = safe_path_join(evaluation_path, "evaluation_results.json")
    if os.path.exists(eval_file):
        with open(eval_file) as f:
            evaluation_results = json.load(f)

    # Calculate weights and filter valid models
    valid_models, weights, optimal_threshold = calculate_weights(copied_models, evaluation_path)
    logger.info(f"Valid models: {valid_models}")
    logger.info(f"Weights: {dict(zip(valid_models, weights))}")
    logger.info(f"Optimal threshold: {optimal_threshold:.3f}")

    if len(valid_models) != len(copied_models):
        excluded = set(copied_models) - set(valid_models)
        logger.info(f"Excluded models with accuracy=0.0: {excluded}")

    # Create ensemble package with only valid models
    if not create_ensemble_package(output_path, valid_models, weights, optimal_threshold):
        logger.error("❌ Failed to create ensemble package")
        return False

    # Filter loaded models to match valid models
    valid_loaded_models = {
        name: model for name, model in loaded_models.items() if name in valid_models
    }

    # Test ensemble performance
    test_results = test_ensemble(valid_loaded_models, weights, data_path, optimal_threshold)

    # Prepare final results
    results = {
        **test_results,
        "model_count": len(valid_models),
        "excluded_models": len(copied_models) - len(valid_models),
    }

    # Clinical quality gate on the ensemble metrics. AUC is the real ensemble
    # roc_auc from test_ensemble; if it's unavailable (single-class test set)
    # we drop auc_roc from the gate rather than failing on a phantom 0.
    ensemble_auc = test_results.get("ensemble_auc", 0.0)
    auc_available = ensemble_auc > 0.0
    gate_metrics = {
        "accuracy": test_results["ensemble_accuracy"],
        "recall": test_results["ensemble_recall"],
        "precision": test_results["ensemble_precision"],
    }
    gate_thresholds = dict(CLINICAL_QUALITY_THRESHOLDS)
    if auc_available:
        gate_metrics["auc_roc"] = ensemble_auc
    else:
        gate_thresholds.pop("auc_roc", None)
        logger.warning("auc_roc unavailable - skipping AUC clinical gate")

    gate_passed, gate_results = evaluate_clinical_quality(gate_metrics, gate_thresholds)
    results["clinical_quality_gate"] = {
        "passed": gate_passed,
        "results": gate_results,
        "auc_roc_available": auc_available,
        "thresholds": gate_thresholds,
    }

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

    # Save results
    with open(safe_path_join(output_path, "ensemble_results.json"), "w") as f:
        json.dump(results, f, indent=2)

    # Send metrics (both JSON logs for Terraform and API for immediate use)
    logger.info(
        json.dumps(
            {"metric_name": "EnsembleAccuracy", "metric_value": results["ensemble_accuracy"] * 100}
        )
    )
    logger.info(
        json.dumps(
            {
                "metric_name": "EnsemblePrecision",
                "metric_value": results["ensemble_precision"] * 100,
            }
        )
    )
    logger.info(
        json.dumps(
            {"metric_name": "EnsembleRecall", "metric_value": results["ensemble_recall"] * 100}
        )
    )
    logger.info(
        json.dumps({"metric_name": "EnsembleF1Score", "metric_value": results["ensemble_f1"] * 100})
    )
    logger.info(
        json.dumps(
            {"metric_name": "EnsembleAUC", "metric_value": results.get("ensemble_auc", 0.0) * 100}
        )
    )

    # Training history record for table dashboard
    from datetime import datetime

    training_summary = {
        "training_version": os.environ.get(
            "CODEBUILD_BUILD_NUMBER", f"v{datetime.now().strftime('%Y%m%d_%H%M')}"
        ),
        "timestamp": datetime.now().isoformat(),
        "vgg16_accuracy": round(evaluation_results.get("vgg16", {}).get("accuracy", 0) * 100, 1),
        # Dynamic model accuracy based on actual model names
        **{
            f"{model_name}_accuracy": round(
                evaluation_results.get(model_name, {}).get("accuracy", 0) * 100, 1
            )
            for model_name in valid_models
            if model_name != "vgg16"
        },
        "ensemble_accuracy": round(results["ensemble_accuracy"] * 100, 1),
        "best_model": max(
            valid_models, key=lambda k: evaluation_results.get(k, {}).get("accuracy", 0)
        )
        if valid_models
        else "none",
        "status": "completed",
    }

    logger.info(json.dumps(training_summary))

    # Metrics logged via existing JSON system

    logger.info(f"✅ Ensemble created with {len(copied_models)} models")
    logger.info(
        f"Ensemble Accuracy: {results['ensemble_accuracy']:.3f}, F1: {results['ensemble_f1']:.3f}"
    )

    # Log accuracy for monitoring (conditional approval will be handled by auto-deployment Lambda)
    logger.info(
        f"ENSEMBLE_ACCURACY_THRESHOLD_CHECK: {results['ensemble_accuracy']:.4f} vs threshold {os.environ.get('MODEL_QUALITY_THRESHOLD', '0.85')}"
    )

    # Determine if model meets quality threshold
    threshold = float(os.environ.get("MODEL_QUALITY_THRESHOLD", "0.85"))
    meets_threshold = results["ensemble_accuracy"] >= threshold
    logger.info(
        f"MODEL_QUALITY_CHECK: {'PASS' if meets_threshold else 'FAIL'} - Accuracy {results['ensemble_accuracy']:.4f} {'≥' if meets_threshold else '<'} {threshold}"
    )

    return True


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--models-path", required=True)
    parser.add_argument("--evaluation-path", required=True)
    parser.add_argument("--data-path", required=True)
    parser.add_argument("--output-path", required=True)

    args = parser.parse_args()

    try:
        success = create_ensemble(
            args.models_path, args.evaluation_path, args.data_path, args.output_path
        )
        if not success:
            sys.exit(1)
    except Exception as e:
        logger.error(f"❌ Ensemble creation failed: {sanitize_for_log(e)}")
        sys.exit(1)
