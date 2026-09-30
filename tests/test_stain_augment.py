# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import numpy as np
from conftest import ROOT, load_module

stain = load_module("scripts/training/stain_augment.py", "stain_augment")


def _tissue(seed=0):
    rng = np.random.default_rng(seed)
    return rng.uniform(40, 250, size=(32, 32, 3)).astype(np.float32)


def test_hed_round_trip_is_lossless():
    image = _tissue()
    np.testing.assert_allclose(stain.hed_to_rgb(stain.rgb_to_hed(image)), image, atol=1e-6)


def test_sigma_zero_returns_the_image():
    image = _tissue()
    np.testing.assert_array_equal(stain.make_stain_augmenter(0.0, seed=1)(image), image)


def test_jitter_changes_colour_and_keeps_shape_and_range():
    image = _tissue()
    out = stain.make_stain_augmenter(0.2, seed=1)(image)
    assert out.shape == image.shape
    assert out.dtype == np.float32
    assert out.min() >= 0.0 and out.max() <= 255.0
    assert np.abs(out - image).mean() > 1.0


def test_each_call_draws_a_new_jitter_and_seed_is_reproducible():
    image = _tissue()
    first = stain.make_stain_augmenter(0.2, seed=7)
    again = stain.make_stain_augmenter(0.2, seed=7)
    a, b = first(image), first(image)
    assert not np.allclose(a, b)
    np.testing.assert_array_equal(a, again(image))


def test_trainer_tarballs_ship_the_module():
    uploader = (ROOT / "scripts" / "script_uploader.sh").read_text()
    common_line = next(line for line in uploader.splitlines() if line.startswith("COMMON_MODULES="))
    assert "stain_augment.py" in common_line
