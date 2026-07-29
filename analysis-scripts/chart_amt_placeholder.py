#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import argparse
from pathlib import Path

import matplotlib.pyplot as plt
import matplotlib.ticker as mticker
import numpy as np
import seaborn as sns


def setup_style():
    sns.set_theme(style="whitegrid", context="talk")
    plt.rcParams["axes.titleweight"] = "bold"


def render(out_path: Path):
    setup_style()
    rng = np.random.default_rng(2026)
    n = 25
    # Hyperparameter search space
    lrs = 10 ** rng.uniform(-5, -2, n)
    batch_sizes = rng.choice([16, 32, 64, 128], size=n)
    dropout = rng.uniform(0.1, 0.5, n)
    # Simulate target: val accuracy peaks around LR=1e-3, medium BS, dropout~0.3
    ideal_lr = np.log10(lrs) - np.log10(1e-3)
    ideal_bs = (np.log2(batch_sizes) - 5) / 2  # centered around 32
    ideal_do = (dropout - 0.3) / 0.1
    score = 0.95 - 0.02 * (ideal_lr**2) - 0.015 * (ideal_bs**2) - 0.008 * (ideal_do**2)
    score += rng.normal(0, 0.008, n)
    score = np.clip(score, 0.82, 0.99)

    best = np.argmax(score)

    fig, axes = plt.subplots(1, 2, figsize=(15, 6))

    # Left panel: trials sorted by score
    order = np.argsort(-score)
    ranks = np.arange(1, n + 1)
    colors = ["#27ae60" if i == 0 else "#3498db" for i in range(n)]
    axes[0].bar(ranks, score[order], color=colors)
    axes[0].set_xlabel("Trial rank (by val_accuracy, descending)")
    axes[0].set_ylabel("Objective: val_accuracy")
    axes[0].set_ylim(0.80, 1.0)
    axes[0].set_title("Automatic Model Tuning - 25 Trials")
    axes[0].annotate(
        f"Best: {score[order][0]:.4f}",
        xy=(1, score[order][0]),
        xytext=(4, 0.93),
        fontsize=11,
        fontweight="bold",
        bbox=dict(boxstyle="round", facecolor="lightyellow", edgecolor="#27ae60"),
        arrowprops=dict(arrowstyle="->", color="#27ae60"),
    )

    # Right panel: parallel coordinates lite - LR vs val_accuracy colored by BS
    sc = axes[1].scatter(
        lrs, score, c=batch_sizes, cmap="viridis", s=110, edgecolors="white", linewidth=1.2
    )
    axes[1].scatter(
        [lrs[best]],
        [score[best]],
        s=400,
        facecolor="none",
        edgecolor="#e74c3c",
        linewidth=3,
        label="Best trial",
    )
    axes[1].set_xscale("log")
    axes[1].xaxis.set_major_formatter(mticker.LogFormatterMathtext())
    axes[1].set_xlabel("Learning rate")
    axes[1].set_ylabel("Objective: val_accuracy")
    axes[1].set_title("Val Accuracy vs Learning Rate  (color = batch size)")
    axes[1].legend(loc="lower left")
    fig.colorbar(sc, ax=axes[1], label="batch size")

    fig.suptitle(
        "SageMaker Automatic Model Tuning - Illustrative Results", fontweight="bold", y=1.02
    )
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.tight_layout()
    fig.savefig(out_path, dpi=150, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"  ✓ {out_path}")

    # Print best hyperparameters for documentation
    print()
    print("Best hyperparameter configuration (illustrative):")
    print(f"  learning_rate = {lrs[best]:.5f}")
    print(f"  batch_size    = {int(batch_sizes[best])}")
    print(f"  dropout       = {dropout[best]:.3f}")
    print(f"  val_accuracy  = {score[best]:.4f}")


def main() -> int:
    parser = argparse.ArgumentParser(description="AMT tuning placeholder chart")
    parser.add_argument(
        "--output", type=Path, default=Path("blog/charts/amt_tuning_placeholder.png")
    )
    args = parser.parse_args()
    render(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
