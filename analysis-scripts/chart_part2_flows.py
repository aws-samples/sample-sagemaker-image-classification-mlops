#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib.patches import Circle, FancyArrowPatch, FancyBboxPatch

# --------------------------------------------------------------------------- #
# Visual language - sampled from the original Part 2 Figure 1
# --------------------------------------------------------------------------- #

BLUE = "#4a90e2"  # stage boxes
ORANGE = "#ff9500"  # quality gate + numbered step circles
GREEN = "#2ecc40"  # pass branch / deploy
RED = "#e74c3c"  # fail branch / reject-retrain
TEXT = "#1a1a1a"
ANNOT = "#555555"  # gray arrow labels
ARROW = "#000000"  # default arrow stroke
WHITE = "#ffffff"

OUT_DIR = Path("blog_docs/part2")


def setup_style():
    plt.rcParams["font.family"] = "DejaVu Sans"
    plt.rcParams["axes.titleweight"] = "bold"


def stage_box(ax, center, label, fill=BLUE, width=1.9, height=1.1, fontsize=11):
    """Rounded box with white bold label centered."""
    x, y = center
    patch = FancyBboxPatch(
        (x - width / 2, y - height / 2),
        width,
        height,
        boxstyle="round,pad=0.02,rounding_size=0.08",
        linewidth=1.4,
        edgecolor=fill,
        facecolor=fill,
        zorder=2,
    )
    ax.add_patch(patch)
    ax.text(
        x,
        y,
        label,
        ha="center",
        va="center",
        color=WHITE,
        fontsize=fontsize,
        fontweight="bold",
        zorder=3,
    )


def number_circle(ax, center, n, fill=ORANGE, radius=0.16):
    """Small numbered circle (step index) above a box."""
    x, y = center
    c = Circle((x, y), radius, facecolor=fill, edgecolor=fill, zorder=4)
    ax.add_patch(c)
    ax.text(
        x,
        y,
        str(n),
        ha="center",
        va="center",
        color=WHITE,
        fontsize=10,
        fontweight="bold",
        zorder=5,
    )


def arrow(
    ax,
    start,
    end,
    color=ARROW,
    label=None,
    label_color=ANNOT,
    label_fontsize=9,
    label_offset=(0, 0.25),
    style="solid",
    lw=1.8,
):
    ls = "-" if style == "solid" else "--"
    a = FancyArrowPatch(
        start,
        end,
        arrowstyle="-|>",
        mutation_scale=14,
        linewidth=lw,
        linestyle=ls,
        color=color,
        zorder=1,
        shrinkA=0,
        shrinkB=0,
    )
    ax.add_patch(a)
    if label:
        mx = (start[0] + end[0]) / 2 + label_offset[0]
        my = (start[1] + end[1]) / 2 + label_offset[1]
        ax.text(
            mx,
            my,
            label,
            ha="center",
            va="center",
            color=label_color,
            fontsize=label_fontsize,
            fontweight="bold" if label_color in (GREEN, RED) else "normal",
        )


def save(fig, name: str):
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    path = OUT_DIR / f"{name}.png"
    fig.savefig(path, dpi=200, bbox_inches="tight", facecolor=WHITE)
    plt.close(fig)
    print(f"  ✓ {path}")


# --------------------------------------------------------------------------- #
# Figure 1: Optimization decision flow
#
# Baseline Model → Transfer Learning → Hyperparameter Optimization → Clinical
# Quality Gates → (Pass) Deploy / (Fail) Reject + Retrain → loops to HPO.
#
# Arrow annotations:
#   1→2: "Too little data / to learn from scratch"
#   2→3: "Features need / adaptation to / medical domain"
#   3→4: "Configuration / not optimized"
# --------------------------------------------------------------------------- #


