# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""The Lambda must hand the model exactly what training fed it."""

import base64
import io

import numpy as np
import pytest
from conftest import load_module
from mlops_common import preprocess as pp
from mlops_common.datasets import load_batch
from PIL import Image

handler = load_module("stack-inference/lambda/inference_handler.py", "inference_handler_parity")


def _raw_tile(fmt: str) -> bytes:
    # BreakHis tiles are 700x460 RGB; a noisy gradient exercises the resampling.
    rng = np.random.default_rng(3)
    base = np.linspace(0, 255, 700, dtype=np.float32)[None, :, None]
    arr = np.clip(base + rng.normal(0, 25, (460, 700, 3)), 0, 255).astype(np.uint8)
    buf = io.BytesIO()
    Image.fromarray(arr).save(buf, format=fmt)
    return buf.getvalue()


def _training_view(raw: bytes, tmp_path) -> np.ndarray:
    """Preprocessing step stores a PNG; the Keras loader re-reads and resizes it.

    keras.utils.load_img(target_size, interpolation="bilinear") converts to RGB
    and calls PIL resize with BILINEAR; imagenet_normalize is the
    preprocessing_function. Reproduced here without TensorFlow.
    """
    stored = tmp_path / "stored.png"
    with Image.open(io.BytesIO(raw)) as img:
        pp.standardize(img).save(stored)
    assert pp.KERAS_INTERPOLATION == "bilinear"
    with Image.open(stored) as img:
        loaded = img.convert("RGB").resize(
            (pp.MODEL_INPUT_SIZE, pp.MODEL_INPUT_SIZE), Image.Resampling.BILINEAR
        )
    return pp.imagenet_normalize(np.asarray(loaded, dtype=np.float32))


@pytest.mark.parametrize("fmt", ["PNG", "JPEG"])
def test_lambda_matches_training_transform(tmp_path, fmt):
    raw = _raw_tile(fmt)
    _, img, _ = handler.decode_image(base64.b64encode(raw).decode())
    serving = pp.preprocess(img)
    training = _training_view(raw, tmp_path)
    assert serving.shape == (224, 224, 3)
    assert serving.dtype == np.float32
    np.testing.assert_allclose(serving, training, atol=1e-5)


def test_evaluation_loader_matches_training_transform(tmp_path):
    raw = _raw_tile("PNG")
    stored = tmp_path / "stored.png"
    with Image.open(io.BytesIO(raw)) as img:
        pp.standardize(img).save(stored)
    np.testing.assert_allclose(
        load_batch([str(stored)])[0], _training_view(raw, tmp_path), atol=1e-5
    )


def test_old_single_resize_path_differs():
    """The pre-fix Lambda (one default-filter resize to 224) was measurably off."""
    raw = _raw_tile("PNG")
    with Image.open(io.BytesIO(raw)) as img:
        old = pp.imagenet_normalize(np.asarray(img.convert("RGB").resize((224, 224))))
        new = pp.preprocess(img)
    assert np.abs(old - new).max() > 0.05


def test_normalisation_constants():
    white = pp.imagenet_normalize(np.full((1, 1, 3), 255.0))
    np.testing.assert_allclose(
        white[0, 0], (1 - np.array(pp.IMAGENET_MEAN)) / np.array(pp.IMAGENET_STD), rtol=1e-6
    )
