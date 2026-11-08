# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import json
import os

import pytest
from conftest import CLASSES, load_module
from mlops_common import dataset_layout
from PIL import Image


def test_parse_filename():
    assert dataset_layout.parse_filename("g001__img_001.png") == {"group": "g001", "subgroup": None}
    assert dataset_layout.parse_filename("class_a/g001__site-a__img_001.png") == {
        "group": "g001",
        "subgroup": "site-a",
    }
    assert dataset_layout.parse_filename("img_0338.jpg") == {"group": None, "subgroup": None}
    assert dataset_layout.parse_filename("__img.jpg") == {"group": None, "subgroup": None}
    assert dataset_layout.group_key("img_0338.jpg") == "image:img_0338.jpg"


def test_manifest_overrides_the_file_name(tmp_path):
    (tmp_path / "manifest.csv").write_text(
        "file,label,group,subgroup,site\n"
        "class_a/g001__site-a__img_001.png,class_a,m7,day,north\n"
        "class_b/img_002.png,class_b,,,south\n"
    )
    manifest = dataset_layout.read_manifest(str(tmp_path))
    first = dataset_layout.describe_image("class_a/g001__site-a__img_001.png", manifest)
    assert first == {"group": "m7", "attributes": {"subgroup": "day", "site": "north"}}
    second = dataset_layout.describe_image("class_b/img_002.png", manifest)
    assert second == {"group": None, "attributes": {"site": "south"}}
    named = dataset_layout.describe_image("class_b/g002__night__img_003.png", manifest)
    assert named == {"group": "g002", "attributes": {"subgroup": "night"}}


def test_manifest_needs_its_columns(tmp_path):
    (tmp_path / "manifest.csv").write_text("file,group\nclass_a/x.png,g1\n")
    with pytest.raises(ValueError, match="label"):
        dataset_layout.read_manifest(str(tmp_path))


def test_subgroups_none_when_no_image_has_the_attribute():
    files = ["class_a/g001__img_001.png", "class_b/g002__img_002.png"]
    assert dataset_layout.subgroups(files, {}, "subgroup") is None
    files.append("class_b/g003__site-a__img_003.png")
    assert dataset_layout.subgroups(files, {}, "subgroup") == ["unknown", "unknown", "site-a"]


def test_discover_classes(tmp_path, monkeypatch):
    for name in ("dog", "cat"):
        (tmp_path / name).mkdir()
    (tmp_path / ".hidden").mkdir()
    monkeypatch.delenv("POSITIVE_CLASS", raising=False)
    assert dataset_layout.discover_classes(str(tmp_path)) == ("cat", "dog")
    monkeypatch.setenv("POSITIVE_CLASS", "cat")
    assert dataset_layout.discover_classes(str(tmp_path)) == ("dog", "cat")
    with pytest.raises(ValueError, match="positive class"):
        dataset_layout.discover_classes(str(tmp_path), positive_class="bird")
    (tmp_path / "bird").mkdir()
    with pytest.raises(ValueError, match="exactly 2"):
        dataset_layout.discover_classes(str(tmp_path))


def test_classes_file_round_trip(tmp_path):
    dataset_layout.write_classes(str(tmp_path), ("dog", "cat"))
    assert dataset_layout.load_classes(str(tmp_path)) == ("dog", "cat")
    assert json.loads((tmp_path / "classes.json").read_text())["positive_class"] == "cat"


def _items(image_name, groups_per_class=20, images_per_group=6):
    items = []
    for label, cls in enumerate(CLASSES):
        for g in range(groups_per_class):
            gid = g + (1000 if label else 0)
            for i in range(images_per_group):
                items.append((f"{cls}/{image_name(gid, i, ('a', 'b')[i % 2])}", label))
    return items


def test_no_group_in_two_splits(image_name):
    train, val, test = dataset_layout.grouped_split(_items(image_name))
    assert dataset_layout.groups_overlap(train, val, test) == []
    for split in (train, val, test):
        assert {label for _, label in split} == {0, 1}
    assert len(train) + len(val) + len(test) == 2 * 20 * 6


def test_split_is_deterministic(image_name):
    items = _items(image_name)
    assert dataset_layout.grouped_split(items, seed=7) == dataset_layout.grouped_split(
        list(reversed(items)), seed=7
    )


def test_manifest_groups_drive_the_split(image_name):
    items = [(f"class_a/img_{i:03d}.png", 0) for i in range(40)]
    items += [(f"class_b/img_{i:03d}.png", 1) for i in range(40)]
    groups = {f: f"m{int(f[-7:-4]) // 4}" for f, _ in items}
    train, val, test = dataset_layout.grouped_split(items, 0.15, 0.15, 7, groups)
    assert dataset_layout.groups_overlap(train, val, test, groups=groups) == []
    assert val and test


def test_groups_overlap_detects_leak(image_name):
    a = [(image_name(1, 1), 0)]
    b = [(image_name(1, 2), 0)]
    assert dataset_layout.groups_overlap(a, b) == ["g001"]


def test_preprocessor_writes_group_disjoint_splits(tmp_path, image_name):
    preprocessor = load_module("scripts/preprocessing/data_preprocessor.py", "data_preprocessor")
    raw = tmp_path / "raw"
    for label, cls in enumerate(CLASSES):
        (raw / cls).mkdir(parents=True)
        for g in range(12):
            for i in range(4):
                name = image_name(g + (500 if label else 0), i, "x" if i % 2 else "y")
                Image.new("RGB", (20, 14), (g * 10, i * 40, 90)).save(raw / cls / name)

    out = tmp_path / "out"
    assert preprocessor.preprocess_images(str(raw), str(out), target_size=16)

    seen = {}
    for split in ("train", "validation", "test"):
        assert dataset_layout.load_classes(str(out / split)) == CLASSES
        manifest = dataset_layout.read_manifest(str(out / split))
        for cls in CLASSES:
            files = os.listdir(out / split / cls)
            assert files, f"{split}/{cls} is empty"
            for f in files:
                with Image.open(out / split / cls / f) as img:
                    assert img.size == (16, 16)
                row = manifest[f"{cls}/{f}"]
                assert row["label"] == cls
                assert row["attributes"]["subgroup"] in ("x", "y")
                assert seen.setdefault(row["group"], split) == split, (
                    f"group {row['group']} in two splits"
                )
