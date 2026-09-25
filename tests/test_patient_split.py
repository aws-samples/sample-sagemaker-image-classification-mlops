# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import os

from conftest import load_module
from mlops_common import breakhis
from PIL import Image


def test_parse_breakhis_filename():
    name = "breakhis_SOB_B_A-14-22549AB-40-001.png"
    assert breakhis.patient_id(name) == "14-22549AB"
    assert breakhis.magnification(name) == "40X"
    assert breakhis.patient_id("SOB_M_DC-14-2523-400-012.png") == "14-2523"
    assert breakhis.patient_id("breast_benign_0338.jpg") is None
    assert breakhis.group_key("breast_benign_0338.jpg") == "image:breast_benign_0338.jpg"


def _items(breakhis_name, patients_per_class=20, images_per_patient=6):
    items = []
    for label, cls in ((0, "B"), (1, "M")):
        for p in range(patients_per_class):
            pid = p + (1000 if cls == "M" else 0)
            for i in range(images_per_patient):
                mag = (40, 100, 200, 400)[i % 4]
                items.append((breakhis_name(cls, pid, mag, i), label))
    return items


def test_no_patient_in_two_splits(breakhis_name):
    train, val, test = breakhis.patient_grouped_split(_items(breakhis_name))
    assert breakhis.groups_overlap(train, val, test) == []
    for split in (train, val, test):
        assert {label for _, label in split} == {0, 1}
    assert len(train) + len(val) + len(test) == 2 * 20 * 6


def test_split_is_deterministic(breakhis_name):
    items = _items(breakhis_name)
    assert breakhis.patient_grouped_split(items, seed=7) == breakhis.patient_grouped_split(
        list(reversed(items)), seed=7
    )


def test_groups_overlap_detects_leak(breakhis_name):
    a = [(breakhis_name("B", 1, 40, 1), 0)]
    b = [(breakhis_name("B", 1, 100, 2), 0)]
    assert breakhis.groups_overlap(a, b) == ["14-00001AB"]


def test_preprocessor_writes_patient_disjoint_splits(tmp_path, breakhis_name, monkeypatch):
    monkeypatch.delenv("PROCESSED_DATA_BUCKET", raising=False)
    preprocessor = load_module("scripts/preprocessing/data_preprocessor.py", "data_preprocessor")
    raw = tmp_path / "raw"
    for label_dir, cls in (("breast_benign", "B"), ("breast_malignant", "M")):
        (raw / label_dir).mkdir(parents=True)
        for p in range(12):
            for i in range(4):
                name = breakhis_name(cls, p + (500 if cls == "M" else 0), 40, i)
                Image.new("RGB", (20, 14), (p * 10, i * 40, 90)).save(raw / label_dir / name)

    out = tmp_path / "out"
    assert preprocessor.preprocess_images(str(raw), str(out), target_size=16)

    seen = {}
    for split in ("train", "validation", "test"):
        for label_dir in ("breast_benign", "breast_malignant"):
            files = os.listdir(out / split / label_dir)
            assert files, f"{split}/{label_dir} is empty"
            for f in files:
                with Image.open(out / split / label_dir / f) as img:
                    assert img.size == (16, 16)
                pid = breakhis.patient_id(f)
                assert seen.setdefault(pid, split) == split, f"patient {pid} in two splits"
