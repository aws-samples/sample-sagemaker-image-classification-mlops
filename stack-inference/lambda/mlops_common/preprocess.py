# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""The one image transform used for training, evaluation and serving.

Training sees images in two resizes: the preprocessing step stores every image
at STORAGE_SIZE with STORAGE_RESAMPLE, then the Keras loader resizes the stored
file to the model input with KERAS_INTERPOLATION. Evaluation and the inference
Lambda apply the same two resizes through ``preprocess()``, so a raw upload
reaches the network exactly as a training image did. Both resample filters are
explicit: Pillow's and Keras's defaults differ (bicubic versus nearest), which
is where the old train/serve skew came from.
"""

from __future__ import annotations

import numpy as np
from PIL import Image

from .constants import IMAGENET_MEAN, IMAGENET_STD

STORAGE_SIZE = 512
MODEL_INPUT_SIZE = 224

STORAGE_RESAMPLE = Image.Resampling.BICUBIC
MODEL_RESAMPLE = Image.Resampling.BILINEAR
# Keras load_img maps "bilinear" to PIL BILINEAR, the same filter as MODEL_RESAMPLE.
KERAS_INTERPOLATION = "bilinear"

_MEAN = np.asarray(IMAGENET_MEAN, dtype=np.float32)
_STD = np.asarray(IMAGENET_STD, dtype=np.float32)


def standardize(img: Image.Image, size: int = STORAGE_SIZE) -> Image.Image:
    """RGB, resized to size x size with STORAGE_RESAMPLE (the stored training image)."""
    return img.convert("RGB").resize((size, size), STORAGE_RESAMPLE)


def resize_for_model(img: Image.Image, input_size: int = MODEL_INPUT_SIZE) -> Image.Image:
    """RGB, resized to the model input with MODEL_RESAMPLE (what the Keras loader does)."""
    return img.convert("RGB").resize((input_size, input_size), MODEL_RESAMPLE)


def imagenet_normalize(image) -> np.ndarray:
    """Scale a 0-255 array to 0-1, then apply ImageNet mean/std per channel.

    Also the Keras ``preprocessing_function`` in training, which runs after
    augmentation, so it replaces ``rescale`` rather than adding to it.
    """
    arr = np.asarray(image, dtype=np.float32) / 255.0
    return (arr - _MEAN) / _STD


def to_model_input(img: Image.Image, input_size: int = MODEL_INPUT_SIZE) -> np.ndarray:
    """Stored image to a normalised float32 (input_size, input_size, 3) array."""
    return imagenet_normalize(resize_for_model(img, input_size))


def preprocess(
    img: Image.Image,
    storage_size: int = STORAGE_SIZE,
    input_size: int = MODEL_INPUT_SIZE,
) -> np.ndarray:
    """Raw image to model input, through the same two resizes training used."""
    return to_model_input(standardize(img, storage_size), input_size)
