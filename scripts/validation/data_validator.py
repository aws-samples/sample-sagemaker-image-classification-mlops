#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from pathlib import Path

import numpy as np
from PIL import Image

# OpenCV powers the blur/contrast/edge-density quality check. It's an optional
# dependency - guard the import so the validator still runs (skipping quality
# filtering with a warning) in environments where it isn't installed.
try:
    import cv2

    _CV2_AVAILABLE = True
except ImportError:
    cv2 = None
    _CV2_AVAILABLE = False

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger(__name__)

# Image-quality thresholds - module-level so operators can tune them. An image
# passes only when it clears all three: sharp enough (Laplacian variance),
# enough tonal range (contrast), and enough structure (edge density).
LAPLACIAN_MIN = 50
CONTRAST_MIN = 15
EDGE_DENSITY_MIN = 0.01

# Thresholds - configurable via env so operators can tune per-dataset
# without touching code. Values picked to match the production training
# preprocessor (resizes to 224×224).
#
# These are read at call-time inside validate_dataset() so tests (and
# operators) can override them per-run without reimporting the module.


def _get_int_env(name: str, default: int) -> int:
    return int(os.environ.get(name, str(default)))


def _get_float_env(name: str, default: float) -> float:
    return float(os.environ.get(name, str(default)))


def _get_bool_env(name: str, default: bool) -> bool:
    return os.environ.get(name, str(default).lower()).lower() == "true"


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


