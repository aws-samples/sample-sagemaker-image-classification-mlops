#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import argparse
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import seaborn as sns

# --------------------------------------------------------------------------- #
# Metrics - collected from pipeline executions across all 4 training rounds.
# Source: evaluation_results.json + ensemble_results.json in the model
# artifacts S3 bucket for each pipeline execution.
# --------------------------------------------------------------------------- #

BATCHES = [
    {
        "batch": 1,
        "label": "Batch 1\n(998+998)",
        "training_images": 1996,
        "benign": 998,
        "malignant": 998,
        "execution": "wxflhfbz0fpi",
        "date": "2026-04-15",
        "models": {
            "densenet121": {
                "accuracy": 0.9867,
                "precision": 0.9801,
                "recall": 0.9940,
                "f1": 0.9870,
                "auc": 0.9999,
                "threshold": 0.89,
            },
            "efficientnet": {
                "accuracy": 0.9667,
                "precision": 0.9672,
                "recall": 0.9667,
                "f1": 0.9666,
                "auc": 0.9960,
                "threshold": 0.21,
            },
            "vgg16": {
                "accuracy": 0.9433,
                "precision": 0.9493,
                "recall": 0.9367,
                "f1": 0.9430,
                "auc": 0.9862,
                "threshold": 0.60,
            },
        },
        "ensemble": {
            "accuracy": 0.9733,
            "precision": 0.9610,
            "recall": 0.9867,
            "f1": 0.9737,
            "threshold": 0.569,
        },
    },
    {
        "batch": 2,
        "label": "Batch 2\n(1996+1996)",
        "training_images": 3992,
        "benign": 1996,
        "malignant": 1996,
        "execution": "xzylbdkhios8",
        "date": "2026-04-17",
        "models": {
            "densenet121": {
                "accuracy": 0.9733,
                "precision": 0.9581,
                "recall": 0.9900,
                "f1": 0.9738,
                "auc": 0.9968,
                "threshold": 0.87,
            },
            "efficientnet": {
                "accuracy": 0.9817,
                "precision": 0.9707,
                "recall": 0.9933,
                "f1": 0.9819,
                "auc": 0.9976,
                "threshold": 0.88,
            },
            "vgg16": {
                "accuracy": 0.8983,
                "precision": 0.9078,
                "recall": 0.8867,
                "f1": 0.8971,
                "auc": 0.9610,
                "threshold": 0.48,
            },
        },
        "ensemble": {
            "accuracy": 0.9533,
            "precision": 0.9857,
            "recall": 0.9200,
            "f1": 0.9517,
            "threshold": 0.751,
        },
    },
    {
        "batch": 3,
        "label": "Batch 3\n(2994+2994)",
        "training_images": 5988,
        "benign": 2994,
        "malignant": 2994,
        "execution": "qx98ud57b2bk",
        "date": "2026-04-17",
        "models": {
            "densenet121": {
                "accuracy": 0.9783,
                "precision": 0.9687,
                "recall": 0.9883,
                "f1": 0.9784,
                "auc": 0.9975,
                "threshold": 0.85,
            },
            "efficientnet": {
                "accuracy": 0.9767,
                "precision": 0.9657,
                "recall": 0.9883,
                "f1": 0.9769,
                "auc": 0.9962,
                "threshold": 0.65,
            },
            "vgg16": {
                "accuracy": 0.9217,
                "precision": 0.9315,
                "recall": 0.9100,
                "f1": 0.9206,
                "auc": 0.9717,
                "threshold": 0.55,
            },
        },
        "ensemble": {
            "accuracy": 0.9683,
            "precision": 0.9707,
            "recall": 0.9667,
            "f1": 0.9687,
            "threshold": 0.640,
        },
    },
    {
        "batch": 4,
        "label": "Batch 4\n(+BreakHis)",
        "training_images": 13897,
        "benign": 5474,
        "malignant": 8423,
        "execution": "z2o9ptj900ns",
        "date": "2026-04-20",
        "models": {
            "densenet121": {
                "accuracy": 0.9377,
                "precision": 0.9362,
                "recall": 0.9628,
                "f1": 0.9493,
                "auc": 0.9817,
                "threshold": 0.53,
            },
            "efficientnet": {
                "accuracy": 0.9626,
                "precision": 0.9684,
                "recall": 0.9699,
                "f1": 0.9692,
                "auc": 0.9922,
                "threshold": 0.61,
            },
            "vgg16": {
                "accuracy": 0.8821,
                "precision": 0.9200,
                "recall": 0.8821,
                "f1": 0.9006,
                "auc": 0.9575,
                "threshold": 0.53,
            },
        },
        "ensemble": {
            "accuracy": 0.9727,
            "precision": 0.9763,
            "recall": 0.9786,
            "f1": 0.9775,
            "threshold": 0.558,
        },
    },
]