def figure_1_optimization_decision_flow():
    fig, ax = plt.subplots(figsize=(18, 5))
    ax.set_xlim(0, 18)
    ax.set_ylim(0, 5)
    ax.axis("off")

    y = 2.2

    # Main stages
    stage_box(ax, (1.5, y), "Baseline\nModel", BLUE)
    stage_box(ax, (5.5, y), "Transfer\nLearning", BLUE)
    stage_box(ax, (10.0, y), "Hyperparameter\nOptimization", BLUE, width=2.3)
    stage_box(ax, (14.5, y), "Clinical\nQuality Gates", ORANGE, width=2.2)

    # Numbered circles above
    number_circle(ax, (1.5, y + 0.85), 1)
    number_circle(ax, (5.5, y + 0.85), 2)
    number_circle(ax, (10.0, y + 0.85), 3)
    number_circle(ax, (14.5, y + 0.85), 4)

    # Stage → Stage arrows with annotations
    arrow(
        ax,
        (2.45, y),
        (4.55, y),
        label="Too little data\nto learn from scratch",
        label_offset=(0, 0.45),
    )
    arrow(
        ax,
        (6.45, y),
        (8.85, y),
        label="Features need\nadaptation to\nmedical domain",
        label_offset=(0, 0.55),
    )
    arrow(ax, (11.15, y), (13.4, y), label="Configuration\nnot optimized", label_offset=(0, 0.45))

    # Pass branch - top right
    deploy_xy = (17.2, 3.4)
    stage_box(ax, deploy_xy, "Deploy", GREEN, width=1.5, height=0.95)
    arrow(
        ax,
        (15.4, y + 0.3),
        (deploy_xy[0] - 0.75, deploy_xy[1] - 0.35),
        color=GREEN,
        label="Pass",
        label_color=GREEN,
        label_offset=(-0.3, 0.2),
        lw=2.2,
    )

    # Fail branch - bottom right → loops back to HPO (node 3)
    reject_xy = (17.2, 0.9)
    stage_box(ax, reject_xy, "Reject +\nRetrain", RED, width=1.5, height=0.95)
    arrow(
        ax,
        (15.4, y - 0.3),
        (reject_xy[0] - 0.75, reject_xy[1] + 0.35),
        color=RED,
        label="Fail",
        label_color=RED,
        label_offset=(-0.3, -0.25),
        lw=2.2,
    )

    # Red retrain loop: reject box down then left then up to node 3
    loop_arrow = FancyArrowPatch(
        (reject_xy[0] - 0.75, reject_xy[1]),
        (10.0, y - 0.65),
        connectionstyle="arc3,rad=-0.25",
        arrowstyle="-|>",
        mutation_scale=16,
        linewidth=2.0,
        color=RED,
        zorder=1,
    )
    ax.add_patch(loop_arrow)

    return fig


# --------------------------------------------------------------------------- #
# Figure 2: Two-phase training within a single SageMaker Training Job
#
# Boxes (left → right):
#   1. Pre-trained Backbone  - blue  - "ImageNet weights / (edges, textures, shapes)"
#   2. Phase 1 / Frozen Backbone  - green - "Train classification head / LR = 0.001 / Backbone locked"
#   3. Phase 2 / Unfreeze Top Layers  - red - "Fine-tune backbone / LR = 0.00001 (100x lower) / Top 30 layers unfreeze"
#   4. Trained Model  - dark gray - "Both phases complete / Single training job / Full history in CloudWatch"
#   5. Model Registry  - orange - "PendingManualApproval / Clinical review"
# Numbered orange circles above each of the 5 boxes.
# Gray annotation under phase 1 & 2: "Single SageMaker Training Job - no intermediate session reloads"
# Bottom gray note: "Phase 1 weights flow directly into Phase 2 - no saving to disk, no reloading, no risk of mismatch"
# --------------------------------------------------------------------------- #


def figure_2_two_phase_training():
    fig, ax = plt.subplots(figsize=(18, 5.5))
    ax.set_xlim(0, 18)
    ax.set_ylim(0, 5.5)
    ax.axis("off")

    y = 2.9

    PHASE1_GREEN = "#2ecc40"
    PHASE2_RED = "#e74c3c"
    DARK = "#3a3a3a"

    # 5 boxes across
    xs = [1.8, 5.2, 8.8, 12.4, 15.9]
    widths = [1.9, 2.1, 2.3, 1.9, 1.9]

    stage_box(ax, (xs[0], y), "Pre-trained\nBackbone", BLUE, width=widths[0])
    stage_box(ax, (xs[1], y), "Phase 1\nFrozen Backbone", PHASE1_GREEN, width=widths[1])
    stage_box(ax, (xs[2], y), "Phase 2\nUnfreeze Top Layers", PHASE2_RED, width=widths[2])
    stage_box(ax, (xs[3], y), "Trained\nModel", DARK, width=widths[3])
    stage_box(ax, (xs[4], y), "Model\nRegistry", ORANGE, width=widths[4])

    for i, x in enumerate(xs, start=1):
        number_circle(ax, (x, y + 0.85), i)

    # Sub-labels inside / under each box
    labels_under = [
        (xs[0], y - 0.85, "ImageNet weights\n(edges, textures, shapes)"),
        (xs[1], y - 0.85, "Train classification head\nLR = 0.001\nBackbone locked"),
        (xs[2], y - 0.85, "Fine-tune backbone\nLR = 0.00001 (100× lower)\nTop 30 layers unfreeze"),
        (xs[3], y - 0.85, "Both phases complete\nSingle training job\nFull history in CloudWatch"),
        (xs[4], y - 0.85, "PendingManualApproval\nClinical review"),
    ]
    for x, ly, text in labels_under:
        ax.text(x, ly, text, ha="center", va="center", fontsize=9, color=TEXT)

    # Arrows between boxes
    for i in range(len(xs) - 1):
        sx = xs[i] + widths[i] / 2
        ex = xs[i + 1] - widths[i + 1] / 2
        arrow(ax, (sx, y), (ex, y))

    # Orange bracket under Phase 1 + Phase 2 with annotation
    bracket_y = 1.3
    bracket_left = xs[1] - widths[1] / 2
    bracket_right = xs[2] + widths[2] / 2
    ax.plot(
        [bracket_left, bracket_left, bracket_right, bracket_right],
        [y - 1.4, bracket_y, bracket_y, y - 1.4],
        color=ORANGE,
        lw=1.8,
    )
    ax.text(
        (bracket_left + bracket_right) / 2,
        bracket_y - 0.25,
        "Single SageMaker Training Job - no intermediate session reloads",
        ha="center",
        va="top",
        fontsize=9,
        color=ORANGE,
        fontweight="bold",
    )

    # Bottom caption
    ax.text(
        9.0,
        0.4,
        "Phase 1 weights flow directly into Phase 2 - no saving to disk, no reloading, no risk of mismatch",
        ha="center",
        va="center",
        fontsize=10,
        color=ANNOT,
        style="italic",
    )

    # Title
    ax.text(
        9.0,
        5.15,
        "Two-phase training within a single SageMaker Training Job",
        ha="center",
        va="center",
        fontsize=14,
        fontweight="bold",
        color=TEXT,
    )

    return fig


