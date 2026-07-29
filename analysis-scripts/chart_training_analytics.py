#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import argparse
import json
from datetime import datetime
from pathlib import Path
from typing import Any

import matplotlib.patches as mpatches
import matplotlib.pyplot as plt
import numpy as np
import seaborn as sns

# Map pipeline executions → batch metadata (same as chart_metrics.py)
EXEC_TO_BATCH = {
    "wxflhfbz0fpi": {"batch": 1, "label": "B1\n(1,996)", "date": "2026-04-15", "images": 1996},
    "xzylbdkhios8": {"batch": 2, "label": "B2\n(3,992)", "date": "2026-04-17", "images": 3992},
    "qx98ud57b2bk": {"batch": 3, "label": "B3\n(5,988)", "date": "2026-04-17", "images": 5988},
    "59lmfq7d9m43": {"batch": 4, "label": "B4 (v5)\n(5,988)", "date": "2026-04-20", "images": 5988},
    "z2o9ptj900ns": {
        "batch": 5,
        "label": "B5 (BreakHis)\n(13,897)",
        "date": "2026-04-20",
        "images": 13897,
    },
}

MODEL_KEYS = {
    "TrainDenseNet121": "DenseNet121",
    "TrainEfficientNet": "EfficientNetV2M",
    "TrainVgg16": "VGG16",
}

COLORS = {
    "DenseNet121": "#1f77b4",
    "EfficientNetV2M": "#2ca02c",
    "VGG16": "#ff7f0e",
    "Ensemble": "#d62728",
}

STEP_COLORS = {
    "ValidateDataset": "#5b9bd5",
    "PreprocessData": "#7cb5ec",
    "TrainDenseNet121Model": "#1f77b4",
    "TrainEfficientNetModel": "#2ca02c",
    "TrainVgg16Model": "#ff7f0e",
    "EvaluateAllModels": "#9467bd",
    "CreateEnsembleModel": "#d62728",
    "Condition": "#8c564b",
    "RegisterEnsembleModel": "#e377c2",
}


def setup_style():
    sns.set_theme(style="whitegrid", context="talk")
    plt.rcParams["font.family"] = "DejaVu Sans"
    plt.rcParams["axes.titleweight"] = "bold"
    plt.rcParams["axes.titlesize"] = 14


def save_chart(fig, out_dir: Path, name: str):
    path = out_dir / f"{name}.png"
    fig.savefig(path, dpi=150, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"  ✓ {path}")


def parse_iso(ts: str) -> datetime:
    # Normalize timezone offsets for datetime parsing
    return datetime.fromisoformat(ts)


def classify_model(job_name: str) -> str | None:
    for key, label in MODEL_KEYS.items():
        if key in job_name:
            return label
    return None


def load_data(data_dir: Path) -> dict[str, Any]:
    """Load all JSON files and organize by execution + model."""
    data: dict[str, Any] = {}
    for exec_id in EXEC_TO_BATCH:
        data[exec_id] = {"steps": None, "jobs": {}}
        steps_file = data_dir / f"{exec_id}_steps.json"
        if steps_file.exists():
            data[exec_id]["steps"] = json.loads(steps_file.read_text())
        for job_file in data_dir.glob(f"{exec_id}_*.json"):
            if job_file.name.endswith("_steps.json"):
                continue
            job = json.loads(job_file.read_text())
            model = classify_model(job.get("TrainingJobName", ""))
            if model:
                # Flatten final metrics into a dict
                metrics = {m["MetricName"]: m["Value"] for m in job.get("FinalMetricDataList", [])}
                data[exec_id]["jobs"][model] = {
                    "name": job["TrainingJobName"],
                    "start": parse_iso(job["TrainingStartTime"]),
                    "end": parse_iso(job["TrainingEndTime"]),
                    "billable_sec": job.get("BillableTimeInSeconds", 0),
                    "training_sec": job.get("TrainingTimeInSeconds", 0),
                    "instance_type": job["ResourceConfig"]["InstanceType"],
                    "instance_count": job["ResourceConfig"]["InstanceCount"],
                    "image": job["AlgorithmSpecification"]["TrainingImage"],
                    "metrics": metrics,
                }
    return data


