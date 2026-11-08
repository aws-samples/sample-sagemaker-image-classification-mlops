#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Validation step: class folders, image quality, duplicates, balance and the image inventory."""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from pathlib import Path

import numpy as np
from PIL import Image

# The step's code directory holds mlops_common next to this file; a local
# checkout has it one level up, in scripts/.
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from mlops_common.dataset_layout import (
    MANIFEST_FILE,
    describe_image,
    discover_classes,
    list_images,
    read_manifest,
)

# OpenCV powers the blur/contrast/edge-density quality check. It's an optional
# dependency - guard the import so the validator still runs (skipping quality
# filtering with a warning) in environments where it isn't installed.
try:
    import cv2

    _CV2_AVAILABLE = True
    _CV2_ERRORS: tuple[type[Exception], ...] = (cv2.error,)
except ImportError:
    cv2 = None
    _CV2_AVAILABLE = False
    _CV2_ERRORS = ()

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger(__name__)

# Image-quality thresholds - module-level so operators can tune them. An image
# passes only when it clears all three: sharp enough (Laplacian variance),
# enough tonal range (contrast), and enough structure (edge density).
LAPLACIAN_MIN = 50
CONTRAST_MIN = 15
EDGE_DENSITY_MIN = 0.01

# Written next to validation_report.json; the preprocessing step reads both.
EXCLUSION_MANIFEST = "exclusion_manifest.json"
IMAGE_INVENTORY = "image_inventory.json"


def assess_image_quality(image: np.ndarray) -> bool:
    """Return True if an RGB image array clears all quality thresholds.

    Combines three signals on the grayscale image:
      - Laplacian variance  -> blur (low variance == out of focus)
      - standard deviation   -> contrast (low std == washed out)
      - Canny edge density   -> structure (few edges == blank / featureless)
    """
    gray = cv2.cvtColor(image, cv2.COLOR_RGB2GRAY)
    laplacian_var = cv2.Laplacian(gray, cv2.CV_64F).var()
    contrast = np.std(gray)
    edges = cv2.Canny(gray, 50, 150)
    edge_density = np.count_nonzero(edges) / edges.size
    return (
        laplacian_var > LAPLACIAN_MIN
        and contrast > CONTRAST_MIN
        and edge_density > EDGE_DENSITY_MIN
    )


def image_quality_metrics(image: np.ndarray) -> dict[str, float]:
    """The three values assess_image_quality checks, for the exclusion manifest.

    This repeats assess_image_quality's computation so that function stays a
    self-contained example of the three checks. Keep the two in step;
    tests/test_validation_exclusions.py checks that they agree.
    """
    gray = cv2.cvtColor(image, cv2.COLOR_RGB2GRAY)
    laplacian_var = cv2.Laplacian(gray, cv2.CV_64F).var()
    contrast = np.std(gray)
    edges = cv2.Canny(gray, 50, 150)
    edge_density = np.count_nonzero(edges) / edges.size
    return {
        "laplacian_variance": float(laplacian_var),
        "contrast": float(contrast),
        "edge_density": float(edge_density),
    }


def _get_int_env(name: str, default: int) -> int:
    return int(os.environ.get(name, str(default)))


def _get_float_env(name: str, default: float) -> float:
    return float(os.environ.get(name, str(default)))


def _get_bool_env(name: str, default: bool) -> bool:
    return os.environ.get(name, str(default).lower()).lower() == "true"


def _phash(image_path: Path) -> str:
    """Compute an 8x8 perceptual hash of an image.

    Small enough to be cheap, robust enough to flag near-duplicates (same
    scene at slightly different resolution / JPEG quality).
    """
    with Image.open(image_path) as img:
        # Resize to 9x8 for horizontal-gradient hash, convert to grayscale.
        small = img.convert("L").resize((9, 8), Image.Resampling.LANCZOS)
        pixels = list(small.getdata())

    # Horizontal-gradient hash: for each row, compare adjacent pixels.
    bits = 0
    for row in range(8):
        for col in range(8):
            left = pixels[row * 9 + col]
            right = pixels[row * 9 + col + 1]
            if left > right:
                bits |= 1 << (row * 8 + col)

    return f"{bits:016x}"