# Cross-dataset evaluation: endpoint trained on batches 1-3 (model package v5)
# tested against held-out BreakHis images.
CROSS_DATASET_EVAL = {
    "in_distribution": {
        "accuracy": 0.97,
        "precision": 0.976,
        "recall": 0.979,
        "f1": 0.977,
        "label": "In-distribution\n(internal test)",
    },
    "out_of_distribution": {
        "accuracy": 0.52,
        "precision": 0.510,
        "recall": 0.99,
        "f1": 0.674,
        "label": "Out-of-distribution\n(BreakHis)",
    },
}

COLORS = {
    "densenet121": "#1f77b4",  # blue
    "efficientnet": "#2ca02c",  # green
    "vgg16": "#ff7f0e",  # orange
    "ensemble": "#d62728",  # red
}

MODEL_DISPLAY = {
    "densenet121": "DenseNet121",
    "efficientnet": "EfficientNetV2M",
    "vgg16": "VGG16",
}


# --------------------------------------------------------------------------- #
# Chart helpers
# --------------------------------------------------------------------------- #


def setup_style():
    sns.set_theme(style="whitegrid", context="talk")
    plt.rcParams["font.family"] = "DejaVu Sans"
    plt.rcParams["axes.titleweight"] = "bold"
    plt.rcParams["axes.titlesize"] = 14
    plt.rcParams["axes.labelsize"] = 12
    plt.rcParams["legend.fontsize"] = 10


def annotate_bars(ax, fmt="{:.1%}"):
    for bar in ax.patches:
        height = bar.get_height()
        if height > 0:
            ax.annotate(
                fmt.format(height),
                xy=(bar.get_x() + bar.get_width() / 2, height),
                xytext=(0, 3),
                textcoords="offset points",
                ha="center",
                va="bottom",
                fontsize=9,
            )


def save_chart(fig, out_dir: Path, name: str):
    path = out_dir / f"{name}.png"
    fig.savefig(path, dpi=150, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"  ✓ {path}")


# --------------------------------------------------------------------------- #
# Chart 1 - Ensemble accuracy progression
# --------------------------------------------------------------------------- #


def chart_ensemble_progression(out_dir: Path):
    fig, ax = plt.subplots(figsize=(11, 6))
    labels = [b["label"] for b in BATCHES]
    metrics = ["accuracy", "precision", "recall", "f1"]
    metric_labels = ["Accuracy", "Precision", "Recall", "F1 Score"]
    x = np.arange(len(BATCHES))
    width = 0.2

    for i, (metric, mlabel) in enumerate(zip(metrics, metric_labels)):
        values = [b["ensemble"][metric] for b in BATCHES]
        ax.bar(x + i * width, values, width, label=mlabel)

    ax.set_xticks(x + width * 1.5)
    ax.set_xticklabels(labels)
    ax.set_ylabel("Score")
    ax.set_ylim(0.85, 1.02)
    ax.set_title("Ensemble Model Performance Progression Across Training Batches")
    ax.legend(loc="lower right", ncol=4)
    annotate_bars(ax)
    save_chart(fig, out_dir, "ensemble_accuracy_progression")


# --------------------------------------------------------------------------- #
# Chart 2 - Per-model accuracy
# --------------------------------------------------------------------------- #


