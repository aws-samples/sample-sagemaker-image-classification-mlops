# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""The from-scratch CNN baseline: configured, packaged like the other trainers,
and kept out of the ensemble."""

import pytest
from conftest import ROOT, load_module

config = load_module("scripts/training/training_config.py", "training_config")


def test_baseline_has_a_config_but_is_not_an_ensemble_member():
    cfg = config.CONFIG["models"]["simple_cnn"]
    assert cfg["input_size"] == (224, 224)
    assert "simple_cnn" not in config.MODEL_NAMES
    tfvars = (ROOT / "stack-training" / "terraform.tfvars").read_text()
    assert "simple_cnn" not in tfvars


def test_baseline_tarball_is_built_like_the_other_trainers():
    uploader = (ROOT / "scripts" / "script_uploader.sh").read_text()
    loop = next(line for line in uploader.splitlines() if line.startswith("for trainer in"))
    for trainer in ("vgg16_trainer", "densenet121_trainer", "efficientnet_trainer"):
        assert trainer in loop
    assert "simple_cnn_trainer" in loop
    assert "training/simple_cnn_trainer.tar.gz" in uploader


def test_baseline_model_is_built_from_scratch(monkeypatch):
    tf = pytest.importorskip("tensorflow")
    monkeypatch.syspath_prepend(str(ROOT / "scripts" / "training"))
    trainer = load_module("scripts/training/simple_cnn_trainer.py", "simple_cnn_trainer")
    model, base = trainer.build_model(0.001)
    assert base is None
    assert model.output_shape == (None, 1)
    assert not any(isinstance(layer, tf.keras.Model) for layer in model.layers)
