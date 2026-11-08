# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Load a class-per-directory split and score it with any model."""

from __future__ import annotations

import os
from collections.abc import Callable, Sequence

import numpy as np
from PIL import Image

from .dataset_layout import list_images, load_classes
from .preprocess import MODEL_INPUT_SIZE, to_model_input


def list_labeled_images(split_dir: str) -> list[tuple[str, int]]:
    """(path, label) for every image, ordered by label then filename.

    Same order and labels as Keras flow_from_directory(shuffle=False) with
    ``classes`` set to the split's class names.
    """
    items: list[tuple[str, int]] = []
    for label, class_dir in enumerate(load_classes(split_dir)):
        folder = os.path.join(split_dir, class_dir)
        items.extend((os.path.join(folder, name), label) for name in list_images(folder))
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
    """Positive-class probability per image, predicted in batches to bound memory."""
    scores = []
    for start in range(0, len(paths), batch_size):
        batch = load_batch(paths[start : start + batch_size], input_size)
        scores.append(np.asarray(predict(batch), dtype=float).reshape(-1))
    return np.concatenate(scores) if scores else np.zeros(0, dtype=float)