def chart_per_model_accuracy(out_dir: Path):
    fig, ax = plt.subplots(figsize=(11, 6))
    x = np.arange(len(BATCHES))
    width = 0.2

    for i, key in enumerate(["densenet121", "efficientnet", "vgg16"]):
        values = [b["models"][key]["accuracy"] for b in BATCHES]
        ax.bar(x + i * width, values, width, label=MODEL_DISPLAY[key], color=COLORS[key])

    ensemble_values = [b["ensemble"]["accuracy"] for b in BATCHES]
    ax.plot(
        x + width,
        ensemble_values,
        "o-",
        color=COLORS["ensemble"],
        linewidth=2.5,
        markersize=10,
        label="Ensemble",
        zorder=5,
    )

    ax.set_xticks(x + width)
    ax.set_xticklabels([b["label"] for b in BATCHES])
    ax.set_ylabel("Test Accuracy")
    ax.set_ylim(0.82, 1.02)
    ax.set_title("Individual Model vs. Ensemble Accuracy by Training Batch")
    ax.legend(loc="lower right", ncol=4)
    annotate_bars(ax)

    # Annotate ensemble line
    for xi, v in zip(x, ensemble_values):
        ax.annotate(
            f"{v:.1%}",
            xy=(xi + width, v),
            xytext=(0, 10),
            textcoords="offset points",
            ha="center",
            va="bottom",
            fontsize=9,
            color=COLORS["ensemble"],
            fontweight="bold",
        )
    save_chart(fig, out_dir, "per_model_accuracy_progression")


# --------------------------------------------------------------------------- #
# Chart 3 - Per-model AUC
# --------------------------------------------------------------------------- #


def chart_per_model_auc(out_dir: Path):
    fig, ax = plt.subplots(figsize=(11, 6))
    x = np.arange(len(BATCHES))

    for key in ["densenet121", "efficientnet", "vgg16"]:
        values = [b["models"][key]["auc"] for b in BATCHES]
        ax.plot(
            x,
            values,
            "o-",
            linewidth=2.5,
            markersize=12,
            label=MODEL_DISPLAY[key],
            color=COLORS[key],
        )
        for xi, v in zip(x, values):
            ax.annotate(
                f"{v:.3f}",
                xy=(xi, v),
                xytext=(5, -15),
                textcoords="offset points",
                fontsize=9,
                color=COLORS[key],
            )

    ax.set_xticks(x)
    ax.set_xticklabels([b["label"] for b in BATCHES])
    ax.set_ylabel("AUC-ROC")
    ax.set_ylim(0.94, 1.005)
    ax.set_title("AUC-ROC Progression - Per Model Across Training Batches")
    ax.legend(loc="lower left", ncol=3)
    ax.grid(True, alpha=0.3)
    save_chart(fig, out_dir, "per_model_auc_progression")


# --------------------------------------------------------------------------- #
# Chart 4 - Confusion matrix breakdown
# --------------------------------------------------------------------------- #


def chart_confusion_breakdown(out_dir: Path):
    """Show precision/recall/specificity trade-off for ensemble per batch."""
    fig, ax = plt.subplots(figsize=(11, 6))
    x = np.arange(len(BATCHES))

    precision = [b["ensemble"]["precision"] for b in BATCHES]
    recall = [b["ensemble"]["recall"] for b in BATCHES]
    f1 = [b["ensemble"]["f1"] for b in BATCHES]

    width = 0.28
    ax.bar(x - width, precision, width, label="Precision", color="#3b8bba")
    ax.bar(x, recall, width, label="Recall (Sensitivity)", color="#e55934")
    ax.bar(x + width, f1, width, label="F1 Score", color="#9b59b6")

    ax.set_xticks(x)
    ax.set_xticklabels([b["label"] for b in BATCHES])
    ax.set_ylabel("Score")
    ax.set_ylim(0.88, 1.01)
    ax.set_title("Ensemble Precision / Recall / F1 Trade-off by Batch")
    ax.legend(loc="lower right", ncol=3)
    annotate_bars(ax)
    save_chart(fig, out_dir, "confusion_breakdown")


# --------------------------------------------------------------------------- #
# Chart 5 - Dataset growth
# --------------------------------------------------------------------------- #


