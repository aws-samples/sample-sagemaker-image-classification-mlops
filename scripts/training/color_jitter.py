# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Colour and intensity jitter for training images.

When colour or brightness varies more between capture sessions (devices,
lighting, sites) than between classes, a model can learn the colour instead of
the content. Jittering each image's channels makes colour unreliable during
training. Each RGB channel is scaled by U(1 - sigma, 1 + sigma) and offset by
U(-sigma, sigma) of the full range, one draw per image; sigma is
``color_jitter_sigma`` in training_config.py. Evaluation and serving see the
unaltered image.
"""

from __future__ import annotations

import numpy as np


def color_jitter(rgb: np.ndarray, sigma: float, rng: np.random.Generator) -> np.ndarray:
    """Scale and offset each channel of a 0-255 (..., 3) image by a random amount."""
    scale = rng.uniform(1.0 - sigma, 1.0 + sigma, size=3)
    offset = rng.uniform(-sigma, sigma, size=3) * 255.0
    return np.clip(np.asarray(rgb, dtype=np.float64) * scale + offset, 0.0, 255.0)


def make_color_jitter(sigma: float, seed: int | None = None):
    """Return f(image) -> image for Keras ImageDataGenerator.preprocessing_function.

    The input is a 0-255 float (H, W, 3) array after the spatial augmentation;
    the output has the same shape and range. sigma 0 returns the image unchanged.
    """
    rng = np.random.default_rng(seed)

    def augment(image: np.ndarray) -> np.ndarray:
        out = np.asarray(image, dtype=np.float32)
        if sigma > 0:
            out = color_jitter(out, sigma, rng).astype(np.float32)
        return out

    return augment
