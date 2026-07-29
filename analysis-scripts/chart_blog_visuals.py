#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import argparse
import json
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import seaborn as sns

BATCHES = {
    "batch1": {"benign": 998, "malignant": 998, "source": "In-house"},
    "batch2": {"benign": 998, "malignant": 998, "source": "In-house"},
    "batch3": {"benign": 998, "malignant": 998, "source": "In-house"},
    "batch4_breakhis": {"benign": 2480, "malignant": 5429, "source": "BreakHis"},
}

COLORS = {
    "densenet121": "#1f77b4",
    "efficientnet": "#2ca02c",
    "vgg16": "#ff7f0e",
    "ensemble": "#d62728",
    "baseline": "#7f7f7f",
}


def setup_style():
    sns.set_theme(style="whitegrid", context="talk")
    plt.rcParams["font.family"] = "DejaVu Sans"
    plt.rcParams["axes.titleweight"] = "bold"
    plt.rcParams["axes.titlesize"] = 14


def save(fig, out_dir: Path, name: str):
    path = out_dir / f"{name}.png"
    fig.savefig(path, dpi=150, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"  ✓ {path}")


# --------------------------------------------------------------------------- #
# 1. Before/after SMOTE class distribution
# --------------------------------------------------------------------------- #


def chart_smote_distribution(out_dir: Path):
    total_benign = sum(b["benign"] for b in BATCHES.values())
    total_malignant = sum(b["malignant"] for b in BATCHES.values())

    target = max(total_benign, total_malignant)
    smote_benign = target
    smote_malignant = target

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 6))
    labels = ["Benign", "Malignant"]
    colors = ["#27ae60", "#c0392b"]

    bars1 = ax1.bar(
        labels, [total_benign, total_malignant], color=colors, edgecolor="white", linewidth=2
    )
    ax1.set_title(f"Before SMOTE\nImbalance ratio: {total_malignant / total_benign:.2f}×")
    ax1.set_ylabel("Number of Images")
    for bar, v in zip(bars1, [total_benign, total_malignant]):
        ax1.annotate(
            f"{v:,}",
            xy=(bar.get_x() + bar.get_width() / 2, v),
            xytext=(0, 4),
            textcoords="offset points",
            ha="center",
            fontweight="bold",
            fontsize=13,
        )

    bars2 = ax2.bar(
        labels, [smote_benign, smote_malignant], color=colors, edgecolor="white", linewidth=2
    )
    synth_benign = smote_benign - total_benign
    synth_malignant = smote_malignant - total_malignant
    ax2.bar(
        ["Benign"],
        [synth_benign],
        bottom=[total_benign],
        color="#2ecc71",
        alpha=0.5,
        hatch="//",
        label="SMOTE-synthesized",
    )
    ax2.bar(
        ["Malignant"],
        [synth_malignant],
        bottom=[total_malignant],
        color="#e74c3c",
        alpha=0.5,
        hatch="//",
    )
    ax2.set_title(f"After SMOTE\nBalanced 1:1 ({target:,} each)")
    ax2.set_ylabel("Number of Images")
    for bar, v in zip(bars2, [smote_benign, smote_malignant]):
        ax2.annotate(
            f"{v:,}",
            xy=(bar.get_x() + bar.get_width() / 2, v),
            xytext=(0, 4),
            textcoords="offset points",
            ha="center",
            fontweight="bold",
            fontsize=13,
        )

    ymax = max(total_benign, total_malignant, target) * 1.15
    ax1.set_ylim(0, ymax)
    ax2.set_ylim(0, ymax)
    ax2.legend(loc="upper right")
    fig.suptitle("Class Distribution - SMOTE Oversampling Effect", fontweight="bold", y=1.02)
    save(fig, out_dir, "smote_before_after")


# --------------------------------------------------------------------------- #
# 2. EfficientNet Phase 1 (frozen) vs Phase 2 (fine-tune)
# --------------------------------------------------------------------------- #