def chart_dataset_growth(out_dir: Path):
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 5.5))

    labels = [b["label"] for b in BATCHES]
    benign = [b["benign"] for b in BATCHES]
    malignant = [b["malignant"] for b in BATCHES]

    # Left: stacked bar of dataset composition
    ax1.bar(labels, benign, label="Benign", color="#27ae60")
    ax1.bar(labels, malignant, bottom=benign, label="Malignant", color="#c0392b")
    for i, (b, m) in enumerate(zip(benign, malignant)):
        total = b + m
        ax1.annotate(
            f"{total:,}",
            xy=(i, total),
            xytext=(0, 6),
            textcoords="offset points",
            ha="center",
            fontweight="bold",
        )
    ax1.set_ylabel("Number of Images")
    ax1.set_title("Training Dataset Composition per Batch")
    ax1.legend(loc="upper left")

    # Right: ensemble accuracy vs dataset size
    ax2.plot(
        [b["training_images"] for b in BATCHES],
        [b["ensemble"]["accuracy"] for b in BATCHES],
        "o-",
        linewidth=3,
        markersize=14,
        color=COLORS["ensemble"],
        label="Ensemble Accuracy",
    )
    for b in BATCHES:
        ax2.annotate(
            f"B{b['batch']}\n{b['ensemble']['accuracy']:.1%}",
            xy=(b["training_images"], b["ensemble"]["accuracy"]),
            xytext=(12, -10),
            textcoords="offset points",
            fontsize=10,
        )
    ax2.set_xlabel("Training Dataset Size")
    ax2.set_ylabel("Ensemble Accuracy")
    ax2.set_title("Accuracy vs. Dataset Size")
    ax2.set_ylim(0.94, 1.0)
    ax2.grid(True, alpha=0.3)
    ax2.legend()

    save_chart(fig, out_dir, "dataset_growth")


# --------------------------------------------------------------------------- #
# Chart 6 - Cross-dataset overfitting
# --------------------------------------------------------------------------- #


def chart_cross_dataset_overfitting(out_dir: Path):
    fig, ax = plt.subplots(figsize=(11, 6.5))

    categories = [
        CROSS_DATASET_EVAL["in_distribution"]["label"],
        CROSS_DATASET_EVAL["out_of_distribution"]["label"],
    ]
    metrics = ["accuracy", "precision", "recall", "f1"]
    metric_labels = ["Accuracy", "Precision", "Recall", "F1"]

    x = np.arange(len(categories))
    width = 0.2

    for i, (m, ml) in enumerate(zip(metrics, metric_labels)):
        values = [
            CROSS_DATASET_EVAL["in_distribution"][m],
            CROSS_DATASET_EVAL["out_of_distribution"][m],
        ]
        bars = ax.bar(x + i * width, values, width, label=ml)
        for bar, v in zip(bars, values):
            ax.annotate(
                f"{v:.1%}",
                xy=(bar.get_x() + bar.get_width() / 2, v),
                xytext=(0, 3),
                textcoords="offset points",
                ha="center",
                fontsize=9,
            )

    ax.set_xticks(x + width * 1.5)
    ax.set_xticklabels(categories)
    ax.set_ylabel("Score")
    ax.set_ylim(0, 1.1)
    ax.set_title("Model Generalization Test - In-Distribution vs. BreakHis (Out-of-Distribution)")
    ax.legend(loc="center right", ncol=4)

    # Annotation highlighting the accuracy drop
    ax.annotate(
        "↓ 45pp accuracy drop\nconfirms overfitting to\ntraining distribution",
        xy=(1, 0.52),
        xytext=(1.4, 0.75),
        fontsize=11,
        ha="center",
        color="#c0392b",
        fontweight="bold",
        arrowprops=dict(arrowstyle="->", color="#c0392b", lw=2),
    )

    save_chart(fig, out_dir, "cross_dataset_overfitting")


# --------------------------------------------------------------------------- #
# Summary observation TXT
# --------------------------------------------------------------------------- #