def _scan_class(class_dir: Path, errors: list[str], warnings: list[str]) -> dict[str, object]:
    """Scan one class directory; return per-class aggregate stats.

    Stats include count, mode histogram (RGB / L / RGBA / etc.), resolution
    histogram buckets, and phash list (for later dedup).
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

    for f in class_dir.iterdir():
        if f.suffix.lower() not in {".jpg", ".jpeg", ".png"}:
            continue
        try:
            with Image.open(f) as img:
                # Verify - detects file-level corruption without loading pixels.
                img.verify()
            # Re-open because verify() closes the handle.
            with Image.open(f) as img:
                mode = img.mode
                w, h = img.size
        except Exception as e:
            errors.append(f"Invalid image {f.name}: {e}")
            continue

        count += 1
        modes[mode] = modes.get(mode, 0) + 1

        if min(w, h) < min_resolution:
            errors.append(f"{f.name}: resolution {w}x{h} below hard minimum {min_resolution}px")
            too_small_count += 1
        elif min(w, h) < warn_resolution:
            warn_resolution_count += 1

        # Quality filtering - low-quality images are logged and counted, never
        # silently dropped, so operators can review the report and decide.
        if enable_quality:
            try:
                with Image.open(f) as img:
                    arr = np.asarray(img.convert("RGB"))
                if not assess_image_quality(arr):
                    warnings.append(
                        f"{f.name}: failed quality check "
                        f"(blur/contrast/edge-density below thresholds)"
                    )
                    low_quality_count += 1
            except Exception as e:
                warnings.append(f"quality check failed for {f.name}: {e}")

        if enable_dupe:
            try:
                phashes.append((f, _phash(f)))
            except Exception as e:
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
    """Return list of (file_a, file_b) tuples where phashes match exactly.

    True perceptual hashing allows a small Hamming distance; we use exact
    matching here because it's O(n) and sufficient for catching
    re-uploaded-under-different-filename cases, which is the common
    cause. Near-dupe detection is a separate problem.
    """
    seen: dict[str, Path] = {}
    dupes: list[tuple[str, str]] = []
    for path, hash_value in phashes:
        if hash_value in seen:
            dupes.append((str(seen[hash_value].name), str(path.name)))
        else:
            seen[hash_value] = path
    return dupes


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

    benign_dir = base / "breast_benign"
    malignant_dir = base / "breast_malignant"

    errors: list[str] = []
    warnings: list[str] = []
    results: dict[str, object] = {
        "status": "success",
        "errors": errors,
        "warnings": warnings,
    }

    if not benign_dir.exists():
        errors.append(f"Benign directory not found: {benign_dir}")
    if not malignant_dir.exists():
        errors.append(f"Malignant directory not found: {malignant_dir}")

    if errors:
        results["status"] = "failed"
        (out / "validation_report.json").write_text(json.dumps(results, indent=2, default=str))
        return False

    benign_stats = _scan_class(benign_dir, errors, warnings)
    malignant_stats = _scan_class(malignant_dir, errors, warnings)

    results["benign_count"] = benign_stats["count"]
    results["malignant_count"] = malignant_stats["count"]
    results["benign_modes"] = benign_stats["modes"]
    results["malignant_modes"] = malignant_stats["modes"]
    results["benign_too_small"] = benign_stats["too_small"]
    results["malignant_too_small"] = malignant_stats["too_small"]
    results["benign_warn_resolution"] = benign_stats["warn_resolution"]
    results["malignant_warn_resolution"] = malignant_stats["warn_resolution"]
    results["benign_low_quality"] = benign_stats["low_quality"]
    results["malignant_low_quality"] = malignant_stats["low_quality"]

    # Minimum-count gate.
    min_per_class = int(os.environ.get("MIN_IMAGES_PER_CLASS", "100"))
    if benign_stats["count"] < min_per_class:
        errors.append(f"Too few benign: {benign_stats['count']} (minimum: {min_per_class})")
    if malignant_stats["count"] < min_per_class:
        errors.append(f"Too few malignant: {malignant_stats['count']} (minimum: {min_per_class})")

    # Color-mode consistency. Only fail hard when a class mixes RGB with
    # non-RGB - trainers normalise RGB specifically.
    if _get_bool_env("ENABLE_MODE_CHECK", True):
        for cls_name, cls_stats in (
            ("benign", benign_stats),
            ("malignant", malignant_stats),
        ):
            modes = cls_stats["modes"]  # type: ignore[index]
            if len(modes) > 1:
                # "RGB" + "RGBA" is usually just PNGs with alpha; we downgrade
                # to warning. Anything else (e.g. L + RGB) is a hard fail.
                non_rgb = {m for m in modes if m not in ("RGB", "RGBA")}
                if non_rgb:
                    errors.append(
                        f"{cls_name}: mixed color modes {modes} - training "
                        f"will silently convert grayscale, distorting stats"
                    )
                else:
                    warnings.append(
                        f"{cls_name}: mixed RGB/RGBA modes {modes} - RGBA "
                        f"alpha will be dropped during preprocessing"
                    )

    # Duplicate detection.
    if _get_bool_env("ENABLE_DUPLICATE_CHECK", True):
        for cls_name, cls_stats in (
            ("benign", benign_stats),
            ("malignant", malignant_stats),
        ):
            dupes = _find_duplicates(cls_stats["phashes"])  # type: ignore[arg-type]
            if dupes:
                warnings.append(
                    f"{cls_name}: {len(dupes)} duplicate image pair(s) - first few: {dupes[:3]}"
                )

    # Class-balance gate. Minority / majority < threshold is a hard fail
    # because the ensemble weights are accuracy-proportional and heavy
    # imbalance drives accuracy up while masking poor minority-class recall.
    min_balance = _get_float_env("MIN_CLASS_BALANCE_RATIO", 0.3)
    total_counts = [benign_stats["count"], malignant_stats["count"]]  # type: ignore[list-item]
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
        "Validation: %d benign, %d malignant, %d errors, %d warnings",
        benign_stats["count"],
        malignant_stats["count"],
        len(errors),
        len(warnings),
    )

    # Log each error/warning so failures are diagnosable from the job log
    # (previously only the counts were emitted, which made triage impossible).
    for e in errors:
        logger.error("Validation error: %s", e)
    for w in warnings:
        logger.warning("Validation warning: %s", w)

    # CloudWatch-friendly JSON log lines.
    for name, value in [
        ("DataValidation_BenignCount", benign_stats["count"]),
        ("DataValidation_MalignantCount", malignant_stats["count"]),
        ("DataValidation_TotalImages", benign_stats["count"] + malignant_stats["count"]),  # type: ignore[operator]
        ("DataValidation_ErrorCount", len(errors)),
        ("DataValidation_WarningCount", len(warnings)),
        (
            "DataValidation_LowQualityCount",
            benign_stats["low_quality"] + malignant_stats["low_quality"],  # type: ignore[operator]
        ),
    ]:
        logger.info(json.dumps({"metric_name": name, "metric_value": value}))

    # Drop phashes before serialising - they're internal to the scan.
    for s in (benign_stats, malignant_stats):
        s.pop("phashes", None)

    (out / "validation_report.json").write_text(json.dumps(results, indent=2, default=str))
    return results["status"] == "success"


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate medical image dataset")
    parser.add_argument("--input-path", required=True)
    parser.add_argument("--output-path", required=True)
    args = parser.parse_args()

    ok = validate_dataset(args.input_path, args.output_path)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