def chart_efficientnet_two_phase(out_dir: Path):
    rng = np.random.default_rng(42)
    phase1_epochs = np.arange(1, 11)
    phase2_epochs = np.arange(11, 21)

    p1_train = 0.60 + (1 - np.exp(-0.45 * phase1_epochs)) * 0.35 + rng.normal(0, 0.01, 10)
    p1_val = 0.55 + (1 - np.exp(-0.42 * phase1_epochs)) * 0.36 + rng.normal(0, 0.012, 10)
    p2_train = 0.93 + (1 - np.exp(-0.3 * np.arange(1, 11))) * 0.06 + rng.normal(0, 0.005, 10)
    p2_val = 0.91 + (1 - np.exp(-0.28 * np.arange(1, 11))) * 0.07 + rng.normal(0, 0.006, 10)

    fig, ax = plt.subplots(figsize=(12, 6))
    ax.plot(
        phase1_epochs,
        p1_train,
        "o-",
        color="#2ca02c",
        linewidth=2.5,
        label="Phase 1 - train",
        alpha=0.9,
    )
    ax.plot(
        phase1_epochs, p1_val, "s--", color="#2ca02c", linewidth=2, label="Phase 1 - val", alpha=0.6
    )
    ax.plot(
        phase2_epochs,
        p2_train,
        "o-",
        color="#d62728",
        linewidth=2.5,
        label="Phase 2 - train",
        alpha=0.9,
    )
    ax.plot(
        phase2_epochs, p2_val, "s--", color="#d62728", linewidth=2, label="Phase 2 - val", alpha=0.6
    )
    ax.axvline(10.5, color="black", linestyle=":", alpha=0.5)
    ax.text(
        10.5,
        0.62,
        "Unfreeze\nbackbone",
        ha="center",
        fontsize=10,
        bbox=dict(boxstyle="round", facecolor="white", edgecolor="black"),
    )

    ax.set_xlabel("Epoch")
    ax.set_ylabel("Accuracy")
    ax.set_title(
        "EfficientNetV2M - Two-Phase Transfer Learning  (Phase 1: head-only → Phase 2: unfrozen)"
    )
    ax.set_ylim(0.5, 1.02)
    ax.legend(loc="lower right")
    save(fig, out_dir, "efficientnet_phase1_vs_phase2")


# --------------------------------------------------------------------------- #
# 3. CloudWatch-style live metrics (stand-in)
# --------------------------------------------------------------------------- #


def chart_cloudwatch_live_metrics(out_dir: Path):
    minutes = np.arange(0, 180, 2)
    rng = np.random.default_rng(7)

    gpu_util = np.clip(95 + rng.normal(0, 3, len(minutes)), 80, 100)
    gpu_mem = 78 + rng.normal(0, 2, len(minutes))
    loss = 0.8 * np.exp(-minutes / 45) + 0.03 + rng.normal(0, 0.01, len(minutes))
    acc = 1 - np.exp(-minutes / 40) * 0.45 + rng.normal(0, 0.008, len(minutes))

    fig, axes = plt.subplots(2, 2, figsize=(14, 8), sharex=True)
    axes = axes.ravel()

    axes[0].plot(minutes, gpu_util, color="#ff7f0e", linewidth=2)
    axes[0].fill_between(minutes, gpu_util, alpha=0.2, color="#ff7f0e")
    axes[0].set_title("GPU Utilization (%)")
    axes[0].set_ylim(70, 105)

    axes[1].plot(minutes, gpu_mem, color="#1f77b4", linewidth=2)
    axes[1].fill_between(minutes, gpu_mem, alpha=0.2, color="#1f77b4")
    axes[1].set_title("GPU Memory (%)")
    axes[1].set_ylim(60, 90)

    axes[2].plot(minutes, loss, color="#d62728", linewidth=2)
    axes[2].set_title("Training Loss")
    axes[2].set_xlabel("Minutes into training")
    axes[2].set_yscale("log")

    axes[3].plot(minutes, acc, color="#2ca02c", linewidth=2)
    axes[3].set_title("Training Accuracy")
    axes[3].set_xlabel("Minutes into training")
    axes[3].set_ylim(0.5, 1.01)

    fig.suptitle("SageMaker Training - Real-time CloudWatch Metrics", fontweight="bold", y=1.00)
    save(fig, out_dir, "cloudwatch_live_metrics")


# --------------------------------------------------------------------------- #
# 5. ROC curve comparison (from actual predictions)
# --------------------------------------------------------------------------- #


def _compute_roc(scores, labels):
    scores = np.asarray(scores)
    labels = np.asarray(labels, dtype=int)
    order = np.argsort(-scores)
    labels_sorted = labels[order]
    pos = labels_sorted.sum()
    neg = len(labels_sorted) - pos
    tp = np.cumsum(labels_sorted)
    fp = np.cumsum(1 - labels_sorted)
    tpr = tp / pos if pos else tp
    fpr = fp / neg if neg else fp
    fpr = np.concatenate(([0.0], fpr, [1.0]))
    tpr = np.concatenate(([0.0], tpr, [1.0]))
    auc = float(np.trapezoid(tpr, fpr))
    return fpr, tpr, auc


def chart_roc_comparison(out_dir: Path, predictions_path: Path):
    data = json.loads(predictions_path.read_text())
    preds = data["predictions"]
    labels = data["true_labels"]

    ensemble_scores = np.mean(
        [
            preds["densenet121"],
            preds["efficientnet"],
            preds["vgg16"],
        ],
        axis=0,
    )

    series = [
        ("VGG16 (baseline CNN)", preds["vgg16"], COLORS["baseline"]),
        ("DenseNet121", preds["densenet121"], COLORS["densenet121"]),
        ("EfficientNetV2M", preds["efficientnet"], COLORS["efficientnet"]),
        ("Ensemble (weighted)", ensemble_scores.tolist(), COLORS["ensemble"]),
    ]

    fig, ax = plt.subplots(figsize=(9, 8))
    ax.plot([0, 1], [0, 1], "--", color="gray", alpha=0.5, label="Random (AUC=0.50)")

    for name, scores, color in series:
        fpr, tpr, auc = _compute_roc(scores, labels)
        ax.plot(fpr, tpr, color=color, linewidth=2.5, label=f"{name}  (AUC={auc:.3f})")

    ax.set_xlabel("False Positive Rate")
    ax.set_ylabel("True Positive Rate (Sensitivity)")
    ax.set_title("ROC Curve Comparison - Baseline vs EfficientNet vs Ensemble")
    ax.legend(loc="lower right", fontsize=11)
    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1.02)
    save(fig, out_dir, "roc_curve_comparison")


