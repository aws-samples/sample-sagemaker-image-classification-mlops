#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Build the weighted ensemble, tune its threshold and score the clinical gate.

- Weights come from each model's VALIDATION accuracy (evaluation step output).
- The ensemble decision threshold is tuned on the VALIDATION split.
- The clinical gate (ensemble_results.json, read by the pipeline Condition
  step) is scored on the TEST split at that threshold.
- predictions.json carries the ensemble's test scores, labels, the threshold
  and the per-image sensitive attributes, so the fairness gate scores exactly
  the model that would be deployed.
"""

import argparse
import json
import logging
import os
import shutil
import sys
import tarfile
from datetime import UTC, datetime
from pathlib import Path

import numpy as np

# The step's code directory holds mlops_common next to this file; a local
# checkout has it one level up, in scripts/.
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from mlops_common.breakhis import magnification, patient_id
from mlops_common.datasets import list_labeled_images, predict_scores
from mlops_common.gates import (
    CLINICAL_QUALITY_THRESHOLDS,
    binary_metrics,
    clinical_gate,
    select_threshold,
)
from mlops_common.preprocess import MODEL_INPUT_SIZE
from mlops_common.safe_tar import find_model_file

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
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


def load_and_export_models(models_path, output_path, model_names):
    """Load each trained .h5 and export it as a SavedModel for TF Serving."""
    import tensorflow as tf

    loaded = {}
    for model_name in model_names:
        model_file = find_model_file(safe_path_join(models_path, model_name))
        if not model_file:
            logger.warning("No model file for %s", sanitize_for_log(model_name))
            continue
        try:
            model = tf.keras.models.load_model(model_file)
            saved_dir = safe_path_join(output_path, f"{model_name}_model", "1")
            os.makedirs(saved_dir, exist_ok=True)
            # Keras 3 removed save_format='tf'; export() writes the SavedModel.
            model.export(saved_dir)
            loaded[model_name] = model
            logger.info("Loaded and exported %s", sanitize_for_log(model_name))
        except Exception as e:
            logger.warning(
                "Failed to process %s: %s", sanitize_for_log(model_name), sanitize_for_log(e)
            )
    return loaded


def calculate_weights(model_names, evaluation_results):
    """Weights proportional to each model's validation accuracy.

    Validation, not test: weighting by test accuracy would let the test split
    shape the model it is later used to judge. Falls back to equal weights.
    """
    accuracies = {}
    for name in model_names:
        entry = evaluation_results.get(name, {})
        acc = (entry.get("validation_metrics") or {}).get("accuracy", 0.0)
        if acc > 0.0 and "error" not in entry:
            accuracies[name] = acc
    if accuracies:
        total = sum(accuracies.values())
        return {name: acc / total for name, acc in accuracies.items()}
    return {name: 1.0 / len(model_names) for name in model_names}


def ensemble_scores(models, weights, paths):
    """Weighted average of the member models' malignant probabilities."""
    total = np.zeros(len(paths), dtype=float)
    for name, model in models.items():

        def predict(batch, model=model):
            return model.predict(batch, verbose=0)

        total += weights[name] * predict_scores(predict, paths, MODEL_INPUT_SIZE)
    return total


def create_ensemble_package(output_path, weights, threshold):
    config = {
        "models": list(weights),
        "weights": [weights[name] for name in weights],
        "ensemble_method": "weighted_average",
        "optimal_threshold": threshold,
        "threshold_selected_on": "validation",
    }
    with open(safe_path_join(output_path, "ensemble_config.json"), "w") as f:
        json.dump(config, f, indent=2)

    inference_src = os.path.join(os.path.dirname(os.path.abspath(__file__)), "inference.py")
    inference_dst = safe_path_join(output_path, "inference.py")
    shutil.copy2(inference_src, inference_dst)

    # Must match scripts/ensemble/requirements.txt: TF 2.19 wheels need numpy<2.2.
    with open(safe_path_join(output_path, "requirements.txt"), "w") as f:
        f.write("tensorflow==2.19.0\nnumpy==2.1.3\n")

    model_tar_path = safe_path_join(output_path, "model.tar.gz")
    with tarfile.open(model_tar_path, "w:gz") as tar:
        for name in ("ensemble_config.json", "inference.py", "requirements.txt"):
            tar.add(safe_path_join(output_path, name), arcname=name)
        for model_name in weights:
            model_dir = safe_path_join(output_path, f"{model_name}_model")
            for root, _, files in os.walk(model_dir):
                for file in files:
                    file_path = os.path.join(root, file)
                    tar.add(file_path, arcname=os.path.relpath(file_path, output_path))
    logger.info("Created %s (%d bytes)", model_tar_path, os.path.getsize(model_tar_path))


def write_predictions(output_path, test_items, test_root, scores, threshold):
    """predictions.json for the fairness gate: the deployed ensemble on test."""
    filenames = [os.path.relpath(p, test_root) for p, _ in test_items]
    payload = {
        "split": "test",
        "model": "ensemble",
        "threshold": threshold,
        "scores": [float(s) for s in scores],
        "labels": [int(label) for _, label in test_items],
        "filenames": filenames,
        # BreakHis carries no demographic metadata. Magnification is the
        # available subgroup proxy; add a real attribute per image here (same
        # order as filenames) for clinical use.
        "sensitive_features": {
            "magnification": [magnification(f) or "unknown" for f in filenames],
        },
        "patient_ids": [patient_id(f) for f in filenames],
    }
    with open(safe_path_join(output_path, "predictions.json"), "w") as f:
        json.dump(payload, f)


