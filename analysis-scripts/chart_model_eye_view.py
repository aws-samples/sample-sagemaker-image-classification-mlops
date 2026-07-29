#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import argparse
import random
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
from PIL import Image, ImageEnhance, ImageOps

IMG_SIZE = 224
IMAGENET_MEAN = np.array([0.485, 0.456, 0.406])
IMAGENET_STD = np.array([0.229, 0.224, 0.225])


def load_raw(path: Path) -> Image.Image:
    return Image.open(path).convert("RGB")


def resize(img: Image.Image) -> Image.Image:
    return img.resize((IMG_SIZE, IMG_SIZE))


def to_array_01(img: Image.Image) -> np.ndarray:
    return np.asarray(img, dtype=np.float32) / 255.0


def imagenet_normalize(x: np.ndarray) -> np.ndarray:
    return (x - IMAGENET_MEAN) / IMAGENET_STD


def disp(ax, img_or_array, title: str, cmap=None, vmin=None, vmax=None):
    ax.imshow(img_or_array, cmap=cmap, vmin=vmin, vmax=vmax)
    ax.set_title(title, fontsize=11)
    ax.axis("off")


# --------------------------------------------------------------------------- #
# 1. Full preprocessing pipeline chart
# --------------------------------------------------------------------------- #


def chart_full_pipeline(raw_path: Path, out_path: Path):
    raw = load_raw(raw_path)
    resized = resize(raw)
    x01 = to_array_01(resized)
    x_norm = imagenet_normalize(x01)
    # For display, remap normalized tensor back to [0,1] so humans can see it
    x_norm_display = (x_norm - x_norm.min()) / (x_norm.max() - x_norm.min())

    r_chan = x01[..., 0]
    g_chan = x01[..., 1]
    b_chan = x01[..., 2]

    fig = plt.figure(figsize=(18, 9))
    gs = fig.add_gridspec(3, 6, hspace=0.35, wspace=0.15)

    # Row 1: pipeline flow
    ax1 = fig.add_subplot(gs[0, 0])
    disp(ax1, np.asarray(raw), f"1) Raw input\n{raw.width}×{raw.height}")
    ax2 = fig.add_subplot(gs[0, 1])
    disp(ax2, np.asarray(resized), "2) Resize to 224×224\n(bilinear)")
    ax3 = fig.add_subplot(gs[0, 2])
    disp(ax3, x01, "3) Pixel scale /255\n→ float32 [0,1]")
    ax4 = fig.add_subplot(gs[0, 3])
    disp(ax4, x_norm_display, "4) ImageNet normalize\n(µ/σ per channel)")
    ax5 = fig.add_subplot(gs[0, 4])
    disp(ax5, r_chan, "5) Red channel", cmap="Reds")
    ax6 = fig.add_subplot(gs[0, 5])
    disp(ax6, g_chan, "6) Green channel", cmap="Greens")

    # Row 2: extended channel view + tensor facts
    ax7 = fig.add_subplot(gs[1, 0])
    disp(ax7, b_chan, "7) Blue channel", cmap="Blues")

    # Pixel-value histograms before and after normalization
    ax_hist_before = fig.add_subplot(gs[1, 1:3])
    for c, color in zip(range(3), ["red", "green", "blue"]):
        ax_hist_before.hist(x01[..., c].flatten(), bins=50, alpha=0.55, color=color, label=color)
    ax_hist_before.set_title("Pixel value distribution\n(after /255 - step 3)", fontsize=11)
    ax_hist_before.set_xlabel("value")
    ax_hist_before.set_ylabel("count")
    ax_hist_before.legend(fontsize=8)

    ax_hist_after = fig.add_subplot(gs[1, 3:5])
    for c, color in zip(range(3), ["red", "green", "blue"]):
        ax_hist_after.hist(x_norm[..., c].flatten(), bins=50, alpha=0.55, color=color, label=color)
    ax_hist_after.set_title(
        "Pixel value distribution\n(after ImageNet normalize - step 4)", fontsize=11
    )
    ax_hist_after.set_xlabel("value")
    ax_hist_after.set_ylabel("count")
    ax_hist_after.legend(fontsize=8)

    ax_facts = fig.add_subplot(gs[1, 5])
    ax_facts.axis("off")
    facts = (
        f"Tensor shape:\n{x_norm.shape}\n\n"
        f"dtype: float32\n\n"
        f"Min: {x_norm.min():.3f}\n"
        f"Max: {x_norm.max():.3f}\n"
        f"Mean: {x_norm.mean():.3f}\n"
        f"Std:  {x_norm.std():.3f}\n\n"
        f"Memory:\n{x_norm.nbytes / 1024:.1f} KB"
    )
    ax_facts.text(
        0,
        0.95,
        facts,
        va="top",
        fontsize=10,
        family="monospace",
        bbox=dict(boxstyle="round", facecolor="#f4f4f4", edgecolor="gray"),
    )
    ax_facts.set_title("What the model sees", fontsize=11)

    # Row 3: augmentation variations (training-time only)
    augs = [
        ("Horizontal flip", np.asarray(ImageOps.mirror(resized))),
        ("Rotate +15°", np.asarray(resized.rotate(15))),
        ("Rotate -15°", np.asarray(resized.rotate(-15))),
        ("Brightness +25%", np.asarray(ImageEnhance.Brightness(resized).enhance(1.25))),
        ("Brightness -25%", np.asarray(ImageEnhance.Brightness(resized).enhance(0.75))),
        ("Contrast +40%", np.asarray(ImageEnhance.Contrast(resized).enhance(1.4))),
    ]
    for i, (title, img) in enumerate(augs):
        ax = fig.add_subplot(gs[2, i])
        disp(ax, img, f"Aug: {title}")

    fig.suptitle(f"Model's-Eye View - {raw_path.name}", fontweight="bold", fontsize=15, y=1.01)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path, dpi=150, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"  ✓ {out_path}")