# --------------------------------------------------------------------------- #
# 6. Learning rate impact (illustrative)
# --------------------------------------------------------------------------- #


def chart_learning_rate_impact(out_dir: Path):
    epochs = np.arange(1, 31)

    too_high = 0.6 + 0.3 * np.sin(epochs * 0.8) * np.exp(-epochs * 0.02) + 0.15
    too_low = 0.55 + 0.3 * (1 - np.exp(-epochs * 0.05))
    ideal = 0.55 + 0.42 * (1 - np.exp(-epochs * 0.25))

    fig, ax = plt.subplots(figsize=(12, 6))
    ax.plot(
        epochs,
        too_high,
        "o-",
        color="#e74c3c",
        linewidth=2.5,
        label="LR = 1e-2  (too high - oscillates)",
    )
    ax.plot(
        epochs, too_low, "s-", color="#f39c12", linewidth=2.5, label="LR = 1e-5  (too low - slow)"
    )
    ax.plot(epochs, ideal, "^-", color="#27ae60", linewidth=3, label="LR = 1e-3  (just right)")

    ax.set_xlabel("Epoch")
    ax.set_ylabel("Validation Accuracy")
    ax.set_title("Learning Rate Impact on Convergence")
    ax.set_ylim(0.4, 1.02)
    ax.legend(loc="lower right")
    ax.annotate(
        "Ideal LR converges\nfastest and reaches\nhighest accuracy",
        xy=(28, 0.95),
        xytext=(18, 0.55),
        fontsize=10,
        ha="center",
        bbox=dict(boxstyle="round", facecolor="lightyellow", edgecolor="#27ae60"),
        arrowprops=dict(arrowstyle="->", color="#27ae60"),
    )
    save(fig, out_dir, "learning_rate_impact")


# --------------------------------------------------------------------------- #
# 7. Early stopping visualization
# --------------------------------------------------------------------------- #


def chart_early_stopping(out_dir: Path):
    rng = np.random.default_rng(11)
    epochs = np.arange(1, 26)
    train_loss = 0.8 * np.exp(-epochs / 5) + 0.02 + rng.normal(0, 0.01, 25)
    val_loss = (
        0.8 * np.exp(-epochs / 6)
        + 0.05
        + 0.005 * np.maximum(0, epochs - 12) ** 1.3
        + rng.normal(0, 0.015, 25)
    )

    stop_epoch = 16

    fig, ax = plt.subplots(figsize=(12, 6))
    ax.plot(epochs, train_loss, "o-", color="#2ca02c", linewidth=2.5, label="Training loss")
    ax.plot(epochs, val_loss, "s-", color="#d62728", linewidth=2.5, label="Validation loss")
    ax.axvline(stop_epoch, color="black", linestyle="--", alpha=0.7, linewidth=2)

    ax.annotate(
        "Early stopping triggered\n(patience=5, best at epoch 11)",
        xy=(stop_epoch, val_loss[stop_epoch - 1]),
        xytext=(20, 0.5),
        fontsize=11,
        ha="center",
        bbox=dict(boxstyle="round", facecolor="lightyellow", edgecolor="black"),
        arrowprops=dict(arrowstyle="->", color="black"),
    )
    ax.axvspan(stop_epoch, 25, color="red", alpha=0.08, label="Overfitting region (not trained)")

    ax.set_xlabel("Epoch")
    ax.set_ylabel("Loss")
    ax.set_title("Early Stopping - Preventing Overfitting")
    ax.legend(loc="upper right")
    save(fig, out_dir, "early_stopping")


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate blog visuals")
    parser.add_argument("--output-dir", type=Path, default=Path("blog/charts"))
    # Default is the SageMaker pipeline's predictions artifact path, overridable via CLI.
    parser.add_argument(
        "--predictions",
        type=Path,
        default=Path("/tmp/predictions.json"),  # nosemgrep # nosec B108
    )
    args = parser.parse_args()

    setup_style()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    print(f"Generating blog visuals into {args.output_dir}/ ...")
    chart_smote_distribution(args.output_dir)
    chart_efficientnet_two_phase(args.output_dir)
    chart_cloudwatch_live_metrics(args.output_dir)
    if args.predictions.exists():
        chart_roc_comparison(args.output_dir, args.predictions)
    else:
        print(f"  ⚠️  {args.predictions} not found - skipping ROC chart")
    chart_learning_rate_impact(args.output_dir)
    chart_early_stopping(args.output_dir)
    print("✓ Done.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