def create_ensemble(models_path, evaluation_path, data_path, validation_dir, output_path):
    logger.info("=== Ensemble Creation Started ===")
    model_names = [
        n.strip()
        for n in os.environ.get("MODEL_NAMES", "vgg16,densenet121,efficientnet").split(",")
        if n.strip()
    ]
    os.makedirs(output_path, exist_ok=True)

    loaded = load_and_export_models(models_path, output_path, model_names)
    if not loaded:
        logger.error("No models loaded")
        return False

    evaluation_results = {}
    eval_file = safe_path_join(evaluation_path, "evaluation_results.json")
    if os.path.exists(eval_file):
        with open(eval_file) as f:
            evaluation_results = json.load(f)

    weights = calculate_weights(list(loaded), evaluation_results)
    models = {name: loaded[name] for name in weights}
    logger.info("Ensemble weights: %s", weights)

    val_items = list_labeled_images(validation_dir)
    test_items = list_labeled_images(data_path)
    if not val_items or not test_items:
        logger.error(
            "Validation (%d) and test (%d) splits must both contain images",
            len(val_items),
            len(test_items),
        )
        return False

    val_scores = ensemble_scores(models, weights, [p for p, _ in val_items])
    threshold, selection = select_threshold(
        [label for _, label in val_items],
        val_scores,
        min_recall=CLINICAL_QUALITY_THRESHOLDS["recall"],
    )
    logger.info("Decision threshold %.2f tuned on %d validation images", threshold, len(val_items))

    test_scores = ensemble_scores(models, weights, [p for p, _ in test_items])
    test_metrics = binary_metrics([label for _, label in test_items], test_scores, threshold)
    gate = clinical_gate(test_metrics)

    create_ensemble_package(output_path, weights, threshold)
    write_predictions(output_path, test_items, data_path, test_scores, threshold)

    results = {
        "ensemble_accuracy": test_metrics["accuracy"],
        "ensemble_precision": test_metrics["precision"],
        "ensemble_recall": test_metrics["recall"],
        "ensemble_f1": test_metrics["f1_score"],
        # The Condition step reads this with JsonGet, so it must be a number.
        "ensemble_auc": test_metrics["auc_roc"] or 0.0,
        "decision_threshold": threshold,
        "threshold_selection": selection,
        "scored_on": "test",
        "n_test": len(test_items),
        "n_validation": len(val_items),
        "weights": weights,
        "model_count": len(weights),
        "excluded_models": len(model_names) - len(weights),
        "clinical_quality_gate": gate,
    }
    with open(safe_path_join(output_path, "ensemble_results.json"), "w") as f:
        json.dump(results, f, indent=2)

    logger.info("Clinical quality gate on test: %s", "PASSED" if gate["passed"] else "FAILED")
    for metric, detail in gate["results"].items():
        if not detail["passed"]:
            logger.warning(
                "%s: %.4f (threshold %s, gap %+.4f)",
                metric,
                detail["value"],
                detail["threshold"],
                detail["gap"],
            )

    for name, key in (
        ("EnsembleAccuracy", "ensemble_accuracy"),
        ("EnsemblePrecision", "ensemble_precision"),
        ("EnsembleRecall", "ensemble_recall"),
        ("EnsembleF1Score", "ensemble_f1"),
        ("EnsembleAUC", "ensemble_auc"),
    ):
        logger.info(json.dumps({"metric_name": name, "metric_value": results[key] * 100}))

    # Training history record for the dashboard table.
    logger.info(
        json.dumps(
            {
                "training_version": os.environ.get(
                    "CODEBUILD_BUILD_NUMBER",
                    f"v{datetime.now(UTC).strftime('%Y%m%d_%H%M')}",
                ),
                "timestamp": datetime.now(UTC).isoformat(),
                **{
                    f"{name}_accuracy": round(
                        evaluation_results.get(name, {}).get("accuracy", 0) * 100, 1
                    )
                    for name in weights
                },
                "ensemble_accuracy": round(results["ensemble_accuracy"] * 100, 1),
                "best_model": max(
                    weights,
                    key=lambda k: (
                        evaluation_results.get(k, {}).get("validation_metrics") or {}
                    ).get("accuracy", 0),
                ),
                "status": "completed",
            }
        )
    )
    return True


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--models-path", required=True)
    parser.add_argument("--evaluation-path", required=True)
    parser.add_argument("--data-path", required=True, help="Test split")
    parser.add_argument(
        "--validation-dir",
        default=DEFAULT_VALIDATION_DIR,
        help="Validation split, used to tune the ensemble decision threshold",
    )
    parser.add_argument("--output-path", required=True)
    args = parser.parse_args()

    try:
        if not create_ensemble(
            args.models_path,
            args.evaluation_path,
            args.data_path,
            args.validation_dir,
            args.output_path,
        ):
            sys.exit(1)
    except Exception as e:
        logger.error("Ensemble creation failed: %s", sanitize_for_log(e))
        sys.exit(1)
