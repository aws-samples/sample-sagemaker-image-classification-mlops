#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import argparse
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import tensorflow as tf
from PIL import Image

IMG_SIZE = 224


def load_image(path: Path) -> tuple[np.ndarray, np.ndarray]:
    """Return (original_array_uint8, normalized_input_batch_float32)."""
    img = Image.open(path).convert("RGB").resize((IMG_SIZE, IMG_SIZE))
    arr = np.asarray(img, dtype=np.uint8)
    x = arr.astype(np.float32) / 255.0
    return arr, x[None, ...]


def compute_gradcam(
    model: tf.keras.Model, image_batch: np.ndarray, target_layer_name: str | None = None
) -> np.ndarray:
    """Compute Grad-CAM for the given preloaded Keras model on a single image."""
    # Find the last convolutional layer if not specified
    if target_layer_name is None:
        for layer in reversed(model.layers):
            # DenseNet uses Conv2D or depthwise - we want a 4-D tensor layer
            if isinstance(
                layer,
                (
                    tf.keras.layers.Conv2D,
                    tf.keras.layers.SeparableConv2D,
                    tf.keras.layers.DepthwiseConv2D,
                ),
            ):
                target_layer_name = layer.name
                break
    if target_layer_name is None:
        raise ValueError("Could not find a convolutional layer for Grad-CAM")

    target_layer = model.get_layer(target_layer_name)
    grad_model = tf.keras.models.Model(
        inputs=model.inputs,
        outputs=[target_layer.output, model.output],
    )

    with tf.GradientTape() as tape:
        conv_out, preds = grad_model(tf.constant(image_batch))
        # Binary classifier - single logit / sigmoid output
        loss = preds[:, 0]

    grads = tape.gradient(loss, conv_out)
    pooled = tf.reduce_mean(grads, axis=(0, 1, 2))
    conv_out = conv_out[0]
    heatmap = tf.reduce_sum(conv_out * pooled, axis=-1)
    heatmap = tf.nn.relu(heatmap)
    hmax = tf.reduce_max(heatmap)
    if hmax > 0:
        heatmap = heatmap / hmax
    return heatmap.numpy(), float(preds[0, 0].numpy()), target_layer_name


def overlay(original: np.ndarray, heatmap: np.ndarray, alpha: float = 0.45) -> np.ndarray:
    """Resize heatmap to image, colorize with jet, and blend."""
    import matplotlib.cm as cm

    h = Image.fromarray((heatmap * 255).astype(np.uint8)).resize(
        (IMG_SIZE, IMG_SIZE), Image.BILINEAR
    )
    h = np.asarray(h) / 255.0
    colored = (cm.jet(h)[..., :3] * 255).astype(np.uint8)
    blended = ((1 - alpha) * original + alpha * colored).astype(np.uint8)
    return blended


def render_pair(benign_path: Path, malignant_path: Path, model_dir: Path, out_path: Path):
    print(f"Loading SavedModel from {model_dir} ...")
    # Load as a Keras model (SavedModel format)
    model = tf.keras.layers.TFSMLayer(str(model_dir), call_endpoint="serving_default")
    # Build a wrapper Keras model so we can get intermediate layer outputs
    inp = tf.keras.Input(shape=(IMG_SIZE, IMG_SIZE, 3))
    out = model(inp)
    # If it's a dict, pick the first value
    if isinstance(out, dict):
        out = next(iter(out.values()))
    wrapped = tf.keras.Model(inp, out)

    # Grad-CAM needs access to internal conv layers. TFSMLayer hides them.
    # Fallback: use saliency instead (gradient magnitude on input).
    def saliency(img_batch):
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

    fig, axes = plt.subplots(2, 3, figsize=(13, 8))

    for row, (label, path) in enumerate([("Benign", benign_path), ("Malignant", malignant_path)]):
        orig, batch = load_image(path)
        sal_map, pred = saliency(batch)
        heat = overlay(orig, sal_map)

        axes[row, 0].imshow(orig)
        axes[row, 0].set_title(f"{label}\n(input image)")
        axes[row, 0].axis("off")

        axes[row, 1].imshow(sal_map, cmap="jet")
        axes[row, 1].set_title("Gradient saliency\n(what DenseNet attends to)")
        axes[row, 1].axis("off")

        axes[row, 2].imshow(heat)
        pred_label = "Malignant" if pred > 0.5 else "Benign"
        confidence = pred if pred > 0.5 else (1 - pred)
        axes[row, 2].set_title(f"Overlay\nPredicted: {pred_label} ({confidence:.1%})")
        axes[row, 2].axis("off")

    fig.suptitle(
        "DenseNet121 - Saliency / Grad-CAM Overlay on Histopathology Images",
        fontweight="bold",
        fontsize=14,
        y=1.01,
    )
    fig.tight_layout()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path, dpi=150, bbox_inches="tight", facecolor="white")
    print(f"  ✓ {out_path}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Grad-CAM / saliency overlay generator")
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--benign", type=Path, required=True)
    parser.add_argument("--malignant", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("blog/charts/gradcam_overlay.png"))
    args = parser.parse_args()

    render_pair(args.benign, args.malignant, args.model_dir, args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
