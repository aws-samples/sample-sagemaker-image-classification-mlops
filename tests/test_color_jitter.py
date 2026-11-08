# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import numpy as np
from conftest import ROOT, load_module

jitter = load_module("scripts/training/color_jitter.py", "color_jitter")


def _image(seed=0):
    rng = np.random.default_rng(seed)
    return rng.uniform(40, 250, size=(32, 32, 3)).astype(np.float32)


def test_sigma_zero_returns_the_image():
    image = _image()
    np.testing.assert_array_equal(jitter.make_color_jitter(0.0, seed=1)(image), image)


def test_jitter_changes_colour_and_keeps_shape_and_range():
    image = _image()
    out = jitter.make_color_jitter(0.2, seed=1)(image)
    assert out.shape == image.shape
    assert out.dtype == np.float32
    assert out.min() >= 0.0 and out.max() <= 255.0
    assert np.abs(out - image).mean() > 1.0


def test_each_call_draws_a_new_jitter_and_seed_is_reproducible():
    image = _image()
    first = jitter.make_color_jitter(0.2, seed=7)
    again = jitter.make_color_jitter(0.2, seed=7)
    a, b = first(image), first(image)
    assert not np.allclose(a, b)
    np.testing.assert_array_equal(a, again(image))


def test_trainer_tarballs_ship_the_module():
    uploader = (ROOT / "scripts" / "script_uploader.sh").read_text()
    common_line = next(line for line in uploader.splitlines() if line.startswith("COMMON_MODULES="))
    assert "color_jitter.py" in common_line
