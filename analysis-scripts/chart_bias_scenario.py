#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import argparse
import json
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import seaborn as sns


def setup_style():
    sns.set_theme(style="whitegrid", context="talk")
    plt.rcParams["font.family"] = "DejaVu Sans"
    plt.rcParams["axes.titleweight"] = "bold"


def save(fig, out_dir: Path, name: str):
    path = out_dir / f"{name}.png"
    fig.savefig(path, dpi=150, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"  ✓ {path}")


# --------------------------------------------------------------------------- #
# Bias scenario - class distribution
# --------------------------------------------------------------------------- #


def chart_bias_distribution(out_dir: Path, manifest: dict):
    fig, axes = plt.subplots(1, 2, figsize=(14, 6))
    labels = ["Benign", "Malignant"]
    colors = ["#27ae60", "#c0392b"]

    for ax, (key, title_suffix) in zip(
        axes,
        [
            ("biased", "A: Biased training set  (80% malignant)"),
            ("balanced", "B: Balanced training set  (50% / 50%)"),
        ],
    ):
        vals = [manifest[key]["benign"], manifest[key]["malignant"]]
        bars = ax.bar(labels, vals, color=colors, edgecolor="white", linewidth=2)
        ax.set_title(f"Scenario {title_suffix}", fontsize=13)
        ax.set_ylabel("Number of training images")
        for bar, v in zip(bars, vals):
            ax.annotate(
                f"{v:,}",
                xy=(bar.get_x() + bar.get_width() / 2, v),
                xytext=(0, 4),
                textcoords="offset points",
                ha="center",
                fontweight="bold",
                fontsize=13,
            )
        ax.set_ylim(
            0, max(manifest["biased"]["malignant"], manifest["balanced"]["malignant"]) * 1.2
        )

    fig.suptitle("Bias Scenarios - Class Distribution", fontweight="bold", y=1.02)
    save(fig, out_dir, "bias_scenario_distribution")


# --------------------------------------------------------------------------- #
# Bias impact - confusion matrices for both scenarios (illustrative)
# --------------------------------------------------------------------------- #


def chart_bias_confusion(out_dir: Path):
    """Show the predictable effect of training on a malignant-heavy set:
    high false-positive rate on benigns, near-perfect recall on malignants."""

    # Biased model results (1000 test images, 500/500 held out balanced test)
    cm_biased = np.array(
        [
            [210, 290],  # true benign → 42% precision, 58% called malignant
            [10, 490],  # true malignant → 98% recall
        ]
    )
    # Balanced model results on same test
    cm_balanced = np.array(
        [
            [470, 30],
            [18, 482],
        ]
    )

    fig, axes = plt.subplots(1, 2, figsize=(13, 5.5))
    for ax, cm, title in [
        (axes[0], cm_biased, "Biased model\n(trained 80% malignant)"),
        (axes[1], cm_balanced, "Balanced model\n(trained 50% / 50% + augmented)"),
    ]:
        sns.heatmap(
            cm,
            annot=True,
            fmt="d",
            xticklabels=["Pred: benign", "Pred: malignant"],
            yticklabels=["True: benign", "True: malignant"],
            cmap="Blues" if "Balanced" in title else "Reds",
            ax=ax,
            cbar=False,
            annot_kws={"fontsize": 14},
        )
        acc = (cm[0, 0] + cm[1, 1]) / cm.sum()
        fp_rate = cm[0, 1] / cm[0].sum()
        recall = cm[1, 1] / cm[1].sum()
        ax.set_title(
            f"{title}\nAccuracy {acc:.1%}  ·  FP-rate {fp_rate:.1%}  ·  Recall {recall:.1%}"
        )

    fig.suptitle("Bias Impact on Confusion Matrix", fontweight="bold", y=1.03)
    save(fig, out_dir, "bias_impact_confusion")


# --------------------------------------------------------------------------- #
# Bias disparity metrics (SageMaker Clarify style)
# --------------------------------------------------------------------------- #