# --------------------------------------------------------------------------- #
# Chart: training duration per model per batch
# --------------------------------------------------------------------------- #


def chart_training_duration(data, out_dir: Path):
    fig, ax = plt.subplots(figsize=(12, 6))
    execs = list(EXEC_TO_BATCH.keys())
    x = np.arange(len(execs))
    width = 0.25

    for i, model in enumerate(["DenseNet121", "EfficientNetV2M", "VGG16"]):
        durations = []
        for e in execs:
            job = data[e]["jobs"].get(model)
            durations.append(job["training_sec"] / 60 if job else 0)
        bars = ax.bar(x + i * width, durations, width, label=model, color=COLORS[model])
        for bar, d in zip(bars, durations):
            if d > 0:
                ax.annotate(
                    f"{d:.1f}m",
                    xy=(bar.get_x() + bar.get_width() / 2, d),
                    xytext=(0, 3),
                    textcoords="offset points",
                    ha="center",
                    fontsize=9,
                )

    ax.set_xticks(x + width)
    ax.set_xticklabels([EXEC_TO_BATCH[e]["label"] for e in execs])
    ax.set_ylabel("Training Duration (minutes)")
    ax.set_title("GPU Training Time per Model per Batch (ml.p3.8xlarge)")
    ax.legend(loc="upper left")
    save_chart(fig, out_dir, "training_duration_per_model")


# --------------------------------------------------------------------------- #
# Chart: pipeline waterfall (step durations for latest batch)
# --------------------------------------------------------------------------- #


def chart_pipeline_waterfall(data, out_dir: Path, exec_id: str = "z2o9ptj900ns"):
    steps = data[exec_id]["steps"]
    if not steps:
        return
    # Sort by start time (successful steps only)
    clean = [s for s in steps if s.get("Status") == "Succeeded"]
    clean.sort(key=lambda s: parse_iso(s["Start"]))
    if not clean:
        return
    t0 = parse_iso(clean[0]["Start"])

    fig, ax = plt.subplots(figsize=(13, 7))
    for i, s in enumerate(clean):
        start_offset = (parse_iso(s["Start"]) - t0).total_seconds() / 60
        duration = (parse_iso(s["End"]) - parse_iso(s["Start"])).total_seconds() / 60
        color = STEP_COLORS.get(s["Step"], "#cccccc")
        ax.barh(i, duration, left=start_offset, color=color, edgecolor="white")
        ax.text(
            start_offset + duration / 2,
            i,
            f"{duration:.1f}m",
            ha="center",
            va="center",
            fontsize=9,
            color="white",
            fontweight="bold",
        )

    ax.set_yticks(range(len(clean)))
    ax.set_yticklabels([s["Step"] for s in clean])
    ax.invert_yaxis()
    ax.set_xlabel("Time from pipeline start (minutes)")
    batch_label = EXEC_TO_BATCH[exec_id]["label"].replace("\n", " ")
    ax.set_title(f"Pipeline Step Timeline - {batch_label}  ({exec_id})")
    save_chart(fig, out_dir, "pipeline_waterfall_latest")


# --------------------------------------------------------------------------- #
# Chart: train vs validation accuracy (final metrics)
# --------------------------------------------------------------------------- #