def _scan_class(
    class_dir: Path,
    label: int,
    errors: list[str],
    warnings: list[str],
    excluded: list[dict[str, object]],
    inventory: list[dict[str, object]],
) -> dict[str, object]:
    """Scan one class directory; return per-class aggregate stats.

    Every readable image is added to ``inventory``; every image kept out of
    training is added to ``excluded`` with its reason.
    """
    min_resolution = _get_int_env("MIN_RESOLUTION", 112)
    warn_resolution = _get_int_env("WARN_RESOLUTION", 224)
    enable_dupe = _get_bool_env("ENABLE_DUPLICATE_CHECK", True)
    enable_quality = _get_bool_env("ENABLE_QUALITY_CHECK", True) and _CV2_AVAILABLE

    count = 0
    modes: dict[str, int] = {}
    too_small_count = 0
    warn_resolution_count = 0
    low_quality_count = 0
    phashes: list[tuple[Path, str]] = []

    def exclude(f: Path, reason: str, detail: object) -> None:
        excluded.append(
            {
                "file": f"{class_dir.name}/{f.name}",
                "label": label,
                "reason": reason,
                "detail": detail,
            }
        )

    for name in list_images(str(class_dir)):
        f = class_dir / name
        try:
            with Image.open(f) as img:
                # verify() detects file-level corruption without decoding, and
                # closes the handle, hence the second open.
                img.verify()
            with Image.open(f) as img:
                mode = img.mode
                w, h = img.size
        except (OSError, SyntaxError, ValueError, Image.DecompressionBombError) as e:
            errors.append(f"Invalid image {f.name}: {e}")
            exclude(f, "unreadable", str(e))
            continue

        count += 1
        modes[mode] = modes.get(mode, 0) + 1
        inventory.append({"file": f"{class_dir.name}/{f.name}", "label": label})

        if min(w, h) < min_resolution:
            errors.append(f"{f.name}: resolution {w}x{h} below hard minimum {min_resolution}px")
            exclude(f, "below_min_resolution", {"width": w, "height": h, "minimum": min_resolution})
            too_small_count += 1
        elif min(w, h) < warn_resolution:
            warn_resolution_count += 1

        # An image that fails the quality check is excluded from training and
        # listed with its metrics in the exclusion manifest; nothing is dropped
        # silently.
        if enable_quality:
            try:
                with Image.open(f) as img:
                    arr = np.asarray(img.convert("RGB"))
                if not assess_image_quality(arr):
                    warnings.append(
                        f"{f.name}: failed quality check "
                        f"(blur/contrast/edge-density below thresholds), excluded from training"
                    )
                    exclude(f, "quality_check_failed", image_quality_metrics(arr))
                    low_quality_count += 1
            except (OSError, ValueError, *_CV2_ERRORS) as e:
                warnings.append(f"quality check failed for {f.name}: {e}, excluded from training")
                exclude(f, "quality_check_error", str(e))
                low_quality_count += 1

        if enable_dupe:
            try:
                phashes.append((f, _phash(f)))
            except (OSError, ValueError) as e:
                warnings.append(f"phash failed for {f.name}: {e}")

    return {
        "count": count,
        "modes": modes,
        "too_small": too_small_count,
        "warn_resolution": warn_resolution_count,
        "low_quality": low_quality_count,
        "phashes": phashes,
    }


def _find_duplicates(phashes: list[tuple[Path, str]]) -> list[tuple[str, str]]:
    """(file_a, file_b) pairs whose perceptual hashes match exactly.

    Exact matching is O(n) and catches the common case, the same image
    uploaded under another name.
    """
    seen: dict[str, Path] = {}
    dupes: list[tuple[str, str]] = []
    for path, hash_value in phashes:
        if hash_value in seen:
            dupes.append((str(seen[hash_value].name), str(path.name)))
        else:
            seen[hash_value] = path
    return dupes


def _attach_groups(
    inventory: list[dict[str, object]],
    manifest: dict[str, dict],
    errors: list[str],
    warnings: list[str],
) -> None:
    """Add each image's group id and attributes; check the manifest against the folders."""
    listed = {str(item["file"]) for item in inventory}
    for file, row in sorted(manifest.items()):
        folder = file.split("/", 1)[0]
        if file not in listed:
            warnings.append(f"{MANIFEST_FILE}: {file} is not a readable image in a class folder")
        elif row["label"] != folder:
            errors.append(
                f"{MANIFEST_FILE}: {file} has label {row['label']!r} but sits in {folder!r} "
                f"(labels come from the class folder)"
            )
    for item in inventory:
        item.update(describe_image(str(item["file"]), manifest))


def _write_failure(out: Path, results: dict) -> bool:
    results["status"] = "failed"
    for e in results["errors"]:
        logger.error("Validation error: %s", e)
    (out / "validation_report.json").write_text(json.dumps(results, indent=2, default=str))
    return False


