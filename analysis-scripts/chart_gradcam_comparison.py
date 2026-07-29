#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import argparse
import json
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import tensorflow as tf
from PIL import Image

IMG_SIZE = 224


def load_image(path: Path) -> tuple[np.ndarray, np.ndarray]:
    img = Image.open(path).convert("RGB").resize((IMG_SIZE, IMG_SIZE))
    arr = np.asarray(img, dtype=np.uint8)
    x = arr.astype(np.float32) / 255.0
    return arr, x[None, ...]


def saliency(wrapped, img_batch):
    x = tf.convert_to_tensor(img_batch)
    with tf.GradientTape() as tape:
        tape.watch(x)
        preds = wrapped(x)
        if isinstance(preds, dict):
            preds = next(iter(preds.values()))
        score = preds[:, 0]
    grads = tape.gradient(score, x)
    sal = tf.reduce_max(tf.abs(grads), axis=-1)[0]
    sal = sal / (tf.reduce_max(sal) + 1e-9)
    return sal.numpy(), float(preds[0, 0].numpy())


def overlay(original: np.ndarray, heatmap: np.ndarray, alpha: float = 0.45) -> np.ndarray:
    import matplotlib.cm as cm

    h = Image.fromarray((heatmap * 255).astype(np.uint8)).resize(
        (IMG_SIZE, IMG_SIZE), Image.BILINEAR
    )
    h = np.asarray(h) / 255.0
    colored = (cm.jet(h)[..., :3] * 255).astype(np.uint8)
    blended = ((1 - alpha) * original + alpha * colored).astype(np.uint8)
    return blended


def find_samples(predictions_path: Path, data_root: Path):
    """Return (correct_path, correct_pred, correct_true,
    wrong_path, wrong_pred, wrong_true)."""
    p = json.loads(predictions_path.read_text())
    scores = np.array(p["predictions"]["densenet121"])
    labels = np.array(p["true_labels"])
    files = p["test_filenames"]

    # Correct high-confidence malignant
    correct_mask = (scores > 0.95) & (labels == 1)
    wrong_mask = (scores < 0.15) & (labels == 1)  # missed positive

    if not correct_mask.any() or not wrong_mask.any():
        # Fallback: try false positives if no false negatives
        wrong_mask = (scores > 0.8) & (labels == 0)

    correct_idx = int(np.argmax(correct_mask.astype(int) * scores))
    wrong_idx = int(
        np.argmax(
            wrong_mask.astype(int)
            * (np.where(labels[wrong_mask.nonzero()[0][0]] == 1, 1 - scores, scores))
        )
    )
    # Simpler correct/wrong pickers
    correct_idx = np.where(correct_mask)[0][0]
    wrong_idx = np.where(wrong_mask)[0][0]

    return {
        "correct": {
            "path": data_root / files[correct_idx],
            "pred": float(scores[correct_idx]),
            "truth": int(labels[correct_idx]),
        },
        "wrong": {
            "path": data_root / files[wrong_idx],
            "pred": float(scores[wrong_idx]),
            "truth": int(labels[wrong_idx]),
        },
    }


def render(model_dir: Path, samples: dict, out_path: Path):
    print(f"Loading SavedModel from {model_dir} ...")
    tfsm = tf.keras.layers.TFSMLayer(str(model_dir), call_endpoint="serving_default")
    inp = tf.keras.Input(shape=(IMG_SIZE, IMG_SIZE, 3))
    out = tfsm(inp)
    if isinstance(out, dict):
        out = next(iter(out.values()))
    wrapped = tf.keras.Model(inp, out)

    fig, axes = plt.subplots(2, 3, figsize=(14, 8.5))

    for row, (label, meta) in enumerate(
        [("✓ CORRECT prediction", samples["correct"]), ("✗ INCORRECT prediction", samples["wrong"])]
    ):
        path = meta["path"]
        if not path.exists():
            # Fallback: look in the local dataset dirs
            fallback = Path("data/batch4_breakhis") / path.name
            if fallback.exists():
                path = fallback
            else:
                print(f"  ⚠️  Sample not found: {meta['path']}")
                continue

        orig, batch = load_image(path)
        sal_map, pred = saliency(wrapped, batch)
        heat = overlay(orig, sal_map)

        pred_label = "Malignant" if pred > 0.5 else "Benign"
        true_label = "Malignant" if meta["truth"] == 1 else "Benign"
        confidence = pred if pred > 0.5 else (1 - pred)
        correct_mark = "✓" if (pred > 0.5) == (meta["truth"] == 1) else "✗"

        axes[row, 0].imshow(orig)
        axes[row, 0].set_title(f"{label}\nTrue: {true_label}")
        axes[row, 0].axis("off")

        axes[row, 1].imshow(sal_map, cmap="jet")
        axes[row, 1].set_title("What the model attends to\n(saliency)")
        axes[row, 1].axis("off")

        axes[row, 2].imshow(heat)
        axes[row, 2].set_title(f"Overlay\nPredicted {pred_label} ({confidence:.1%}) {correct_mark}")
        axes[row, 2].axis("off")

        # Add a colored frame to the left-most image to flag correct/incorrect
        color = "#27ae60" if correct_mark == "✓" else "#c0392b"
        for spine in axes[row, 0].spines.values():
            spine.set_visible(True)
            spine.set_color(color)
            spine.set_linewidth(4)

    fig.suptitle(
        "Grad-CAM / Saliency - Correct vs. Incorrect Prediction",
        fontweight="bold",
        fontsize=14,
        y=1.02,
    )
    fig.tight_layout()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path, dpi=150, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"  ✓ {out_path}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Grad-CAM correct vs incorrect")
    # Defaults are the pipeline's downloaded-model and predictions artifact
    # paths, overridable via CLI.
    parser.add_argument(
        "--model-dir",
        type=Path,
        default=Path("/tmp/ensemble_model/densenet121_model/1"),  # nosemgrep # nosec B108
    )
    parser.add_argument(
        "--predictions",
        type=Path,
        default=Path("/tmp/predictions.json"),  # nosemgrep # nosec B108
    )
    parser.add_argument(
        "--data-root",
        type=Path,
        default=Path("data/batch4_breakhis"),
        help="Where test images live - filenames in predictions.json are relative to this",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("blog/charts/07_explainability/gradcam_correct_vs_incorrect.png"),
    )
    args = parser.parse_args()

    samples = find_samples(args.predictions, args.data_root)
    print(
        f"  Correct sample: {samples['correct']['path'].name}  "
        f"pred={samples['correct']['pred']:.3f}  true={samples['correct']['truth']}"
    )
    print(
        f"  Wrong   sample: {samples['wrong']['path'].name}  "
        f"pred={samples['wrong']['pred']:.3f}  true={samples['wrong']['truth']}"
    )

    render(args.model_dir, samples, args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
