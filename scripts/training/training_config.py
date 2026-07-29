#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Common training configuration for all models"""

import argparse
import os

# Parse hyperparameters if available


def get_hyperparameters():
    """Get hyperparameters from command line arguments"""
    parser = argparse.ArgumentParser()
    parser.add_argument("--TRAINING_EPOCHS", type=int, default=20)
    parser.add_argument("--TRAINING_BATCH_SIZE", type=int, default=32)
    parser.add_argument("--TRAINING_LEARNING_RATE", type=float, default=0.001)
    # Epochs spent in Phase 1 (frozen backbone, train head only). The remaining
    # TRAINING_EPOCHS - PHASE1_EPOCHS run in Phase 2 (unfrozen, 100x lower LR).
    parser.add_argument("--PHASE1_EPOCHS", type=int, default=10)

    # Only parse known args to avoid conflicts with other scripts
    args, _ = parser.parse_known_args()
    return args


# Get hyperparameters
try:
    hp = get_hyperparameters()
except (SystemExit, argparse.ArgumentError):
    # argparse raises SystemExit on bad input; fall back to defaults so the
    # training_config module is still importable in interactive/REPL contexts.
    class DefaultHP:
        TRAINING_EPOCHS = 20
        TRAINING_BATCH_SIZE = 32
        TRAINING_LEARNING_RATE = 0.001
        PHASE1_EPOCHS = 10

    hp = DefaultHP()

# Get model names from environment (passed from SageMaker pipeline parameters)
MODEL_NAMES = os.environ.get("MODEL_NAMES", "vgg16,densenet121,efficientnet").split(",")

# Dynamic model configurations based on model names.
#
# `phase2_unfreeze_layers` is the number of TOP base-model layers unfrozen in
# Phase 2 of two-phase transfer learning (see scripts/training/_common.py). The
# blog uses "top 30" for the deep backbones; VGG16 has only ~19 layers, so a
# value >= depth simply unfreezes the whole base, which is fine at the Phase 2
# learning rate (100x lower than Phase 1).
MODEL_CONFIGS = {}
for model_name in MODEL_NAMES:
    model_name = model_name.strip()
    if "vgg16" in model_name:
        MODEL_CONFIGS[model_name] = {
            "input_size": (224, 224),
            "phase2_unfreeze_layers": 8,
            "dense_units": 256,
            "dropout_rate": 0.5,
        }
    elif "densenet" in model_name:
        MODEL_CONFIGS[model_name] = {
            "input_size": (224, 224),
            "phase2_unfreeze_layers": 30,
            "dense_units": 256,
            "dropout_rate": 0.3,
        }
    elif "efficientnet" in model_name:
        MODEL_CONFIGS[model_name] = {
            "input_size": (224, 224),
            "phase2_unfreeze_layers": 30,
            "dense_units": 512,
            "dropout_rate": 0.4,
        }

# Fallback static configs if environment not available
if not MODEL_CONFIGS:
    MODEL_CONFIGS = {
        "vgg16": {
            "input_size": (224, 224),
            "phase2_unfreeze_layers": 8,
            "dense_units": 256,
            "dropout_rate": 0.5,
        },
        "densenet121": {
            "input_size": (224, 224),
            "phase2_unfreeze_layers": 30,
            "dense_units": 256,
            "dropout_rate": 0.3,
        },
        "efficientnet": {
            "input_size": (224, 224),
            "phase2_unfreeze_layers": 30,
            "dense_units": 512,
            "dropout_rate": 0.4,
        },
    }


# Common training parameters - uses hyperparameters with fallbacks.
#
# Two-phase transfer learning (see scripts/training/_common.py):
#   Phase 1 - freeze the pre-trained backbone, train only the classification
#             head at `learning_rate` (default 1e-3) for `phase1_epochs`.
#   Phase 2 - unfreeze the top N base layers, recompile at a 100x-lower rate
#             (`learning_rate * phase2_lr_factor`) and continue for the
#             remaining epochs. The 100x reduction prevents catastrophic
#             forgetting of the ImageNet features.
TRAINING_PARAMS = {
    "epochs": hp.TRAINING_EPOCHS,
    "batch_size": hp.TRAINING_BATCH_SIZE,
    "learning_rate": hp.TRAINING_LEARNING_RATE,
    "phase1_epochs": hp.PHASE1_EPOCHS,
    "phase2_lr_factor": 0.01,  # Phase 2 LR = learning_rate * 0.01 (100x lower)
    "patience": 5,
    "reduce_lr_patience": 3,
    "reduce_lr_factor": 0.5,
    "validation_split": 0.2,
    "mixed_precision": False,
}

# Data augmentation parameters. Medical-safe values from the blog: each one maps
# to a real-world imaging variation and must preserve diagnostic features.
#   rotation_range=15      - slight patient-positioning variation (beyond 15° is
#                            clinically unrealistic)
#   width/height_shift=0.05 - minor framing differences
#   brightness=(0.8, 1.2)  - ±20% scanner-calibration exposure variation
#   horizontal_flip=True   - bilateral anatomy (left breast mirrors right)
#   vertical_flip omitted  - vertically inverted images don't occur in practice
AUGMENTATION_PARAMS = {
    "rotation_range": 15,
    "width_shift_range": 0.05,
    "height_shift_range": 0.05,
    "brightness_range": (0.8, 1.2),
    "horizontal_flip": True,
    "fill_mode": "constant",
    "cval": 0,
}

# SageMaker metric logging


def log_metric(metric_name, value):
    """Log metric for SageMaker"""
    print(f"{metric_name}: {value}")


def log_training_metrics(model_name, epoch, metrics):
    """Log training metrics with proper formatting"""
    # Dynamic model name mapping based on actual model names
    model_suffix = model_name.replace("-", "").replace("_", "").title()

    required_metrics = [
        "train_accuracy",
        "val_accuracy",
        "train_loss",
        "val_loss",
        "train_precision",
        "train_recall",
        "val_precision",
        "val_recall",
    ]

    # Check if all required metrics are present
    missing_metrics = [m for m in required_metrics if m not in metrics]
    if missing_metrics:
        print(f"Warning: Missing metrics for {model_name}: {missing_metrics}")
        return

    # Log all metrics
    log_metric(f"ModelTrainingAccuracy{model_suffix}", metrics["train_accuracy"])
    log_metric(f"ModelValidationAccuracy{model_suffix}", metrics["val_accuracy"])
    log_metric(f"ModelTrainingLoss{model_suffix}", metrics["train_loss"])
    log_metric(f"ModelValidationLoss{model_suffix}", metrics["val_loss"])
    log_metric(f"ModelTrainingPrecision{model_suffix}", metrics["train_precision"])
    log_metric(f"ModelTrainingRecall{model_suffix}", metrics["train_recall"])
    log_metric(f"ModelValidationPrecision{model_suffix}", metrics["val_precision"])
    log_metric(f"ModelValidationRecall{model_suffix}", metrics["val_recall"])
    log_metric(f"ModelEpochsCompleted{model_suffix}", epoch)

    # Calculate and log overfitting gap
    overfitting_gap = metrics["train_accuracy"] - metrics["val_accuracy"]
    log_metric(f"ModelOverfittingGap{model_suffix}", overfitting_gap)


def get_model_config(model_name):
    """Get configuration for specific model"""
    return MODEL_CONFIGS.get(model_name, MODEL_CONFIGS["vgg16"])


# Main CONFIG object that training scripts expect
CONFIG = {"models": MODEL_CONFIGS, "training": TRAINING_PARAMS, "augmentation": AUGMENTATION_PARAMS}