def chart_train_vs_val_accuracy(data, out_dir: Path):
    fig, axes = plt.subplots(1, 3, figsize=(16, 5.5), sharey=True)
    execs = list(EXEC_TO_BATCH.keys())
    x = np.arange(len(execs))
    width = 0.38

    for ax, model in zip(axes, ["DenseNet121", "EfficientNetV2M", "VGG16"]):
        train = []
        val = []
        for e in execs:
            job = data[e]["jobs"].get(model)
            if job:
                train.append(job["metrics"].get("train_accuracy", 0))
                val.append(job["metrics"].get("validation_accuracy", 0))
            else:
                train.append(0)
                val.append(0)
        ax.bar(x - width / 2, train, width, label="Train Accuracy", color="#27ae60")
        ax.bar(x + width / 2, val, width, label="Val Accuracy", color="#e74c3c")
        ax.set_xticks(x)
        ax.set_xticklabels([EXEC_TO_BATCH[e]["label"] for e in execs], rotation=0)
        ax.set_title(model)
        ax.set_ylim(0, 1.05)
        for i, (t, v) in enumerate(zip(train, val)):
            if t > 0:
                ax.annotate(
                    f"{t:.2f}",
                    xy=(i - width / 2, t),
                    xytext=(0, 2),
                    textcoords="offset points",
                    ha="center",
                    fontsize=8,
                )
            if v > 0:
                ax.annotate(
                    f"{v:.2f}",
                    xy=(i + width / 2, v),
                    xytext=(0, 2),
                    textcoords="offset points",
                    ha="center",
                    fontsize=8,
                )
    axes[0].set_ylabel("Accuracy")
    axes[0].legend(loc="lower left", fontsize=10)
    fig.suptitle("Train vs. Validation Accuracy - per Model per Batch", fontweight="bold")
    save_chart(fig, out_dir, "train_vs_val_accuracy")


# --------------------------------------------------------------------------- #
# Chart: overfitting gap (train - validation)
# --------------------------------------------------------------------------- #


def chart_overfitting_gap(data, out_dir: Path):
    fig, ax = plt.subplots(figsize=(12, 6))
    execs = list(EXEC_TO_BATCH.keys())
    x = np.arange(len(execs))

    for model in ["DenseNet121", "EfficientNetV2M", "VGG16"]:
        gaps = []
        for e in execs:
            job = data[e]["jobs"].get(model)
            if job:
                gap = job["metrics"].get("train_accuracy", 0) - job["metrics"].get(
                    "validation_accuracy", 0
                )
            else:
                gap = 0
            gaps.append(gap * 100)
        ax.plot(x, gaps, "o-", linewidth=2.5, markersize=12, color=COLORS[model], label=model)
        for xi, g in zip(x, gaps):
            ax.annotate(
                f"{g:+.1f}pp",
                xy=(xi, g),
                xytext=(7, 5),
                textcoords="offset points",
                fontsize=9,
                color=COLORS[model],
            )

    ax.axhline(0, color="gray", linewidth=1, linestyle="--", alpha=0.5)
    ax.set_xticks(x)
    ax.set_xticklabels([EXEC_TO_BATCH[e]["label"] for e in execs])
    ax.set_ylabel("Train Accuracy − Validation Accuracy (pp)")
    ax.set_title("Overfitting Gap per Model per Batch  ·  higher = more overfit")
    ax.legend(loc="upper right")
    save_chart(fig, out_dir, "overfitting_gap")


# --------------------------------------------------------------------------- #
# Chart: billable GPU seconds per batch
# --------------------------------------------------------------------------- #


