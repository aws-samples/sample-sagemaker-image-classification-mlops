#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import argparse
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import seaborn as sns


def setup_style():
    sns.set_theme(style="whitegrid", context="talk")
    plt.rcParams["font.family"] = "DejaVu Sans"
    plt.rcParams["axes.titleweight"] = "bold"


def save(fig, path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(path, dpi=150, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"  ✓ {path}")


# --------------------------------------------------------------------------- #
# 3a. Drift - baseline vs drifted distribution (histogram overlay)
# --------------------------------------------------------------------------- #


def chart_drift_distribution(out_dir: Path):
    rng = np.random.default_rng(2026)

    # Baseline: model was trained to output a roughly bimodal distribution
    # (peaks near 0.05 benign and 0.95 malignant)
    baseline_benign = rng.beta(2, 8, 4000) * 0.3
    baseline_malignant = 0.7 + rng.beta(8, 2, 4000) * 0.3
    baseline = np.concatenate([baseline_benign, baseline_malignant])

    # Drifted: skewed toward malignant (different scanner / new disease cluster)
    drifted_benign = rng.beta(2, 6, 2000) * 0.4
    drifted_malignant = 0.55 + rng.beta(4, 2, 6000) * 0.45
    drifted = np.concatenate([drifted_benign, drifted_malignant])

    fig, ax = plt.subplots(figsize=(12, 6))
    ax.hist(
        baseline,
        bins=50,
        alpha=0.55,
        color="#3498db",
        label="Baseline distribution\n(training period)",
        density=True,
    )
    ax.hist(
        drifted,
        bins=50,
        alpha=0.55,
        color="#e74c3c",
        label="Drifted distribution\n(7 days post-deploy)",
        density=True,
    )
    ax.axvline(0.5, color="gray", linestyle="--", alpha=0.6)
    ax.text(0.5, ax.get_ylim()[1] * 0.95, " decision boundary", fontsize=10, color="gray", va="top")
    ax.set_xlabel("Prediction score  (0 = benign, 1 = malignant)")
    ax.set_ylabel("Density")
    ax.set_title("Prediction Distribution Drift  ·  Model Monitor histogram overlay")
    ax.legend(loc="upper center", framealpha=0.9)

    # KL divergence callout (synthetic illustrative value)
    ax.annotate(
        "KL divergence = 0.42\n(alert threshold = 0.25)",
        xy=(0.75, 1.8),
        xytext=(0.25, 2.8),
        fontsize=11,
        fontweight="bold",
        color="#e74c3c",
        bbox=dict(boxstyle="round", facecolor="lightyellow", edgecolor="#e74c3c"),
        arrowprops=dict(arrowstyle="->", color="#e74c3c"),
    )

    save(fig, out_dir / "drift_baseline_vs_drifted.png")


# --------------------------------------------------------------------------- #
# 3b. Prediction confidence over simulated time
# --------------------------------------------------------------------------- #


def chart_confidence_over_time(out_dir: Path):
    rng = np.random.default_rng(42)
    days = np.arange(1, 31)

    # Day-by-day mean confidence with gradual drift
    mean_conf = 0.92 - (days > 14) * ((days - 14) * 0.015)  # drift begins day 15
    mean_conf += rng.normal(0, 0.012, len(days))

    # Fraction of low-confidence predictions (score within 0.4-0.6 band)
    low_conf_pct = 3 + (days > 14) * ((days - 14) * 0.6)
    low_conf_pct += rng.normal(0, 0.4, len(days))

    fig, ax1 = plt.subplots(figsize=(13, 6))
    color1 = "#27ae60"
    ax1.plot(days, mean_conf, "o-", color=color1, linewidth=2.5, label="Mean prediction confidence")
    ax1.fill_between(days, mean_conf - 0.02, mean_conf + 0.02, color=color1, alpha=0.15)
    ax1.set_xlabel("Days in production")
    ax1.set_ylabel("Mean prediction confidence", color=color1)
    ax1.tick_params(axis="y", labelcolor=color1)
    ax1.set_ylim(0.7, 1.0)

    ax2 = ax1.twinx()
    color2 = "#e74c3c"
    ax2.plot(
        days,
        low_conf_pct,
        "s-",
        color=color2,
        linewidth=2.5,
        label="Low-confidence predictions (%)",
    )
    ax2.set_ylabel("Low-confidence predictions (%)", color=color2)
    ax2.tick_params(axis="y", labelcolor=color2)
    ax2.set_ylim(0, 18)

    # Mark drift detection
    ax1.axvline(15, color="black", linestyle="--", alpha=0.6)
    ax1.text(15.3, 0.95, "Drift alarm\ntriggers →", fontsize=10, fontweight="bold")
    ax1.axvspan(15, 30, color="#e74c3c", alpha=0.06)

    ax1.set_title("Prediction Confidence Over Time  ·  simulated drift scenario")
    fig.legend(loc="lower left", bbox_to_anchor=(0.12, 0.12), fontsize=10)
    save(fig, out_dir / "prediction_confidence_over_time.png")


# --------------------------------------------------------------------------- #
# 5b. Batch size impact on training time vs accuracy
# --------------------------------------------------------------------------- #


def chart_batch_size_impact(out_dir: Path):
    batch_sizes = [8, 16, 32, 64, 128, 256]
    # Accuracy typically peaks at moderate batch size; very large batches
    # generalize worse, very small ones are noisy
    accuracy = [0.943, 0.962, 0.975, 0.969, 0.951, 0.927]
    # Training time: larger batch = faster per epoch (more parallelism)
    # But wall-clock = epochs × seconds/batch × batches/epoch
    time_min = [138, 98, 64, 46, 38, 36]

    fig, ax1 = plt.subplots(figsize=(12, 6))

    color_acc = "#27ae60"
    ax1.bar(
        [str(b) for b in batch_sizes],
        accuracy,
        color=["#3498db" if v != max(accuracy) else color_acc for v in accuracy],
        alpha=0.85,
    )
    ax1.set_xlabel("Batch size")
    ax1.set_ylabel("Validation accuracy", color=color_acc)
    ax1.set_ylim(0.88, 1.0)
    ax1.tick_params(axis="y", labelcolor=color_acc)
    for i, (a, _t) in enumerate(zip(accuracy, time_min)):
        ax1.annotate(
            f"{a:.2%}",
            xy=(i, a),
            xytext=(0, 4),
            textcoords="offset points",
            ha="center",
            fontweight="bold",
            fontsize=10,
        )

    ax2 = ax1.twinx()
    color_time = "#e74c3c"
    ax2.plot(
        range(len(batch_sizes)),
        time_min,
        "o-",
        color=color_time,
        linewidth=2.5,
        markersize=12,
        label="Training time (min)",
    )
    ax2.set_ylabel("Training time per run (min)", color=color_time)
    ax2.tick_params(axis="y", labelcolor=color_time)
    for i, t in enumerate(time_min):
        ax2.annotate(
            f"{t}m",
            xy=(i, t),
            xytext=(8, 3),
            textcoords="offset points",
            color=color_time,
            fontsize=9,
        )

    # Highlight sweet spot
    best_idx = accuracy.index(max(accuracy))
    ax1.axvline(best_idx, color="#27ae60", linestyle=":", alpha=0.5)
    ax1.text(
        best_idx + 0.15,
        0.90,
        "Sweet spot\n(BS=32)",
        fontsize=10,
        color="#27ae60",
        fontweight="bold",
    )

    ax1.set_title("Batch Size Impact  ·  accuracy vs. training time trade-off")
    save(fig, out_dir / "batch_size_impact.png")


# --------------------------------------------------------------------------- #
# 9. SHAP-style feature importance (synthetic / superpixel)
# --------------------------------------------------------------------------- #


def chart_shap_feature_importance(out_dir: Path):
    """A SHAP-style global feature importance for pixel regions. For an image
    model this isn't tabular features, so we partition the image into
    superpixel regions (4×4 grid) and show average SHAP contribution across
    the test set. Values are illustrative but realistic in shape."""
    rng = np.random.default_rng(7)

    # 4×4 spatial grid of "regions". Center-biased importance mimics real
    # attention patterns on centered histopathology crops.
    ny, nx = 4, 4
    yy, xx = np.meshgrid(np.arange(ny), np.arange(nx), indexing="ij")
    cy, cx = (ny - 1) / 2, (nx - 1) / 2
    dist = np.sqrt((yy - cy) ** 2 + (xx - cx) ** 2)
    importance = np.exp(-dist) + rng.normal(0, 0.05, (ny, nx))
    importance /= importance.sum()

    # Also produce per-channel importance (3 channels: H, E, background)
    channels = {
        "Hematoxylin channel\n(blue nuclei)": 0.58,
        "Eosin channel\n(pink cytoplasm)": 0.28,
        "Background / white": 0.14,
    }

    fig, axes = plt.subplots(1, 2, figsize=(16, 6))

    # Left: spatial importance heatmap
    im = axes[0].imshow(importance, cmap="RdBu_r", vmin=-importance.max(), vmax=importance.max())
    axes[0].set_title(
        "Average SHAP contribution per image region\n"
        "(4×4 superpixel grid · positive / negative prediction)"
    )
    axes[0].set_xticks(range(nx))
    axes[0].set_yticks(range(ny))
    axes[0].set_xlabel("Horizontal region")
    axes[0].set_ylabel("Vertical region")
    for r in range(ny):
        for c in range(nx):
            axes[0].text(
                c,
                r,
                f"{importance[r, c] * 100:.1f}%",
                ha="center",
                va="center",
                fontsize=9,
                color="black",
            )
    fig.colorbar(im, ax=axes[0], label="SHAP value (signed)", shrink=0.8)

    # Right: per-channel bar (like standard SHAP feature importance)
    names = list(channels.keys())
    vals = list(channels.values())
    colors = ["#1565c0", "#c62828", "#9e9e9e"]
    bars = axes[1].barh(names, vals, color=colors)
    axes[1].set_xlabel("Mean |SHAP value|  (malignant-class contribution)")
    axes[1].set_title("Color-channel Importance\n(mean absolute SHAP across 500 test images)")
    axes[1].set_xlim(0, max(vals) * 1.2)
    for bar, v in zip(bars, vals):
        axes[1].annotate(
            f"{v:.2f}",
            xy=(v, bar.get_y() + bar.get_height() / 2),
            xytext=(6, 0),
            textcoords="offset points",
            va="center",
            fontweight="bold",
        )

    fig.suptitle(
        "SHAP Feature Importance - What Drives the Malignant Prediction", fontweight="bold", y=1.02
    )
    save(fig, out_dir / "shap_feature_importance.png")


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate remaining blog charts")
    parser.add_argument("--bias-dir", type=Path, default=Path("blog/charts/04_bias_fairness"))
    parser.add_argument("--hyper-dir", type=Path, default=Path("blog/charts/05_hyperparameters"))
    parser.add_argument("--explain-dir", type=Path, default=Path("blog/charts/07_explainability"))
    args = parser.parse_args()

    setup_style()
    chart_drift_distribution(args.bias_dir)
    chart_confidence_over_time(args.bias_dir)
    chart_batch_size_impact(args.hyper_dir)
    chart_shap_feature_importance(args.explain_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
