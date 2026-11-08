#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Training configuration shared by every trainer: hyperparameters, model settings, augmentation."""

import argparse
import os

# Parse hyperparameters if available


def get_hyperparameters():
    """Hyperparameters SageMaker passes as ``--KEY value`` arguments."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--TRAINING_EPOCHS", type=int, default=20)
    parser.add_argument("--TRAINING_BATCH_SIZE", type=int, default=32)
    parser.add_argument("--TRAINING_LEARNING_RATE", type=float, default=0.001)
    # With your own backbone weights: epochs in Phase 1 (frozen backbone, head
    # only); the rest of TRAINING_EPOCHS run in Phase 2 (unfrozen, 100x lower LR).
    parser.add_argument("--PHASE1_EPOCHS", type=int, default=10)

    # Only parse known args to avoid conflicts with other scripts
    args, _ = parser.parse_known_args()
    return args


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

# `phase2_unfreeze_layers` is the number of top backbone layers unfrozen in
# Phase 2 when your own backbone weights are loaded (scripts/training/_common.py).
# VGG16 has only ~19 layers, so a value >= depth unfreezes the whole backbone,
# which is fine at the Phase 2 learning rate.
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


# The from-scratch baseline (simple_cnn_trainer.py) is not an ensemble member,
# so it is not in MODEL_NAMES; its config is always present. Four conv blocks
# (conv, batch norm, max pool) and a small dense head, trained in one phase.
MODEL_CONFIGS["simple_cnn"] = {
    "input_size": (224, 224),
    "conv_filters": (32, 64, 128, 256),
    "dense_units": 128,
    "dropout_rate": 0.5,
}


# With your own backbone weights, training runs in two phases
# (scripts/training/_common.py): Phase 1 trains only the head with the backbone
# frozen, Phase 2 unfreezes the top layers at `learning_rate * phase2_lr_factor`,
# low enough not to wipe out what the loaded weights learned. Without weights
# every model trains in one phase with every layer trainable.
TRAINING_PARAMS = {
    "epochs": hp.TRAINING_EPOCHS,
    "batch_size": hp.TRAINING_BATCH_SIZE,
    "learning_rate": hp.TRAINING_LEARNING_RATE,
    "phase1_epochs": hp.PHASE1_EPOCHS,
    "phase2_lr_factor": 0.01,
    "patience": 5,
    "reduce_lr_patience": 3,
    "reduce_lr_factor": 0.5,
    "validation_split": 0.2,
    "mixed_precision": False,
}

# Data augmentation, training images only:
#   rotation_range=15        - slight rotation of the subject
#   width/height_shift=0.05  - minor framing differences
#   brightness=(0.8, 1.2)    - +/-20% illumination variation
#   horizontal/vertical flip - turn off a flip when orientation carries meaning
#   color_jitter_sigma=0.1   - per-image colour and intensity jitter
#                              (color_jitter.py), so the models cannot learn
#                              capture-session colour instead of content; 0 is off
AUGMENTATION_PARAMS = {
    "rotation_range": 15,
    "width_shift_range": 0.05,
    "height_shift_range": 0.05,
    "brightness_range": (0.8, 1.2),
    "horizontal_flip": True,
    "vertical_flip": True,
    "fill_mode": "constant",
    "cval": 0,
    "color_jitter_sigma": 0.1,
}


# SageMaker metric logging


def log_metric(metric_name, value):
    """Print a metric line the training job's MetricDefinitions match."""
    print(f"{metric_name}: {value}")


def log_training_metrics(model_name, epoch, metrics):
    """Print the per-epoch training metrics of one model."""
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

    missing_metrics = [m for m in required_metrics if m not in metrics]
    if missing_metrics:
        print(f"Warning: Missing metrics for {model_name}: {missing_metrics}")
        return

    log_metric(f"ModelTrainingAccuracy{model_suffix}", metrics["train_accuracy"])
    log_metric(f"ModelValidationAccuracy{model_suffix}", metrics["val_accuracy"])
    log_metric(f"ModelTrainingLoss{model_suffix}", metrics["train_loss"])
    log_metric(f"ModelValidationLoss{model_suffix}", metrics["val_loss"])
    log_metric(f"ModelTrainingPrecision{model_suffix}", metrics["train_precision"])
    log_metric(f"ModelTrainingRecall{model_suffix}", metrics["train_recall"])
    log_metric(f"ModelValidationPrecision{model_suffix}", metrics["val_precision"])
    log_metric(f"ModelValidationRecall{model_suffix}", metrics["val_recall"])
    log_metric(f"ModelEpochsCompleted{model_suffix}", epoch)

    overfitting_gap = metrics["train_accuracy"] - metrics["val_accuracy"]
    log_metric(f"ModelOverfittingGap{model_suffix}", overfitting_gap)


def get_model_config(model_name):
    """Configuration of one model, VGG16's when the name is unknown."""
    return MODEL_CONFIGS.get(model_name, MODEL_CONFIGS["vgg16"])


# Main CONFIG object that training scripts expect
CONFIG = {"models": MODEL_CONFIGS, "training": TRAINING_PARAMS, "augmentation": AUGMENTATION_PARAMS}