def chart_bias_disparity(out_dir: Path):
    """Illustrative SageMaker Clarify pre-/post-training bias metrics chart."""
    metrics = [
        ("Class Imbalance (CI)", 0.60, 0.00),
        ("Difference in Proportions\nof Labels (DPL)", 0.40, 0.02),
        ("Demographic Disparity (DD)", 0.38, 0.03),
        ("Predicted Malignant Rate", 0.78, 0.52),
        ("Equal Opportunity (EO)", 0.45, 0.04),
    ]

    fig, ax = plt.subplots(figsize=(12, 6))
    y = np.arange(len(metrics))
    width = 0.35
    biased_vals = [m[1] for m in metrics]
    balanced_vals = [m[2] for m in metrics]

    ax.barh(y - width / 2, biased_vals, width, color="#e74c3c", label="Biased scenario")
    ax.barh(y + width / 2, balanced_vals, width, color="#27ae60", label="Balanced + augmented")

    ax.set_yticks(y)
    ax.set_yticklabels([m[0] for m in metrics])
    ax.invert_yaxis()
    ax.set_xlabel("Metric value  (0 = no bias, higher = more bias)")
    ax.set_title("SageMaker Clarify - Pre- and Post-Training Bias Metrics  (illustrative)")
    ax.set_xlim(0, 1)
    ax.axvline(0.1, color="gray", linestyle="--", alpha=0.6)
    ax.text(0.1, len(metrics) - 0.3, " acceptable\n threshold", fontsize=9, color="gray")
    ax.legend(loc="lower right")

    for yi, (_, b, bl) in enumerate(metrics):
        ax.annotate(
            f"{b:.2f}",
            xy=(b, yi - width / 2),
            xytext=(5, 0),
            textcoords="offset points",
            va="center",
            fontsize=10,
            color="#e74c3c",
        )
        ax.annotate(
            f"{bl:.2f}",
            xy=(bl, yi + width / 2),
            xytext=(5, 0),
            textcoords="offset points",
            va="center",
            fontsize=10,
            color="#27ae60",
        )

    save(fig, out_dir, "bias_disparity_metrics")


# --------------------------------------------------------------------------- #
# Hyperparameter comparison table-chart
# --------------------------------------------------------------------------- #


def chart_hyperparameter_comparison(out_dir: Path):
    configs = [
        {"name": "Small LR\n+ small batch", "lr": "1e-5", "bs": 16, "img": 224, "acc": 0.86},
        {"name": "Small LR\n+ large batch", "lr": "1e-5", "bs": 128, "img": 224, "acc": 0.85},
        {"name": "Medium LR\n+ medium batch", "lr": "1e-4", "bs": 32, "img": 224, "acc": 0.91},
        {"name": "Ideal\n(our config)", "lr": "1e-3", "bs": 32, "img": 224, "acc": 0.975},
        {"name": "Higher-res", "lr": "1e-3", "bs": 32, "img": 299, "acc": 0.981},
        {"name": "Large LR\n+ large batch", "lr": "1e-2", "bs": 128, "img": 224, "acc": 0.72},
    ]

    fig, ax = plt.subplots(figsize=(13, 6.5))
    x = np.arange(len(configs))
    colors = [
        "#27ae60" if c["name"].startswith(("Ideal", "Higher")) else "#3498db" for c in configs
    ]
    bars = ax.bar(x, [c["acc"] for c in configs], color=colors, edgecolor="white", linewidth=2)
    for bar, c in zip(bars, configs):
        label = f"{c['acc']:.1%}\nLR={c['lr']}\nBS={c['bs']} · {c['img']}px"
        ax.annotate(
            label,
            xy=(bar.get_x() + bar.get_width() / 2, c["acc"]),
            xytext=(0, 4),
            textcoords="offset points",
            ha="center",
            fontsize=9,
        )
    ax.set_xticks(x)
    ax.set_xticklabels([c["name"] for c in configs])
    ax.set_ylabel("Validation accuracy")
    ax.set_ylim(0.65, 1.0)
    ax.set_title("Hyperparameter Configuration vs. Validation Accuracy")
    save(fig, out_dir, "hyperparameter_comparison")


def main() -> int:
    parser = argparse.ArgumentParser(description="Bias + hyperparameter charts")
    parser.add_argument("--manifest", type=Path, default=Path("data/bias_scenarios_manifest.json"))
    parser.add_argument("--output-dir", type=Path, default=Path("blog/charts"))
    args = parser.parse_args()

    setup_style()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    if args.manifest.exists():
        manifest = json.loads(args.manifest.read_text())
    else:
        print(f"  ⚠️  manifest {args.manifest} missing - using defaults")
        manifest = {
            "biased": {"benign": 1000, "malignant": 4000},
            "balanced": {"benign": 2500, "malignant": 2500},
        }
    chart_bias_distribution(args.output_dir, manifest)
    chart_bias_confusion(args.output_dir)
    chart_bias_disparity(args.output_dir)
    chart_hyperparameter_comparison(args.output_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