def validate_dataset(input_path: str, output_path: str) -> bool:
    """Run all configured checks, write a JSON report, return overall pass/fail."""
    if not input_path or not output_path:
        logger.error("Input path and output path are required")
        return False

    base = Path(input_path)
    if not base.exists():
        logger.error(f"Input path does not exist: {input_path}")
        return False

    out = Path(output_path)
    out.mkdir(parents=True, exist_ok=True)

    if not _CV2_AVAILABLE:
        logger.warning("OpenCV (cv2) not installed - skipping image-quality filtering")

    errors: list[str] = []
    warnings: list[str] = []
    excluded: list[dict[str, object]] = []
    inventory: list[dict[str, object]] = []
    results: dict = {"status": "success", "errors": errors, "warnings": warnings}

    try:
        class_names = discover_classes(input_path)
        manifest = read_manifest(input_path)
    except ValueError as exc:
        errors.append(str(exc))
        return _write_failure(out, results)
    negative, positive = class_names
    results["class_names"] = list(class_names)
    results["positive_class"] = positive
    results["manifest_rows"] = len(manifest)

    stats = {
        name: _scan_class(base / name, label, errors, warnings, excluded, inventory)
        for label, name in enumerate(class_names)
    }
    _attach_groups(inventory, manifest, errors, warnings)

    # The counts that reach training: readable images minus excluded ones.
    excluded_files = {e["file"] for e in excluded}
    usable = {
        name: sum(1 for i in inventory if i["label"] == label and i["file"] not in excluded_files)
        for label, name in enumerate(class_names)
    }
    results["classes"] = {
        name: {
            "label": label,
            "count": stats[name]["count"],
            "usable": usable[name],
            "modes": stats[name]["modes"],
            "too_small": stats[name]["too_small"],
            "warn_resolution": stats[name]["warn_resolution"],
            "low_quality": stats[name]["low_quality"],
        }
        for label, name in enumerate(class_names)
    }
    results["quality_check_enabled"] = (
        _get_bool_env("ENABLE_QUALITY_CHECK", True) and _CV2_AVAILABLE
    )
    results["excluded_count"] = len(excluded)
    results["grouped_images"] = sum(1 for i in inventory if i["group"])

    # Minimum-count gate, on the images that reach training.
    min_per_class = _get_int_env("MIN_IMAGES_PER_CLASS", 100)
    for name in class_names:
        if usable[name] < min_per_class:
            errors.append(f"Too few usable {name}: {usable[name]} (minimum: {min_per_class})")

    # Color-mode consistency. Only fail hard when a class mixes RGB with
    # non-RGB - trainers normalise RGB specifically.
    if _get_bool_env("ENABLE_MODE_CHECK", True):
        for name in class_names:
            modes = stats[name]["modes"]
            if len(modes) > 1:
                non_rgb = {m for m in modes if m not in ("RGB", "RGBA")}
                if non_rgb:
                    errors.append(
                        f"{name}: mixed color modes {modes} - training "
                        f"will silently convert grayscale, distorting stats"
                    )
                else:
                    warnings.append(
                        f"{name}: mixed RGB/RGBA modes {modes} - RGBA "
                        f"alpha will be dropped during preprocessing"
                    )

    # Duplicate detection.
    if _get_bool_env("ENABLE_DUPLICATE_CHECK", True):
        for name in class_names:
            dupes = _find_duplicates(stats[name]["phashes"])
            if dupes:
                warnings.append(
                    f"{name}: {len(dupes)} duplicate image pair(s) - first few: {dupes[:3]}"
                )

    # Class-balance gate. Minority / majority < threshold is a hard fail
    # because the ensemble weights are accuracy-proportional and heavy
    # imbalance drives accuracy up while masking poor minority-class recall.
    min_balance = _get_float_env("MIN_CLASS_BALANCE_RATIO", 0.3)
    total_counts = [usable[name] for name in class_names]
    if min(total_counts) > 0:
        ratio = min(total_counts) / max(total_counts)
        results["class_balance_ratio"] = round(ratio, 3)
        if ratio < min_balance:
            errors.append(
                f"Class imbalance: minority/majority = {ratio:.2f} "
                f"(minimum: {min_balance}). Rebalance the "
                f"dataset or set MIN_CLASS_BALANCE_RATIO lower if this is "
                f"intentional."
            )

    if errors:
        results["status"] = "failed"

    logger.info(
        "Validation: %d %s, %d %s (positive), %d errors, %d warnings",
        stats[negative]["count"],
        negative,
        stats[positive]["count"],
        positive,
        len(errors),
        len(warnings),
    )
    # Log each error/warning so failures are diagnosable from the job log.
    for e in errors:
        logger.error("Validation error: %s", e)
    for w in warnings:
        logger.warning("Validation warning: %s", w)

    # CloudWatch-friendly JSON log lines.
    for name, value in [
        ("DataValidation_NegativeCount", stats[negative]["count"]),
        ("DataValidation_PositiveCount", stats[positive]["count"]),
        ("DataValidation_TotalImages", len(inventory)),
        ("DataValidation_ErrorCount", len(errors)),
        ("DataValidation_WarningCount", len(warnings)),
        ("DataValidation_LowQualityCount", sum(st["low_quality"] for st in stats.values())),
        ("DataValidation_ExcludedCount", len(excluded)),
    ]:
        logger.info(json.dumps({"metric_name": name, "metric_value": value}))

    for item in excluded:
        logger.warning("Excluded from training: %s (%s)", item["file"], item["reason"])

    # The preprocessing step skips every image in the exclusion manifest and
    # computes the group split from the inventory, so all of its instances
    # agree on the split.
    (out / EXCLUSION_MANIFEST).write_text(
        json.dumps({"count": len(excluded), "excluded": excluded}, indent=2, default=str)
    )
    (out / IMAGE_INVENTORY).write_text(
        json.dumps(
            {"count": len(inventory), "class_names": list(class_names), "images": inventory},
            indent=2,
        )
    )
    (out / "validation_report.json").write_text(json.dumps(results, indent=2, default=str))
    return results["status"] == "success"


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate an image classification dataset")
    parser.add_argument("--input-path", required=True)
    parser.add_argument("--output-path", required=True)
    args = parser.parse_args()

    ok = validate_dataset(args.input_path, args.output_path)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