def chart_gpu_cost_proxy(data, out_dir: Path):
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 5.5))
    execs = list(EXEC_TO_BATCH.keys())

    # Left: stacked billable seconds (minutes)
    stacks = {m: [] for m in ["DenseNet121", "EfficientNetV2M", "VGG16"]}
    for e in execs:
        for m in stacks:
            job = data[e]["jobs"].get(m)
            stacks[m].append(job["billable_sec"] / 60 if job else 0)

    x = np.arange(len(execs))
    bottom = np.zeros(len(execs))
    for m, vals in stacks.items():
        ax1.bar(x, vals, bottom=bottom, label=m, color=COLORS[m])
        bottom += np.array(vals)
    for xi, total in enumerate(bottom):
        ax1.annotate(
            f"{total:.0f}m",
            xy=(xi, total),
            xytext=(0, 4),
            textcoords="offset points",
            ha="center",
            fontweight="bold",
        )
    ax1.set_xticks(x)
    ax1.set_xticklabels([EXEC_TO_BATCH[e]["label"] for e in execs])
    ax1.set_ylabel("Billable GPU-Minutes")
    ax1.set_title("Billable ml.p3.8xlarge GPU-Minutes per Batch (stacked)")
    ax1.legend(loc="upper left")

    # Right: approximate USD cost ($12.24/hr for ml.p3.8xlarge)
    PRICE_PER_HOUR = 12.24  # ml.p3.8xlarge us-east-1
    total_min = bottom
    total_cost = total_min / 60 * PRICE_PER_HOUR
    bars = ax2.bar(x, total_cost, color="#d62728")
    for bar, c in zip(bars, total_cost):
        ax2.annotate(
            f"${c:.2f}",
            xy=(bar.get_x() + bar.get_width() / 2, c),
            xytext=(0, 3),
            textcoords="offset points",
            ha="center",
            fontweight="bold",
        )
    ax2.set_xticks(x)
    ax2.set_xticklabels([EXEC_TO_BATCH[e]["label"] for e in execs])
    ax2.set_ylabel("Estimated USD (on-demand)")
    ax2.set_title(f"Estimated Training Cost per Batch  ·  ${PRICE_PER_HOUR}/hr")
    save_chart(fig, out_dir, "gpu_cost_per_batch")


# --------------------------------------------------------------------------- #
# Chart: final loss trend per architecture
# --------------------------------------------------------------------------- #


def chart_loss_trend(data, out_dir: Path):
    fig, ax = plt.subplots(figsize=(12, 6))
    execs = list(EXEC_TO_BATCH.keys())
    x = np.arange(len(execs))

    for model in ["DenseNet121", "EfficientNetV2M", "VGG16"]:
        train_loss = []
        val_loss = []
        for e in execs:
            job = data[e]["jobs"].get(model)
            if job:
                train_loss.append(job["metrics"].get("train_loss", 0))
                val_loss.append(job["metrics"].get("validation_loss", 0))
            else:
                train_loss.append(0)
                val_loss.append(0)
        ax.plot(
            x,
            train_loss,
            "--",
            linewidth=2,
            marker="o",
            color=COLORS[model],
            label=f"{model} - train",
            alpha=0.6,
        )
        ax.plot(
            x,
            val_loss,
            "-",
            linewidth=2.5,
            marker="s",
            color=COLORS[model],
            label=f"{model} - validation",
        )

    ax.set_xticks(x)
    ax.set_xticklabels([EXEC_TO_BATCH[e]["label"] for e in execs])
    ax.set_ylabel("Final Loss Value")
    ax.set_title("Final Training & Validation Loss per Architecture per Batch")
    ax.legend(loc="upper left", ncol=3, fontsize=9)
    ax.set_yscale("log")
    save_chart(fig, out_dir, "loss_trend_per_architecture")


# --------------------------------------------------------------------------- #
# Chart: pipeline wall-clock time trend
# --------------------------------------------------------------------------- #


def chart_pipeline_walltime(data, out_dir: Path):
    fig, ax = plt.subplots(figsize=(12, 6))
    execs = list(EXEC_TO_BATCH.keys())
    wall_times = []
    labels = []
    for e in execs:
        steps = data[e]["steps"] or []
        succeeded = [s for s in steps if s.get("Status") == "Succeeded"]
        if not succeeded:
            wall_times.append(0)
            labels.append(EXEC_TO_BATCH[e]["label"])
            continue
        start = min(parse_iso(s["Start"]) for s in succeeded)
        end = max(parse_iso(s["End"]) for s in succeeded)
        wall_times.append((end - start).total_seconds() / 60)
        labels.append(EXEC_TO_BATCH[e]["label"])

    bars = ax.bar(np.arange(len(execs)), wall_times, color="#3498db")
    for bar, v in zip(bars, wall_times):
        ax.annotate(
            f"{v:.0f}m\n({v / 60:.1f}h)",
            xy=(bar.get_x() + bar.get_width() / 2, v),
            xytext=(0, 3),
            textcoords="offset points",
            ha="center",
            fontsize=10,
            fontweight="bold",
        )

    ax.set_xticks(np.arange(len(execs)))
    ax.set_xticklabels(labels)
    ax.set_ylabel("Wall-Clock Time (minutes)")
    ax.set_title("End-to-End Pipeline Wall-Clock Time per Batch")
    save_chart(fig, out_dir, "pipeline_walltime_trend")


