# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""The validation step's exclusion manifest and the sharded preprocessing split."""

import json
import os

import numpy as np
import pytest
from conftest import CLASSES, load_module
from mlops_common import dataset_layout
from PIL import Image

validator = load_module("scripts/validation/data_validator.py", "data_validator")
preprocessor = load_module("scripts/preprocessing/data_preprocessor.py", "data_preprocessor")


@pytest.fixture
def raw(tmp_path, image_name, monkeypatch):
    """16 groups per class, 4 images each; small images are fine for these checks."""
    monkeypatch.setenv("MIN_IMAGES_PER_CLASS", "1")
    monkeypatch.setenv("MIN_RESOLUTION", "1")
    monkeypatch.setenv("WARN_RESOLUTION", "1")
    monkeypatch.setenv("ENABLE_DUPLICATE_CHECK", "false")
    root = tmp_path / "raw"
    for label, cls in enumerate(CLASSES):
        (root / cls).mkdir(parents=True)
        for g in range(16):
            for i in range(4):
                name = image_name(g + (500 if label else 0), i)
                Image.new("RGB", (20, 14), (g * 10, i * 40, 90)).save(root / cls / name)
    return root


class Cv2Stub:
    """The three OpenCV calls of the quality check, each one logged.

    OpenCV is not a test dependency. Images 0 and 1 of groups 3 and 503 (keyed
    on the colour the raw fixture gave them) come out blank: no Laplacian
    variance, contrast or edges. Every other image comes out as a checkerboard,
    which clears all three thresholds. The real check and metrics code run.
    """

    COLOR_RGB2GRAY = "COLOR_RGB2GRAY"
    CV_64F = "CV_64F"

    def __init__(self):
        self.calls = []

    def cvtColor(self, image, code):
        self.calls.append(("cvtColor", code))
        r, g, _ = (int(v) for v in image[0, 0])
        if r == 30 and g in (0, 40):
            return np.zeros(image.shape[:2])
        return np.indices(image.shape[:2]).sum(axis=0) % 2 * 255.0

    def Laplacian(self, gray, depth):
        self.calls.append(("Laplacian", depth))
        return gray

    def Canny(self, gray, low, high):
        self.calls.append(("Canny", low, high))
        return gray


@pytest.fixture
def cv2_stub(monkeypatch):
    stub = Cv2Stub()
    monkeypatch.setattr(validator, "cv2", stub)
    return stub


@pytest.fixture
def blurry(monkeypatch, image_name, cv2_stub):
    """Quality check on; images 0 and 1 of groups 3 and 503 fail it (see Cv2Stub)."""
    monkeypatch.setenv("ENABLE_QUALITY_CHECK", "true")
    monkeypatch.setattr(validator, "_CV2_AVAILABLE", True)
    return {image_name(gid, seq) for gid in (3, 503) for seq in (0, 1)}


def _split_files(out):
    found = {}
    for split in ("train", "validation", "test"):
        for cls in CLASSES:
            for name in os.listdir(out / split / cls):
                found[name] = split
    return found


def test_quality_failures_are_excluded_listed_and_counted(tmp_path, raw, blurry):
    report = tmp_path / "report"
    assert validator.validate_dataset(str(raw), str(report))

    manifest = json.loads((report / validator.EXCLUSION_MANIFEST).read_text())
    inventory = json.loads((report / validator.IMAGE_INVENTORY).read_text())
    results = json.loads((report / "validation_report.json").read_text())

    assert manifest["count"] == len(manifest["excluded"]) == 4
    assert {os.path.basename(e["file"]) for e in manifest["excluded"]} == blurry
    for entry in manifest["excluded"]:
        assert entry["reason"] == "quality_check_failed"
        assert entry["detail"] == {"laplacian_variance": 0.0, "contrast": 0.0, "edge_density": 0.0}
    assert inventory["count"] == 128
    assert results["excluded_count"] == 4
    assert results["class_names"] == list(CLASSES)
    assert [results["classes"][c]["usable"] for c in CLASSES] == [62, 62]
    assert {i["group"] for i in inventory["images"]} >= {"g003", "g503"}
    assert sum("excluded from training" in w for w in results["warnings"]) == 4


@pytest.mark.parametrize(("colour", "passes"), [((30, 0, 90), False), ((30, 80, 90), True)])
def test_manifest_values_repeat_the_quality_check(cv2_stub, colour, passes):
    """image_quality_metrics makes the same OpenCV calls as assess_image_quality,
    and its values give the same verdict at the thresholds."""
    image = np.full((14, 20, 3), colour, np.uint8)
    assert validator.assess_image_quality(image) == passes
    check_calls = cv2_stub.calls.copy()
    cv2_stub.calls.clear()

    m = validator.image_quality_metrics(image)
    assert cv2_stub.calls == check_calls
    assert passes == (
        m["laplacian_variance"] > validator.LAPLACIAN_MIN
        and m["contrast"] > validator.CONTRAST_MIN
        and m["edge_density"] > validator.EDGE_DENSITY_MIN
    )


