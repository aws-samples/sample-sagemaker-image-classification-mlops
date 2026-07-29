#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import argparse
import json
import random
import shutil
from pathlib import Path


def collect(source_dir: Path, class_name: str) -> list[Path]:
    out: list[Path] = []
    for batch_dir in sorted(source_dir.iterdir()):
        if not batch_dir.is_dir() or batch_dir.name.startswith("batches_"):
            continue
        if batch_dir.name in ("biased_malignant_heavy", "balanced_augmented"):
            continue
        class_dir = batch_dir / class_name
        if class_dir.exists():
            for ext in ("*.jpg", "*.jpeg", "*.png", "*.bmp"):
                out.extend(class_dir.glob(ext))
    return out


def make_scenario(
    out_dir: Path,
    benign_count: int,
    malignant_count: int,
    benign_pool: list[Path],
    malignant_pool: list[Path],
):
    if out_dir.exists():
        shutil.rmtree(out_dir)
    (out_dir / "breast_benign").mkdir(parents=True)
    (out_dir / "breast_malignant").mkdir(parents=True)

    for src in benign_pool[:benign_count]:
        (out_dir / "breast_benign" / src.name).symlink_to(src.resolve())
    for src in malignant_pool[:malignant_count]:
        (out_dir / "breast_malignant" / src.name).symlink_to(src.resolve())


def main() -> int:
    parser = argparse.ArgumentParser(description="Create bias demonstration datasets")
    parser.add_argument("--source-dir", type=Path, default=Path("data"))
    parser.add_argument("--output-root", type=Path, default=Path("data"))
    parser.add_argument("--seed", type=int, default=2026)
    parser.add_argument(
        "--biased-total",
        type=int,
        default=5000,
        help="Total images in biased scenario (default: 5000)",
    )
    parser.add_argument(
        "--biased-malignant-ratio",
        type=float,
        default=0.80,
        help="Fraction of malignant samples in biased scenario (default: 0.80)",
    )
    parser.add_argument(
        "--balanced-total",
        type=int,
        default=5000,
        help="Total images in balanced scenario (default: 5000)",
    )
    args = parser.parse_args()

    rng = random.Random(args.seed)  # nosec B311 - seeded PRNG for reproducible dataset sampling, not security
    benign = collect(args.source_dir, "breast_benign")
    malignant = collect(args.source_dir, "breast_malignant")
    rng.shuffle(benign)
    rng.shuffle(malignant)
    print(f"Pool: {len(benign):,} benign | {len(malignant):,} malignant")

    # Scenario A: biased (malignant-heavy)
    b_mal = int(args.biased_total * args.biased_malignant_ratio)
    b_ben = args.biased_total - b_mal
    biased_dir = args.output_root / "biased_malignant_heavy"
    make_scenario(biased_dir, b_ben, b_mal, benign, malignant)
    print(
        f"✓ Biased scenario ({biased_dir}): {b_ben} benign + {b_mal} malignant  "
        f"({args.biased_malignant_ratio:.0%} malignant)"
    )

    # Scenario B: balanced
    half = args.balanced_total // 2
    balanced_dir = args.output_root / "balanced_augmented"
    make_scenario(balanced_dir, half, half, benign, malignant)
    print(f"✓ Balanced scenario ({balanced_dir}): {half} benign + {half} malignant  (50%/50%)")

    # Save manifest
    manifest_path = args.output_root / "bias_scenarios_manifest.json"
    manifest_path.write_text(
        json.dumps(
            {
                "biased": {
                    "path": str(biased_dir),
                    "benign": b_ben,
                    "malignant": b_mal,
                    "ratio_malignant": args.biased_malignant_ratio,
                },
                "balanced": {
                    "path": str(balanced_dir),
                    "benign": half,
                    "malignant": half,
                    "ratio_malignant": 0.5,
                },
            },
            indent=2,
        )
    )
    print(f"✓ Manifest written to {manifest_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