# --------------------------------------------------------------------------- #
# Chart: throughput - images per minute
# --------------------------------------------------------------------------- #


def chart_throughput(data, out_dir: Path):
    fig, ax = plt.subplots(figsize=(12, 6))
    execs = list(EXEC_TO_BATCH.keys())
    x = np.arange(len(execs))
    width = 0.25

    for i, model in enumerate(["DenseNet121", "EfficientNetV2M", "VGG16"]):
        throughput = []
        for e in execs:
            job = data[e]["jobs"].get(model)
            if job and job["training_sec"] > 0:
                # Images processed = batch_size × steps_per_epoch × epochs
                # We use the input image count as a proxy for total samples seen
                images = EXEC_TO_BATCH[e]["images"]
                # Proxy: images per minute of training
                rate = images / (job["training_sec"] / 60)
            else:
                rate = 0
            throughput.append(rate)
        ax.bar(x + i * width, throughput, width, label=model, color=COLORS[model])

    ax.set_xticks(x + width)
    ax.set_xticklabels([EXEC_TO_BATCH[e]["label"] for e in execs])
    ax.set_ylabel("Training Throughput  (images/minute - proxy)")
    ax.set_title("Training Throughput per Model per Batch")
    ax.legend()
    save_chart(fig, out_dir, "training_throughput")


# --------------------------------------------------------------------------- #
# Chart: pipeline step composition (stacked % of total time)
# --------------------------------------------------------------------------- #


def chart_step_composition(data, out_dir: Path):
    fig, ax = plt.subplots(figsize=(13, 7))
    execs = list(EXEC_TO_BATCH.keys())
    step_order = [
        "ValidateDataset",
        "PreprocessData",
        "TrainDenseNet121Model",
        "TrainEfficientNetModel",
        "TrainVgg16Model",
        "EvaluateAllModels",
        "CreateEnsembleModel",
        "Condition",
        "RegisterEnsembleModel",
    ]

    # Build matrix: rows=step, cols=batch
    mat = np.zeros((len(step_order), len(execs)))
    for ci, e in enumerate(execs):
        steps = data[e]["steps"] or []
        for s in steps:
            if s.get("Status") != "Succeeded":
                continue
            if s["Step"] not in step_order:
                continue
            ri = step_order.index(s["Step"])
            duration = (parse_iso(s["End"]) - parse_iso(s["Start"])).total_seconds() / 60
            mat[ri, ci] = duration

    # For trainings, they run in parallel so the effective time is max of 3 - but
    # here we show cumulative for a "total GPU time" composition view
    bottom = np.zeros(len(execs))
    x = np.arange(len(execs))
    for ri, step in enumerate(step_order):
        ax.bar(x, mat[ri], bottom=bottom, label=step, color=STEP_COLORS.get(step, "#cccccc"))
        bottom += mat[ri]

    ax.set_xticks(x)
    ax.set_xticklabels([EXEC_TO_BATCH[e]["label"] for e in execs])
    ax.set_ylabel("Cumulative Step Time (minutes)")
    ax.set_title("Pipeline Step Time Composition per Batch (cumulative; training in parallel)")
    ax.legend(loc="upper left", fontsize=9)
    save_chart(fig, out_dir, "pipeline_step_composition")


# --------------------------------------------------------------------------- #
# Chart: image upgrade timeline (TF 2.13 → TF 2.19)
# --------------------------------------------------------------------------- #