# --------------------------------------------------------------------------- #
# Figure 9: HPO → Model Registry: Closing the loop
#
# Boxes (left → right):
#   1. SageMaker AMT            blue   - "20+ trials / Bayesian search"
#   2. Best Trial               blue   - "Winning hyperparameter / configuration"
#   3. Evaluation               blue   - "Clinical thresholds / Recall ≥ 0.95"
#   4. Quality Gate             orange - "Pass / Fail check"
#   5. Model Registry           orange - "PendingManualApproval"
#
# Model Card attaches below Quality Gate with a dashed arrow upward.
# Bottom annotation: "Each registered model carries its HPO trial ID,
# evaluation metrics, Model Card reference, and Experiment lineage."
# --------------------------------------------------------------------------- #


def figure_9_hpo_to_registry():
    fig, ax = plt.subplots(figsize=(18, 5))
    ax.set_xlim(0, 18)
    ax.set_ylim(0, 5)
    ax.axis("off")

    y = 2.7

    # Five main stages
    xs = [1.6, 5.0, 8.4, 11.8, 15.2]
    widths = [1.9, 1.9, 1.9, 1.9, 1.9]
    colors = [BLUE, BLUE, BLUE, ORANGE, ORANGE]
    labels = [
        "SageMaker\nAMT",
        "Best Trial",
        "Evaluation",
        "Quality Gate",
        "Model\nRegistry",
    ]
    sublabels = [
        "20+ trials\nBayesian search",
        "Winning hyperparameter\nconfiguration",
        "Clinical thresholds\nRecall ≥ 0.95",
        "Pass / Fail check",
        "PendingManualApproval",
    ]

    for i, (x, w, c, lab, sub) in enumerate(zip(xs, widths, colors, labels, sublabels), start=1):
        stage_box(ax, (x, y), lab, c, width=w)
        number_circle(ax, (x, y + 0.85), i)
        ax.text(x, y - 0.85, sub, ha="center", va="center", fontsize=9, color=TEXT)

    # Arrows between stages
    for i in range(len(xs) - 1):
        sx = xs[i] + widths[i] / 2
        ex = xs[i + 1] - widths[i + 1] / 2
        arrow(ax, (sx, y), (ex, y))

    # Model Card attachment below Quality Gate
    card_x, card_y = xs[3], 0.7
    stage_box(ax, (card_x, card_y), "Model Card", "#7f7f7f", width=1.9, height=0.7, fontsize=10)
    ax.text(
        card_x,
        card_y - 0.4,
        "Clinical context",
        ha="center",
        va="center",
        fontsize=8.5,
        color=ANNOT,
        style="italic",
    )
    # Dashed arrow upward
    attach_arrow = FancyArrowPatch(
        (card_x, card_y + 0.35),
        (card_x, y - 0.55),
        arrowstyle="-|>",
        mutation_scale=12,
        linewidth=1.5,
        linestyle="--",
        color=ANNOT,
        zorder=1,
    )
    ax.add_patch(attach_arrow)

    # Title
    ax.text(
        9.0,
        4.6,
        "HPO → Model Registry: Closing the loop",
        ha="center",
        va="center",
        fontsize=14,
        fontweight="bold",
        color=TEXT,
    )

    # Bottom annotation
    ax.text(
        9.0,
        0.1,
        "Each registered model carries its HPO trial ID, evaluation metrics, "
        "Model Card reference, and Experiment lineage.",
        ha="center",
        va="center",
        fontsize=10,
        color=ANNOT,
        style="italic",
    )

    return fig


# --------------------------------------------------------------------------- #


def main() -> int:
    setup_style()
    print("Regenerating Part 2 flow diagrams...")

    save(figure_1_optimization_decision_flow(), "Part_2_figure_1_new")
    save(figure_2_two_phase_training(), "Part_2_figure_2_new")
    save(figure_9_hpo_to_registry(), "Part_2_figure_9_new")

    print("\nReview in blog_docs/part2/*_new.png, then overwrite originals if satisfied.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
