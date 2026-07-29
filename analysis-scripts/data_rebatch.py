#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import argparse
import json
import random
import shutil
from pathlib import Path


def collect_class(source_dir: Path, class_name: str) -> list[tuple[Path, str]]:
    """Walk source_dir/*/<class_name> and return (path, source_batch) tuples."""
    results: list[tuple[Path, str]] = []
    for batch_dir in sorted(source_dir.iterdir()):
        if not batch_dir.is_dir():
            continue
        if batch_dir.name.startswith("batches_"):
            continue  # skip previously generated mini-batch directories
        class_dir = batch_dir / class_name
        if not class_dir.exists():
            continue
        for ext in ("*.jpg", "*.jpeg", "*.png", "*.bmp", "*.tif", "*.tiff"):
            for p in class_dir.glob(ext):
                results.append((p, batch_dir.name))
    return results


def main() -> int:
    parser = argparse.ArgumentParser(description="Re-batch all data into small balanced batches")
    parser.add_argument("--source-dir", type=Path, default=Path("data"))
    parser.add_argument("--output-dir", type=Path, default=Path("data/batches_small"))
    parser.add_argument(
        "--images-per-batch",
        type=int,
        default=300,
        help="Total images per mini-batch (half benign, half malignant)",
    )
    parser.add_argument("--seed", type=int, default=2026)
    parser.add_argument(
        "--copy-mode",
        choices=["symlink", "copy"],
        default="symlink",
        help="symlink (fast, low disk) or copy (self-contained)",
    )
    args = parser.parse_args()

    rng = random.Random(args.seed)  # nosec B311 - seeded PRNG for reproducible dataset sampling, not security
    benign = collect_class(args.source_dir, "breast_benign")
    malignant = collect_class(args.source_dir, "breast_malignant")

    print(f"Pooled {len(benign):,} benign and {len(malignant):,} malignant images")

    rng.shuffle(benign)
    rng.shuffle(malignant)

    per_class = args.images_per_batch // 2
    n_full_batches = min(len(benign), len(malignant)) // per_class
    print(
        f"Creating {n_full_batches} balanced mini-batches of {args.images_per_batch} images "
        f"({per_class} benign + {per_class} malignant each)"
    )

    if args.output_dir.exists():
        shutil.rmtree(args.output_dir)
    args.output_dir.mkdir(parents=True)

    manifest: dict[str, list] = {"mini_batches": []}
    for i in range(n_full_batches):
        batch_name = f"batch_{i + 1:03d}"
        batch_dir = args.output_dir / batch_name
        (batch_dir / "breast_benign").mkdir(parents=True)
        (batch_dir / "breast_malignant").mkdir(parents=True)

        assignments = []
        for class_label, pool in [("breast_benign", benign), ("breast_malignant", malignant)]:
            for src_path, source_batch in pool[i * per_class : (i + 1) * per_class]:
                dst_path = batch_dir / class_label / src_path.name
                if args.copy_mode == "symlink":
                    dst_path.symlink_to(src_path.resolve())
                else:
                    shutil.copy2(src_path, dst_path)
                assignments.append(
                    {
                        "file": str(dst_path.relative_to(args.output_dir)),
                        "class": class_label,
                        "source": source_batch,
                    }
                )

        manifest["mini_batches"].append(
            {
                "name": batch_name,
                "benign_count": per_class,
                "malignant_count": per_class,
                "files": assignments,
            }
        )
        if (i + 1) % 10 == 0 or (i + 1) == n_full_batches:
            print(f"  Created {i + 1}/{n_full_batches}")

    manifest_path = args.output_dir / "_manifest.json"
    manifest_path.write_text(
        json.dumps(
            {
                "total_mini_batches": n_full_batches,
                "images_per_batch": args.images_per_batch,
                "per_class_per_batch": per_class,
                "copy_mode": args.copy_mode,
                "seed": args.seed,
                "source_dir": str(args.source_dir),
                "mini_batches": [mb["name"] for mb in manifest["mini_batches"]],
            },
            indent=2,
        )
    )
    print(f"✓ Wrote {manifest_path}")
    print(f"✓ {n_full_batches} mini-batches ready under {args.output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
