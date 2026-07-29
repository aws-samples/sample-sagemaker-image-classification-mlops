#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import argparse
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
from PIL import Image, ImageEnhance, ImageOps


def augment_hflip(img: Image.Image) -> Image.Image:
    return ImageOps.mirror(img)


def augment_rotation(img: Image.Image, angle: int = 20) -> Image.Image:
    return img.rotate(angle, expand=False, fillcolor=(0, 0, 0))


def augment_brightness(img: Image.Image, factor: float = 1.25) -> Image.Image:
    return ImageEnhance.Brightness(img).enhance(factor)


def augment_contrast(img: Image.Image, factor: float = 1.4) -> Image.Image:
    return ImageEnhance.Contrast(img).enhance(factor)


def make_grid(sample_benign: Path, sample_malignant: Path, out_path: Path):
    # Single-row layout showing the preprocessing pipeline on one benign sample.
    fig, axes = plt.subplots(1, 6, figsize=(18, 3.5))

    raw = Image.open(sample_benign).convert("RGB")
    resized = raw.resize((224, 224))
    normalized_display = np.clip(np.asarray(resized).astype(np.float32) / 255.0, 0, 1)

    steps = [
        np.asarray(raw),
        np.asarray(resized),
        normalized_display,
        np.asarray(augment_hflip(resized)),
        np.asarray(augment_rotation(resized)),
        np.asarray(augment_brightness(resized)),
    ]
    for col, img_arr in enumerate(steps):
        axes[col].imshow(img_arr)
        axes[col].axis("off")

    fig.tight_layout()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path, dpi=150, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"  ✓ {out_path}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Preprocessing samples chart")
    parser.add_argument("--benign", type=Path, required=True)
    parser.add_argument("--malignant", type=Path, required=True)
    parser.add_argument(
        "--output", type=Path, default=Path("blog/charts/preprocessing_before_after.png")
    )
    args = parser.parse_args()
    make_grid(args.benign, args.malignant, args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
