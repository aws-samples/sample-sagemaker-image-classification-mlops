# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Optional backbone weights: random initialisation unless BACKBONE_WEIGHTS_S3_URI is set."""

import pytest
from conftest import ROOT, load_module

weights = load_module("scripts/training/backbone_weights.py", "backbone_weights")


def test_empty_uri_means_random_init(monkeypatch, tmp_path):
    monkeypatch.setenv("BACKBONE_WEIGHTS_S3_URI", "")
    monkeypatch.setenv("SM_CHANNEL_WEIGHTS", str(tmp_path))
    (tmp_path / "vgg16.weights.h5").write_bytes(b"x")
    assert weights.resolve_weights_path("vgg16") is None
    monkeypatch.delenv("BACKBONE_WEIGHTS_S3_URI")
    assert weights.resolve_weights_path("vgg16") is None


def test_named_file_wins_then_the_only_file(monkeypatch, tmp_path):
    monkeypatch.setenv("BACKBONE_WEIGHTS_S3_URI", "s3://bucket/weights/")
    monkeypatch.setenv("SM_CHANNEL_WEIGHTS", str(tmp_path))
    (tmp_path / "other.weights.h5").write_bytes(b"x")
    assert weights.resolve_weights_path("vgg16") == str(tmp_path / "other.weights.h5")
    (tmp_path / "vgg16.weights.h5").write_bytes(b"x")
    assert weights.resolve_weights_path("vgg16") == str(tmp_path / "vgg16.weights.h5")


def test_set_uri_without_a_usable_channel_fails(monkeypatch, tmp_path):
    monkeypatch.setenv("BACKBONE_WEIGHTS_S3_URI", "s3://bucket/weights/")
    monkeypatch.delenv("SM_CHANNEL_WEIGHTS", raising=False)
    with pytest.raises(RuntimeError, match="channel is missing"):
        weights.resolve_weights_path("vgg16")
    monkeypatch.setenv("SM_CHANNEL_WEIGHTS", str(tmp_path))
    (tmp_path / "a.h5").write_bytes(b"x")
    (tmp_path / "b.h5").write_bytes(b"x")
    with pytest.raises(RuntimeError, match=r"none is vgg16\.weights\.h5"):
        weights.resolve_weights_path("vgg16")


def test_trainer_tarballs_ship_the_module():
    uploader = (ROOT / "scripts" / "script_uploader.sh").read_text()
    common_line = next(line for line in uploader.splitlines() if line.startswith("COMMON_MODULES="))
    assert "backbone_weights.py" in common_line
