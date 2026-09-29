# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Export one trained member model as a SavedModel with explanation signatures.

The served endpoint is the SageMaker TensorFlow Serving container, which runs
the SavedModel graphs in TensorFlow Serving and a small Python handler
(code/inference.py) in front of them. The handler has no TensorFlow, so
everything that needs gradients or many forward passes is built into the graph
here and exposed as extra signatures next to the usual serving signature:

- ``serving_default`` (endpoint ``serve``): the model's forward pass, the same
  signature ``model.export()`` writes. Plain predictions use only this one.
- ``gradcam``: Grad-CAM for one image. Activations are taken at the feature map
  that feeds the model's GlobalAveragePooling2D layer (the backbone's final
  convolutional block), gradients are of the malignant logit (the final Dense
  layer before its sigmoid, so a saturated probability still has a gradient).
  Returns ReLU maps for both classes (the benign map uses the negated
  gradient), resized to GRADCAM_GRID x GRADCAM_GRID, and the probability.
- ``region_scores``: the malignant probability of the image with regions of a
  coarse grid replaced by the baseline. ``masks`` is (N, G, G): 1 keeps a
  region, 0 replaces it with 0.0, which after ImageNet normalisation is the
  ImageNet mean colour. One call scores N coalitions for the region Shapley
  estimate without sending N images over the wire.
"""

from __future__ import annotations

import tensorflow as tf

GRADCAM_GRID = 14


def split_at_pooling(model):
    """(features, head_layers, final_dense) for a backbone + GAP + dense head.

    features maps the input to the feature map feeding GlobalAveragePooling2D;
    head_layers are the layers after it, in order, excluding final_dense.
    """
    # The last one: EfficientNet's squeeze-and-excitation blocks have their own.
    pools = [
        i
        for i, layer in enumerate(model.layers)
        if isinstance(layer, tf.keras.layers.GlobalAveragePooling2D)
    ]
    if not pools:
        raise ValueError(f"No GlobalAveragePooling2D layer in {model.name}")
    pool_idx = pools[-1]
    pool = model.layers[pool_idx]
    features = tf.keras.Model(model.inputs, pool.input, name=f"{model.name}_features")
    tail = model.layers[pool_idx:]
    final_dense = tail[-1]
    if not isinstance(final_dense, tf.keras.layers.Dense) or final_dense.units != 1:
        raise ValueError(f"{model.name} must end in a Dense(1) layer")
    return features, tail[:-1], final_dense


def _logit(head_layers, final_dense, activations):
    x = activations
    for layer in head_layers:
        x = layer(x, training=False)
    return tf.squeeze(tf.matmul(x, final_dense.kernel) + final_dense.bias, axis=-1)


def export_with_explanations(model, saved_dir):
    """Write model to saved_dir with serve, gradcam and region_scores endpoints."""
    features, head_layers, final_dense = split_at_pooling(model)
    height, width, channels = (int(d) for d in model.input_shape[1:])
    image_spec = tf.TensorSpec([None, height, width, channels], tf.float32, name="image")

    archive = tf.keras.export.ExportArchive()
    archive.track(model)
    # First endpoint becomes serving_default, as with model.export().
    archive.add_endpoint(
        name="serve",
        fn=lambda inputs: model(inputs, training=False),
        input_signature=[tf.TensorSpec([None, height, width, channels], tf.float32)],
    )

    def gradcam(image):
        with tf.GradientTape() as tape:
            acts = features(image, training=False)
            tape.watch(acts)
            logit = _logit(head_layers, final_dense, acts)
        grads = tape.gradient(logit, acts)
        alpha = tf.reduce_mean(grads, axis=[1, 2], keepdims=True)
        cam = tf.reduce_sum(acts * alpha, axis=-1, keepdims=True)
        size = [GRADCAM_GRID, GRADCAM_GRID]
        return {
            "cam_malignant": tf.squeeze(tf.image.resize(tf.nn.relu(cam), size), -1),
            "cam_benign": tf.squeeze(tf.image.resize(tf.nn.relu(-cam), size), -1),
            "score": tf.sigmoid(logit),
        }

    archive.add_endpoint(name="gradcam", fn=gradcam, input_signature=[image_spec])

    def region_scores(image, masks):
        up = tf.image.resize(masks[..., tf.newaxis], [height, width], method="nearest")
        return {"scores": tf.reshape(model(image[:1] * up, training=False), [-1])}

    archive.add_endpoint(
        name="region_scores",
        fn=region_scores,
        input_signature=[image_spec, tf.TensorSpec([None, None, None], tf.float32, name="masks")],
    )
    archive.write_out(saved_dir, verbose=False)