def test_preprocessing_skips_every_excluded_image(tmp_path, raw, blurry):
    report = tmp_path / "report"
    assert validator.validate_dataset(str(raw), str(report))
    out = tmp_path / "out"
    assert preprocessor.preprocess_images(
        str(raw), str(out), target_size=16, validation_report_path=str(report)
    )
    written = _split_files(out)
    assert len(written) == 128 - 4
    assert not blurry & set(written)
    summary = json.loads((out / "preprocessing_summary.json").read_text())
    assert summary["excluded_by_validation"] == 4


def _shard(raw, tmp_path, n_shards):
    """Spread the raw files over n shard directories by sorted key, the way a
    contiguous ShardedByS3Key split can (one shard may hold only one class)."""
    keys = sorted(f"{cls}/{name}" for cls in CLASSES for name in os.listdir(raw / cls))
    shards = []
    per = -(-len(keys) // n_shards)
    for k in range(n_shards):
        shard = tmp_path / f"shard{k}"
        # Like a SageMaker input channel, a share has a class folder only when
        # it holds an image of that class.
        for key in keys[k * per : (k + 1) * per]:
            (shard / key).parent.mkdir(parents=True, exist_ok=True)
            os.link(raw / key, shard / key)
        shards.append(shard)
    return shards


@pytest.mark.parametrize("n_shards", [2, 3])
def test_sharded_preprocessing_matches_one_instance(tmp_path, raw, blurry, monkeypatch, n_shards):
    report = tmp_path / "report"
    assert validator.validate_dataset(str(raw), str(report))

    single = tmp_path / "single"
    monkeypatch.setattr(preprocessor, "cluster_hosts", lambda: ("algo-1", ["algo-1"]))
    assert preprocessor.preprocess_images(str(raw), str(single), 16, str(report))
    expected = _split_files(single)

    hosts = [f"algo-{k + 1}" for k in range(n_shards)]
    combined = {}
    for k, shard in enumerate(_shard(raw, tmp_path, n_shards)):
        out = tmp_path / f"out{k}"
        monkeypatch.setattr(preprocessor, "cluster_hosts", lambda k=k: (hosts[k], hosts))
        assert preprocessor.preprocess_images(str(shard), str(out), 16, str(report))
        for name, split in _split_files(out).items():
            assert name not in combined, f"{name} written by two instances"
            combined[name] = split

    # The union of the shards' uploads is exactly the one-instance split.
    assert combined == expected
    by_group = {}
    for name, split in combined.items():
        group = dataset_layout.parse_filename(name)["group"]
        assert by_group.setdefault(group, split) == split


def test_several_instances_need_the_inventory(tmp_path, raw, monkeypatch):
    monkeypatch.setattr(preprocessor, "cluster_hosts", lambda: ("algo-1", ["algo-1", "algo-2"]))
    assert not preprocessor.preprocess_images(str(raw), str(tmp_path / "out"), 16, None)


def test_files_missing_from_the_inventory_are_skipped_and_listed(tmp_path, raw, image_name):
    report = tmp_path / "report"
    assert validator.validate_dataset(str(raw), str(report))
    late = image_name(900, 0)
    Image.new("RGB", (20, 14), (1, 2, 3)).save(raw / "class_a" / late)
    out = tmp_path / "out"
    assert preprocessor.preprocess_images(str(raw), str(out), 16, str(report))
    assert late not in _split_files(out)
    summary = json.loads((out / "preprocessing_summary.json").read_text())
    assert summary["not_validated"] == [f"class_a/{late}"]


def test_manifest_label_must_match_the_folder(tmp_path, raw):
    first = sorted(os.listdir(raw / "class_a"))[0]
    (raw / "manifest.csv").write_text(f"file,label,group\nclass_a/{first},class_b,m1\n")
    report = tmp_path / "report"
    assert not validator.validate_dataset(str(raw), str(report))
    results = json.loads((report / "validation_report.json").read_text())
    assert any("labels come from the class folder" in e for e in results["errors"])


def test_validation_needs_two_class_folders(tmp_path, raw):
    (raw / "class_c").mkdir()
    report = tmp_path / "report"
    assert not validator.validate_dataset(str(raw), str(report))
    results = json.loads((report / "validation_report.json").read_text())
    assert any("exactly 2 class folders" in e for e in results["errors"])
