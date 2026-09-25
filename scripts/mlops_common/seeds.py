# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Seed every random number generator a step uses."""

from __future__ import annotations

import os
import random

import numpy as np

from .constants import DEFAULT_SEED


def set_seeds(seed: int = DEFAULT_SEED) -> int:
    """Seed Python, NumPy and (when installed) TensorFlow; returns the seed.

    GPU kernels can still be non-deterministic; this makes splits, weight
    initialisation and augmentation order repeatable, not bit-exact.
    """
    os.environ["PYTHONHASHSEED"] = str(seed)
    random.seed(seed)
    np.random.seed(seed)
    try:
        import tensorflow as tf
    except ImportError:
        return seed
    tf.keras.utils.set_random_seed(seed)
    return seed
