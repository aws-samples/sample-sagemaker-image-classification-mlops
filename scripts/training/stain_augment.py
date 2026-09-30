# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Stain (colour) augmentation for H&E histopathology, training only.

BreakHis slides were stained and scanned at different times, so stain
intensity varies more between patients than between classes. On the
patient-grouped split, a logistic regression on only the per-image mean and
spread of each colour channel reached AUC 0.98 on validation and 0.68 on
test (2026-09): colour is a shortcut that does not carry over to new patients. Jittering the stain per image makes
colour unreliable during training, so the network has to use tissue
structure instead.

The jitter works in HED space (haematoxylin, eosin, DAB; Ruifrok and
Johnston colour deconvolution): each stain channel is scaled by
U(1 - sigma, 1 + sigma) and shifted by U(-sigma, sigma), as in Tellez et
al. 2019, "Quantifying the effects of data augmentation and stain colour
normalization in convolutional neural networks for computational pathology";
sigma 0.2 is their "HED-strong" setting.

Evaluation and serving never call this: they see the unaltered image.
"""

from __future__ import annotations

import numpy as np

# Ruifrok and Johnston stain vectors (rows: haematoxylin, eosin, DAB), the
# matrix skimage.color.rgb2hed uses. Densities are plain optical density,
# -log(I / 255), the scale the Tellez et al. sigma values refer to.
_RGB_FROM_HED = np.array(
    [[0.65, 0.70, 0.29], [0.07, 0.99, 0.11], [0.27, 0.57, 0.78]], dtype=np.float64
)
_HED_FROM_RGB = np.linalg.inv(_RGB_FROM_HED)


def rgb_to_hed(rgb: np.ndarray) -> np.ndarray:
    """0-255 RGB (..., 3) to HED optical densities."""
    rgb = np.maximum(np.asarray(rgb, dtype=np.float64) / 255.0, 1e-6)
    return -np.log(rgb) @ _HED_FROM_RGB


def hed_to_rgb(hed: np.ndarray) -> np.ndarray:
    """HED optical densities to 0-255 RGB, clipped to the valid range."""
    rgb = np.exp(-(np.asarray(hed, dtype=np.float64) @ _RGB_FROM_HED))
    return np.clip(rgb, 0.0, 1.0) * 255.0


def hed_jitter(rgb: np.ndarray, sigma: float, rng: np.random.Generator) -> np.ndarray:
    """Scale and shift each stain channel by a random amount (one draw per image)."""
    hed = rgb_to_hed(rgb)
    alpha = rng.uniform(1.0 - sigma, 1.0 + sigma, size=3)
    beta = rng.uniform(-sigma, sigma, size=3)
    return hed_to_rgb(hed * alpha + beta)


def make_stain_augmenter(sigma: float, seed: int | None = None):
    """Return f(image) -> image for Keras ImageDataGenerator.preprocessing_function.

    The input is a 0-255 float (H, W, 3) array after the spatial augmentation;
    the output has the same shape and range. sigma 0 returns the image unchanged.
    """
    rng = np.random.default_rng(seed)

    def augment(image: np.ndarray) -> np.ndarray:
        out = np.asarray(image, dtype=np.float32)
        if sigma > 0:
            out = hed_jitter(out, sigma, rng).astype(np.float32)
        return out

    return augment
