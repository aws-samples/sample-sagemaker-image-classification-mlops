# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Load a class-per-directory split and score it with any model."""

from __future__ import annotations

import os
from collections.abc import Callable, Sequence

import numpy as np
from PIL import Image

from .constants import CLASS_DIRS, IMAGE_EXTENSIONS
from .preprocess import MODEL_INPUT_SIZE, to_model_input


def list_labeled_images(split_dir: str) -> list[tuple[str, int]]:
    """(path, label) for every image, ordered by class then filename.

    Same order and labels as Keras flow_from_directory(shuffle=False).
    """
    items: list[tuple[str, int]] = []
    for label, class_dir in enumerate(CLASS_DIRS):
        folder = os.path.join(split_dir, class_dir)
        if not os.path.isdir(folder):
            continue
        for name in sorted(os.listdir(folder)):
            if name.lower().endswith(IMAGE_EXTENSIONS):
                items.append((os.path.join(folder, name), label))
    return items


def load_batch(paths: Sequence[str], input_size: int = MODEL_INPUT_SIZE) -> np.ndarray:
    """Stored images to a normalised (N, input_size, input_size, 3) float32 batch."""
    arrays = []
    for path in paths:
        with Image.open(path) as img:
            arrays.append(to_model_input(img, input_size))
    return np.stack(arrays) if arrays else np.zeros((0, input_size, input_size, 3), np.float32)


def predict_scores(
    predict: Callable[[np.ndarray], np.ndarray],
    paths: Sequence[str],
    input_size: int = MODEL_INPUT_SIZE,
    batch_size: int = 32,
) -> np.ndarray:
    """Malignant probability per image, predicted in batches to bound memory."""
    scores = []
    for start in range(0, len(paths), batch_size):
        batch = load_batch(paths[start : start + batch_size], input_size)
        scores.append(np.asarray(predict(batch), dtype=float).reshape(-1))
    return np.concatenate(scores) if scores else np.zeros(0, dtype=float)