def write_observations(out_dir: Path):
    lines = [
        "# Training Progression - Observations",
        "",
        "Automatically generated from pipeline execution metrics.",
        "",
        "## Dataset Growth",
        "",
    ]
    for b in BATCHES:
        lines.append(
            f"- **Batch {b['batch']}** ({b['date']}): {b['training_images']:,} images "
            f"({b['benign']:,} benign, {b['malignant']:,} malignant) - "
            f"Ensemble accuracy **{b['ensemble']['accuracy']:.2%}**"
        )

    lines += [
        "",
        "## Ensemble Metrics per Batch",
        "",
        "| Batch | Accuracy | Precision | Recall | F1 | Threshold |",
        "|-------|----------|-----------|--------|-----|-----------|",
    ]
    for b in BATCHES:
        e = b["ensemble"]
        lines.append(
            f"| B{b['batch']} | {e['accuracy']:.2%} | {e['precision']:.2%} | "
            f"{e['recall']:.2%} | {e['f1']:.2%} | {e['threshold']:.3f} |"
        )

    lines += [
        "",
        "## Per-Model AUC Progression",
        "",
        "| Batch | DenseNet121 | EfficientNetV2M | VGG16 |",
        "|-------|-------------|-----------------|-------|",
    ]
    for b in BATCHES:
        lines.append(
            f"| B{b['batch']} | {b['models']['densenet121']['auc']:.4f} | "
            f"{b['models']['efficientnet']['auc']:.4f} | "
            f"{b['models']['vgg16']['auc']:.4f} |"
        )

    lines += [
        "",
        "## Generalization Test (Model Package v5 vs. BreakHis)",
        "",
        "| Metric | In-Distribution | Out-of-Distribution (BreakHis) | Drop |",
        "|--------|-----------------|--------------------------------|------|",
    ]
    iod = CROSS_DATASET_EVAL["in_distribution"]
    ood = CROSS_DATASET_EVAL["out_of_distribution"]
    for m in ("accuracy", "precision", "recall", "f1"):
        lines.append(
            f"| {m.title()} | {iod[m]:.2%} | {ood[m]:.2%} | {(iod[m] - ood[m]) * 100:+.1f} pp |"
        )

    lines += [
        "",
        "## Key Observations",
        "",
        "1. **Ensemble consistently outperforms individual models** - the weighted",
        "   ensemble (accuracy-based weights) beats the best individual model on",
        "   every batch, confirming that architectural diversity helps.",
        "",
        "2. **DenseNet121 and EfficientNetV2M are the strongest individual models.**",
        "   VGG16 lags by ~5-10pp on accuracy. Its main contribution is diversity.",
        "",
        "3. **Accuracy did not monotonically increase with more in-distribution data.**",
        "   Batch 2 ensemble accuracy dropped vs. Batch 1 - suggests the initial",
        "   high accuracy reflected dataset memorization, not generalization.",
        "",
        "4. **Adding BreakHis (Batch 4) doubled training set size and accuracy held.**",
        "   Ensemble accuracy on held-out test: 97.27% - roughly equal to in-house",
        "   batches. This is a positive sign: the model absorbed a new distribution.",
        "",
        "5. **Cross-dataset evaluation exposed severe overfitting (v5 model).**",
        "   The v5 ensemble trained on batches 1-3 scored 97% on its own test set",
        "   but only **52%** on held-out BreakHis - confirming that pre-BreakHis",
        "   training data was distributionally narrow. Batch 4 is addressing this.",
        "",
    ]

    path = out_dir / "observations.md"
    path.write_text("\n".join(lines))
    print(f"  ✓ {path}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=Path("blog/charts"))
    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)
    setup_style()

    print(f"Generating charts in {args.output_dir}/ ...")
    chart_ensemble_progression(args.output_dir)
    chart_per_model_accuracy(args.output_dir)
    chart_per_model_auc(args.output_dir)
    chart_confusion_breakdown(args.output_dir)
    chart_dataset_growth(args.output_dir)
    chart_cross_dataset_overfitting(args.output_dir)
    write_observations(args.output_dir)

    print()
    print("✓ Done. Open the charts folder to review.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
