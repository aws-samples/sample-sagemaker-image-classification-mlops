#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""
Shared training utilities for VGG16, DenseNet121, and EfficientNet trainers.

Every trainer is a thin wrapper: it defines `create_<name>_model()` (architecture)
and `main()` (CLI + config glue). The rest - data loaders, callbacks, checkpoint
resume, model packaging, output validation, metric emission - lives here and
runs identically for all three.

Before this module existed, each trainer duplicated ~300 lines; an indentation
bug in the network-isolation weights path existed in 2 of 3 copies. Keeping a
single code path makes that class of bug impossible.
"""

from __future__ import annotations

import json
import logging
import os
import sys
import tarfile
from collections.abc import Callable

import tensorflow as tf
from spot_checkpoint import checkpoint_callback, resume_or_new
from tensorflow.keras.callbacks import EarlyStopping, ReduceLROnPlateau
from tensorflow.keras.preprocessing.image import ImageDataGenerator
from training_config import CONFIG
from training_metrics import send_training_metrics_to_cloudwatch

# The training tarball ships mlops_common next to this file; a local checkout
# has it one level up, in scripts/.
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from mlops_common.constants import CLASS_DIRS, DEFAULT_SEED, IMAGE_EXTENSIONS
from mlops_common.preprocess import KERAS_INTERPOLATION, imagenet_normalize
from mlops_common.seeds import set_seeds

logger = logging.getLogger(__name__)


def _camel_suffix(model_name: str) -> str:
    """Map a pipeline model key to the CamelCase suffix used in CloudWatch
    metric names (e.g. `densenet121` -> `Densenet121`)."""
    return model_name.replace("-", "").replace("_", "").title()


def resolve_weights_path(model_name: str) -> str | None:
    """Return the pre-downloaded ImageNet weights path injected by
    `SM_CHANNEL_WEIGHTS`, or None if network isolation is off.

    The training roots sync weights into /opt/ml/input/data/weights/<name>_weights.h5
    via the `weights` input channel (see `download_pretrained_weights.py`).
    """
    channel = os.environ.get("SM_CHANNEL_WEIGHTS")
    if not channel:
        return None
    candidate = os.path.join(channel, f"{model_name}_weights.h5")
    return candidate if os.path.exists(candidate) else None


def validate_training_dir(train_dir: str) -> bool:
    """Verify a channel contains both class directories with at least one image each."""
    if not train_dir or not os.path.exists(train_dir):
        logger.error("Training directory does not exist: %s", train_dir)
        return False

    for required in CLASS_DIRS:
        sub = os.path.join(train_dir, required)
        if not os.path.exists(sub):
            logger.error("Required directory missing: %s", sub)
            return False
        count = sum(1 for f in os.listdir(sub) if f.lower().endswith(IMAGE_EXTENSIONS))
        if count == 0:
            logger.error("No images found in %s", sub)
            return False
        logger.info("Found %d images in %s", count, required)
    return True


def build_data_generators(train_dir: str, input_size: int, val_dir: str | None = None):
    """Return (train_generator, val_generator).

    With a `validation` channel (the patient-grouped validation split from
    preprocessing) early stopping watches that split. Without one, Keras
    carves validation_split out of the training images, which can put images
    of one patient on both sides.

    The loader resizes with KERAS_INTERPOLATION and normalises with the shared
    imagenet_normalize, the same transform mlops_common.preprocess applies at
    evaluation and serving time. preprocessing_function runs after
    augmentation, so it replaces `rescale` rather than adding to it.
    """
    aug = CONFIG["augmentation"]
    train_cfg = CONFIG["training"]
    use_val_channel = bool(val_dir) and validate_training_dir(val_dir)
    split = None if use_val_channel else train_cfg["validation_split"]
    if not use_val_channel:
        logger.warning("No validation channel; using validation_split=%s of the train split", split)

    train_datagen = ImageDataGenerator(
        preprocessing_function=imagenet_normalize,
        rotation_range=aug["rotation_range"],
        width_shift_range=aug["width_shift_range"],
        height_shift_range=aug["height_shift_range"],
        brightness_range=aug["brightness_range"],
        horizontal_flip=aug["horizontal_flip"],
        fill_mode=aug["fill_mode"],
        cval=aug.get("cval", 0),
        validation_split=split or 0.0,
    )
    val_datagen = ImageDataGenerator(
        preprocessing_function=imagenet_normalize,
        validation_split=split or 0.0,
    )
    common = {
        "target_size": (input_size, input_size),
        "batch_size": train_cfg["batch_size"],
        "class_mode": "binary",
        "classes": list(CLASS_DIRS),
        "interpolation": KERAS_INTERPOLATION,
    }

    train_gen = train_datagen.flow_from_directory(
        train_dir, seed=DEFAULT_SEED, subset="training" if split else None, **common
    )
    if use_val_channel:
        val_gen = val_datagen.flow_from_directory(val_dir, shuffle=False, **common)
    else:
        val_gen = val_datagen.flow_from_directory(
            train_dir, shuffle=False, subset="validation", **common
        )
    return train_gen, val_gen


def compute_class_weight(labels) -> dict:
    """Balanced class weights, n / (n_classes * n_c), from the training labels.

    Replaces SMOTE: interpolating raw pixels between two tissue images makes
    implausible images, while weighting the loss corrects the imbalance
    without inventing data.
    """
    import numpy as np

    labels = np.asarray(labels, dtype=int)
    counts = np.bincount(labels, minlength=2)
    total = int(counts.sum())
    return {c: (total / (2.0 * n) if n else 0.0) for c, n in enumerate(counts.tolist())}


def build_callbacks() -> list:
    """Common callback stack: early stopping + LR-on-plateau + per-epoch checkpoint.

    ReduceLROnPlateau lowers the learning rate when validation loss stalls -
    medical-imaging curves plateau in waves, and a patience-5 EarlyStopping
    gives this callback room to trigger a reduction and let the model recover
    before training halts.

    Per-epoch metric emission is handled centrally by
    `training_metrics.send_training_metrics_to_cloudwatch()` at the end of
    training, so we don't duplicate emission via a custom Keras callback.
    """
    train_cfg = CONFIG["training"]
    return [
        EarlyStopping(
            patience=train_cfg["patience"],
            restore_best_weights=True,
            verbose=1,
        ),
        ReduceLROnPlateau(
            monitor="val_loss",
            factor=train_cfg["reduce_lr_factor"],
            patience=train_cfg["reduce_lr_patience"],
            verbose=1,
        ),
        checkpoint_callback(),
    ]


def save_and_package(
    model, model_dir: str, model_name: str, history_dict: dict
) -> tuple[str, dict]:
    """Save the trained model as .h5, wrap in model.tar.gz, persist history JSON.

    `history_dict` is the already-merged two-phase history (see
    `run_two_phase_fit`). Returns (model_tar_path, history_dict). Raises on
    I/O failure."""
    os.makedirs(model_dir, exist_ok=True)
    h5_path = os.path.join(model_dir, f"{model_name}_model.h5")
    model.save(h5_path)

    tar_path = os.path.join(model_dir, "model.tar.gz")
    with tarfile.open(tar_path, "w:gz") as tar:
        tar.add(h5_path, arcname=f"{model_name}_model.h5")

    with open(os.path.join(model_dir, "training_history.json"), "w") as f:
        json.dump(history_dict, f, indent=2)

    return tar_path, history_dict


def _extract_history(keras_history) -> dict:
    """Pull the metrics we persist out of a Keras History, tolerating the
    `precision_1`/`recall_1` suffixes Keras appends when metric names collide
    across recompiles."""
    h = keras_history.history

    def series(*names):
        for n in names:
            if n in h:
                return [float(x) for x in h[n]]
        return [0.0] * len(h.get("loss", []))

    return {
        "accuracy": series("accuracy"),
        "val_accuracy": series("val_accuracy"),
        "loss": series("loss"),
        "val_loss": series("val_loss"),
        "precision": series("precision", "precision_1", "precision_2"),
        "val_precision": series("val_precision", "val_precision_1", "val_precision_2"),
        "recall": series("recall", "recall_1", "recall_2"),
        "val_recall": series("val_recall", "val_recall_1", "val_recall_2"),
    }


def _merge_histories(first: dict, second: dict) -> dict:
    """Concatenate two phase histories key-by-key into one continuous run."""
    return {k: first.get(k, []) + second.get(k, []) for k in first}


def run_two_phase_fit(
    model,
    base,
    model_name: str,
    train_gen,
    val_gen,
    callbacks: list,
    learning_rate: float,
    epochs: int,
    initial_epoch: int,
    phase2_unfreeze_layers: int,
    class_weight: dict | None = None,
) -> dict:
    """Two-phase transfer learning, shared by all trainers.

    Phase 1 - backbone frozen, train only the classification head at
    `learning_rate`, for `phase1_epochs` epochs.
    Phase 2 - unfreeze the top `phase2_unfreeze_layers` base layers, recompile
    at a 100x-lower learning rate (`learning_rate * phase2_lr_factor`), and
    continue to `epochs`. The low rate prevents catastrophic forgetting of the
    ImageNet features while letting the top layers adapt to the medical domain.

    Returns the merged history dict spanning both phases. If a spot resume put
    us past Phase 1 already (`initial_epoch >= phase1_epochs`), Phase 1 is
    skipped and we resume directly in the unfrozen Phase 2 configuration.
    """
    train_cfg = CONFIG["training"]
    phase1_epochs = min(train_cfg["phase1_epochs"], epochs)
    phase2_lr = learning_rate * train_cfg["phase2_lr_factor"]

    history1 = {}
    if initial_epoch < phase1_epochs:
        # Phase 1: freeze the whole backbone, train the head.
        base.trainable = False
        model.compile(
            optimizer=tf.keras.optimizers.Adam(learning_rate=learning_rate),
            loss="binary_crossentropy",
            metrics=["accuracy", tf.keras.metrics.Precision(), tf.keras.metrics.Recall()],
        )
        logger.info(
            "=== %s Phase 1 (frozen backbone, lr=%.2e) epochs %d->%d ===",
            model_name,
            learning_rate,
            initial_epoch,
            phase1_epochs,
        )
        h1 = model.fit(
            train_gen,
            validation_data=val_gen,
            epochs=phase1_epochs,
            initial_epoch=initial_epoch,
            callbacks=callbacks,
            class_weight=class_weight,
            verbose=1,
        )
        history1 = _extract_history(h1)
        phase2_initial_epoch = phase1_epochs
    else:
        phase2_initial_epoch = initial_epoch

    # Phase 2: unfreeze the top N base layers, recompile at the lower rate.
    base.trainable = True
    if phase2_unfreeze_layers < len(base.layers):
        for layer in base.layers[:-phase2_unfreeze_layers]:
            layer.trainable = False
    logger.info(
        "=== %s Phase 2 (top %d layers unfrozen, lr=%.2e) epochs %d->%d ===",
        model_name,
        phase2_unfreeze_layers,
        phase2_lr,
        phase2_initial_epoch,
        epochs,
    )
    model.compile(
        optimizer=tf.keras.optimizers.Adam(learning_rate=phase2_lr),
        loss="binary_crossentropy",
        metrics=["accuracy", tf.keras.metrics.Precision(), tf.keras.metrics.Recall()],
    )
    h2 = model.fit(
        train_gen,
        validation_data=val_gen,
        epochs=epochs,
        initial_epoch=phase2_initial_epoch,
        callbacks=callbacks,
        class_weight=class_weight,
        verbose=1,
    )
    history2 = _extract_history(h2)

    return _merge_histories(history1, history2) if history1 else history2


def validate_outputs(model_dir: str, model_name: str) -> bool:
    """Verify model + tar.gz + history were written and tar is plausible."""
    required = [
        os.path.join(model_dir, f"{model_name}_model.h5"),
        os.path.join(model_dir, "model.tar.gz"),
        os.path.join(model_dir, "training_history.json"),
    ]
    missing = [f for f in required if not os.path.exists(f)]
    if missing:
        logger.error("Missing required output files: %s", missing)
        return False
    size = os.path.getsize(os.path.join(model_dir, "model.tar.gz"))
    if size < 1000:
        logger.error("Model tar.gz too small (%d bytes) - likely corrupt", size)
        return False
    logger.info("Outputs validated (model.tar.gz = %d bytes)", size)
    return True


def run_training(
    model_name: str,
    model_builder: Callable,
    model_dir: str,
    train_dir: str,
    val_dir: str | None = None,
) -> bool:
    """Entire training loop, identical across all three trainer scripts.

    `model_builder` takes (learning_rate, weights_path) -> (model, base_model).
    The trainer script only provides this function - everything else is
    orchestrated here.
    """
    if not model_dir:
        logger.error("model_dir is required")
        return False
    try:
        os.makedirs(model_dir, exist_ok=True)
    except OSError as exc:
        logger.error("Cannot create model directory: %s", exc)
        return False

    if not validate_training_dir(train_dir):
        return False

    train_cfg = CONFIG["training"]
    epochs = train_cfg["epochs"]
    batch_size = train_cfg["batch_size"]
    learning_rate = train_cfg["learning_rate"]
    logger.info(
        "=== %s Training Started ===\nmodel_dir=%s  train_dir=%s  epochs=%s  batch_size=%s  lr=%s",
        model_name,
        model_dir,
        train_dir,
        epochs,
        batch_size,
        learning_rate,
    )

    set_seeds(DEFAULT_SEED)
    tf.keras.mixed_precision.set_global_policy("float32")

    model_cfg = CONFIG["models"][model_name]
    weights_path = resolve_weights_path(model_name)

    # model_builder returns (compiled_model, base_model). The base model is the
    # pre-trained backbone whose layers we freeze in Phase 1 and selectively
    # unfreeze in Phase 2.
    model, base = model_builder(learning_rate, weights_path)

    input_size = model_cfg["input_size"][0]
    train_gen, val_gen = build_data_generators(train_dir, input_size, val_dir)
    class_weight = compute_class_weight(train_gen.classes)
    logger.info("Class weights (benign=0, malignant=1): %s", class_weight)

    callbacks = build_callbacks()
    initial_epoch = resume_or_new(model)

    history = run_two_phase_fit(
        model=model,
        base=base,
        model_name=model_name,
        train_gen=train_gen,
        val_gen=val_gen,
        callbacks=callbacks,
        learning_rate=learning_rate,
        epochs=epochs,
        initial_epoch=initial_epoch,
        phase2_unfreeze_layers=model_cfg["phase2_unfreeze_layers"],
        class_weight=class_weight,
    )

    tar_path, history_dict = save_and_package(model, model_dir, model_name, history)

    if not validate_outputs(model_dir, model_name):
        return False

    # Single metric emission path (no duplicate in-band Keras callback).
    send_training_metrics_to_cloudwatch(model_name, history_dict)

    # Guard against an empty history: a spot resume at/after the final epoch
    # makes model.fit run 0 epochs, leaving every metric list empty. The model
    # is already saved at this point, so don't turn a recoverable resume into a
    # failed job by indexing [-1] into an empty list.
    def _last(series):
        return series[-1] if series else 0.0

    final_acc = _last(history_dict["val_accuracy"])
    final_precision = _last(history_dict["val_precision"])
    final_recall = _last(history_dict["val_recall"])
    f1 = (
        2 * final_precision * final_recall / (final_precision + final_recall)
        if (final_precision + final_recall) > 0
        else 0.0
    )
    logger.info(
        "%s training complete - val_acc=%.4f, F1=%.4f, tar=%s",
        model_name,
        final_acc,
        f1,
        tar_path,
    )
    return True


def parse_common_args():
    """Paths only. SageMaker also passes hyperparameters as `--KEY value`;
    training_config reads those, so they are left to parse_known_args here."""
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--model-dir",
        default=os.environ.get("SM_MODEL_DIR", "/opt/ml/model"),
    )
    parser.add_argument(
        "--train",
        default=os.environ.get("SM_CHANNEL_TRAINING", "/opt/ml/input/data/training"),
    )
    parser.add_argument(
        "--validation",
        default=os.environ.get("SM_CHANNEL_VALIDATION"),
        help="Optional validation channel (patient-grouped split from preprocessing)",
    )
    args, _ = parser.parse_known_args()
    return args


def trainer_main(model_name: str, model_builder: Callable) -> None:
    """Entry point used by every trainer's `if __name__ == "__main__":`."""
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(levelname)s - %(message)s",
    )
    args = parse_common_args()
    try:
        ok = run_training(model_name, model_builder, args.model_dir, args.train, args.validation)
        sys.exit(0 if ok else 1)
    except Exception as exc:
        logger.error("%s training script failed: %s", model_name, exc, exc_info=True)
        sys.exit(1)