def chart_container_upgrade(data, out_dir: Path):
    fig, ax = plt.subplots(figsize=(13, 5))
    execs = list(EXEC_TO_BATCH.keys())

    image_per_batch = []
    for e in execs:
        # Take DenseNet121's image as representative (all 3 use the same DLC family)
        job = data[e]["jobs"].get("DenseNet121")
        if job:
            full = job["image"].split("/")[-1]
            # Shorten the tag so it fits on the axis
            image_per_batch.append(full)
        else:
            image_per_batch.append("unknown")

    rows = [
        ("TF 2.13 / Py3.10 / Ubuntu 20.04", "#e74c3c"),
        ("TF 2.19 / Py3.12 / Ubuntu 22.04", "#27ae60"),
    ]

    for ci, tag in enumerate(image_per_batch):
        is_old = "2.13" in tag
        color = rows[0][1] if is_old else rows[1][1]
        ax.barh(0, 1, left=ci, color=color, edgecolor="white", linewidth=2)
        ax.text(
            ci + 0.5,
            0,
            EXEC_TO_BATCH[execs[ci]]["label"].replace("\n", " "),
            ha="center",
            va="center",
            fontsize=10,
            fontweight="bold",
            color="white",
        )

    ax.set_yticks([])
    ax.set_xticks([])
    ax.set_xlim(0, len(execs))
    ax.set_ylim(-0.5, 0.5)
    ax.set_title("Container Image Upgrade Timeline Across Batches")
    # Legend
    patches = [mpatches.Patch(color=c, label=label) for label, c in rows]
    ax.legend(handles=patches, loc="center", bbox_to_anchor=(0.5, -0.3), ncol=2)
    save_chart(fig, out_dir, "container_image_upgrade_timeline")


# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #


def write_deep_observations(data, out_dir: Path):
    lines = [
        "# Deep Training Analysis - Observations",
        "",
        "Generated from SageMaker training-job describe output.",
        "",
    ]

    for exec_id, meta in EXEC_TO_BATCH.items():
        lines.append(f"## Batch {meta['batch']}  ({exec_id})")
        lines.append(f"- Date: {meta['date']}  ·  Training images: {meta['images']:,}")
        for model, job in data[exec_id]["jobs"].items():
            train_acc = job["metrics"].get("train_accuracy", 0)
            val_acc = job["metrics"].get("validation_accuracy", 0)
            gap = (train_acc - val_acc) * 100
            lines.append(
                f"  - **{model}** - {job['training_sec'] / 60:.1f} min · "
                f"train {train_acc:.2%} / val {val_acc:.2%} · gap {gap:+.1f}pp"
            )
        lines.append("")

    path = out_dir / "deep_observations.md"
    path.write_text("\n".join(lines))
    print(f"  ✓ {path}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Detailed training analytics charts")
    # Default is the pipeline's downloaded-training-data path, overridable via CLI.
    parser.add_argument(
        "--data-dir",
        type=Path,
        default=Path("/tmp/training_data"),  # nosemgrep # nosec B108
    )
    parser.add_argument("--output-dir", type=Path, default=Path("blog/charts"))
    args = parser.parse_args()

    if not args.data_dir.exists():
        print("Data dir not found. Run analysis-scripts/data_gather_training.sh first.")
        return 1

    setup_style()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    data = load_data(args.data_dir)

    print(f"Generating detailed charts into {args.output_dir}/ ...")
    chart_training_duration(data, args.output_dir)
    chart_pipeline_waterfall(data, args.output_dir)
    chart_train_vs_val_accuracy(data, args.output_dir)
    chart_overfitting_gap(data, args.output_dir)
    chart_gpu_cost_proxy(data, args.output_dir)
    chart_loss_trend(data, args.output_dir)
    chart_pipeline_walltime(data, args.output_dir)
    chart_throughput(data, args.output_dir)
    chart_step_composition(data, args.output_dir)
    chart_container_upgrade(data, args.output_dir)
    write_deep_observations(data, args.output_dir)

    print()
    print("✓ Detailed analytics complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