# --------------------------------------------------------------------------- #
# 2. Raw vs model-input side-by-side
# --------------------------------------------------------------------------- #


def chart_raw_vs_model_input(raw_path: Path, out_path: Path):
    raw = load_raw(raw_path)
    resized = resize(raw)
    x01 = to_array_01(resized)
    x_norm = imagenet_normalize(x01)
    x_display = (x_norm - x_norm.min()) / (x_norm.max() - x_norm.min())

    fig, axes = plt.subplots(1, 3, figsize=(14, 5))
    disp(axes[0], np.asarray(raw), f"What a person sees\n(raw JPG/PNG - {raw.width}×{raw.height})")
    disp(axes[1], x01, "After preprocessing\n(224×224 × 3 × float32, scaled /255)")
    disp(axes[2], x_display, "What the model actually consumes\n(ImageNet-normalized tensor)")

    fig.suptitle("Raw image  vs.  model-input tensor", fontweight="bold", fontsize=14, y=1.03)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path, dpi=150, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"  ✓ {out_path}")


# --------------------------------------------------------------------------- #
# 3. Training batch grid - the sample a model actually processes per step
# --------------------------------------------------------------------------- #


def chart_training_batch_grid(
    benign_dir: Path, malignant_dir: Path, out_path: Path, grid_size: int = 4, seed: int = 2026
):
    rng = random.Random(seed)  # nosec B311 - seeded PRNG for reproducible image-grid sampling, not security

    benign_files = list(benign_dir.glob("*.png")) + list(benign_dir.glob("*.jpg"))
    malignant_files = list(malignant_dir.glob("*.png")) + list(malignant_dir.glob("*.jpg"))

    samples_per_class = (grid_size * grid_size) // 2
    picks = [
        (p, "benign") for p in rng.sample(benign_files, k=min(samples_per_class, len(benign_files)))
    ] + [
        (p, "malignant")
        for p in rng.sample(malignant_files, k=min(samples_per_class, len(malignant_files)))
    ]
    rng.shuffle(picks)

    fig, axes = plt.subplots(grid_size, grid_size, figsize=(12, 12))
    axes = axes.ravel()
    for ax, (path, label) in zip(axes, picks):
        img = Image.open(path).convert("RGB").resize((IMG_SIZE, IMG_SIZE))
        color = "#27ae60" if label == "benign" else "#c0392b"
        ax.imshow(np.asarray(img))
        ax.set_title(label, fontsize=10, color=color, fontweight="bold")
        ax.axis("off")
        for spine in ax.spines.values():
            spine.set_visible(True)
            spine.set_color(color)
            spine.set_linewidth(3)

    fig.suptitle(
        f"A single training batch ({grid_size * grid_size} images, balanced)",
        fontweight="bold",
        fontsize=14,
        y=1.01,
    )
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path, dpi=150, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"  ✓ {out_path}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Model's-eye preprocessing visualization")
    parser.add_argument("--benign", type=Path, required=True, help="Single benign sample image")
    parser.add_argument(
        "--malignant", type=Path, required=True, help="Single malignant sample image"
    )
    parser.add_argument(
        "--benign-dir", type=Path, default=Path("data/batch4_breakhis/breast_benign")
    )
    parser.add_argument(
        "--malignant-dir", type=Path, default=Path("data/batch4_breakhis/breast_malignant")
    )
    parser.add_argument("--output-dir", type=Path, default=Path("blog/charts/03_preprocessing"))
    args = parser.parse_args()

    print(f"Generating model-eye-view charts into {args.output_dir}/ ...")

    chart_full_pipeline(args.benign, args.output_dir / "model_eye_view_benign.png")
    chart_full_pipeline(args.malignant, args.output_dir / "model_eye_view_malignant.png")
    chart_raw_vs_model_input(args.benign, args.output_dir / "raw_vs_model_input_benign.png")
    chart_raw_vs_model_input(args.malignant, args.output_dir / "raw_vs_model_input_malignant.png")
    chart_training_batch_grid(
        args.benign_dir, args.malignant_dir, args.output_dir / "training_batch_grid.png"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
