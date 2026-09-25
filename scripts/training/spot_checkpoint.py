# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""
Spot-training checkpoint helpers shared by all SageMaker trainer scripts.

When a training job runs with `EnableManagedSpotTraining = true` SageMaker mounts
the checkpoint S3 prefix at `/opt/ml/checkpoints` (or the path in
`SM_CHECKPOINT_CONFIG_LOCAL_PATH`) and auto-syncs both directions:

- Job start: S3 prefix -> local path
- Job in progress: local writes stream to S3 in near-real-time
- Spot interruption: job restarts, sees existing checkpoints, resumes from the latest epoch

These helpers return:
- the checkpoint directory (creating it if needed)
- a Keras `ModelCheckpoint` callback that writes one file per epoch
- the initial epoch to resume from (or 0 on a fresh run)

Docs: https://docs.aws.amazon.com/sagemaker/latest/dg/model-managed-spot-training.html
"""

import logging
import os
import re

import tensorflow as tf

logger = logging.getLogger(__name__)

_DEFAULT_CHECKPOINT_DIR = "/opt/ml/checkpoints"
_CHECKPOINT_FILENAME = "ckpt-epoch-{epoch:04d}.weights.h5"
_EPOCH_PATTERN = re.compile(r"ckpt-epoch-(\d+)\.weights\.h5$")


def checkpoint_dir():
    """Return the SageMaker-managed checkpoint directory, creating it if needed."""
    path = os.environ.get("SM_CHECKPOINT_CONFIG_LOCAL_PATH", _DEFAULT_CHECKPOINT_DIR)
    os.makedirs(path, exist_ok=True)
    return path


def latest_checkpoint(ckpt_dir):
    """Return (filepath, epoch) of the highest-epoch checkpoint, or (None, 0)."""
    if not os.path.isdir(ckpt_dir):
        return None, 0

    best_epoch = 0
    best_file = None
    for name in os.listdir(ckpt_dir):
        match = _EPOCH_PATTERN.match(name)
        if match:
            epoch = int(match.group(1))
            if epoch > best_epoch:
                best_epoch = epoch
                best_file = os.path.join(ckpt_dir, name)
    return best_file, best_epoch


def resume_or_new(model):
    """Load weights from the latest checkpoint into `model` if present.

    Returns `initial_epoch` to pass to `model.fit`.
    """
    ckpt_dir = checkpoint_dir()
    latest, epoch = latest_checkpoint(ckpt_dir)
    if latest is None:
        logger.info("No existing checkpoint found, starting fresh")
        return 0

    logger.info(f"Resuming from checkpoint: {latest} (epoch {epoch})")
    model.load_weights(latest)
    return epoch


def checkpoint_callback():
    """Return a Keras ModelCheckpoint that saves one weights file per epoch.

    SageMaker auto-syncs the checkpoint directory to S3 so spot interruptions
    survive across restarts.
    """
    ckpt_dir = checkpoint_dir()
    return tf.keras.callbacks.ModelCheckpoint(
        filepath=os.path.join(ckpt_dir, _CHECKPOINT_FILENAME),
        save_weights_only=True,
        save_freq="epoch",
    )
