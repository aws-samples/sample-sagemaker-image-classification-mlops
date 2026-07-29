# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""
SageMaker ensemble inference handler.

Loads individual SavedModel directories produced by the ensemble_creator
(via model.export() in Keras 3 / TF 2.16+) and runs weighted inference.

Exported SavedModels are loaded with tf.saved_model.load(), which works in
both Keras 2 and Keras 3. tf.keras.models.load_model() no longer supports
SavedModel directories in Keras 3.
"""

import json
import os

import numpy as np
import tensorflow as tf


def _get_serving_fn(saved_model):
    """Return the default serving signature from a loaded SavedModel."""
    sigs = getattr(saved_model, "signatures", {})
    if "serving_default" in sigs:
        return sigs["serving_default"]
    # Fallback: pick the first available signature
    if sigs:
        return next(iter(sigs.values()))
    # As a last resort, treat the loaded object as callable
    return saved_model


def model_fn(model_dir):
    models = {}
    serving_fns = {}
    with open(os.path.join(model_dir, "ensemble_config.json")) as f:
        config = json.load(f)

    for model_name in config["models"]:
        model_path = os.path.join(model_dir, f"{model_name}_model", "1")
        loaded = tf.saved_model.load(model_path)
        models[model_name] = loaded
        serving_fns[model_name] = _get_serving_fn(loaded)

    return {"models": models, "serving_fns": serving_fns, "config": config}


def input_fn(request_body, request_content_type):
    input_data = json.loads(request_body)
    array_data = np.array(input_data["instances"][0], dtype=np.float32)
    return array_data.astype(np.float32)


def _predict_single(serving_fn, input_tensor):
    """Call a SavedModel serving function and extract prediction array."""
    output = serving_fn(input_tensor)
    # Output may be a dict (SavedModel) or a tensor
    if isinstance(output, dict):
        # Take the first output tensor from the dict
        out_tensor = next(iter(output.values()))
    else:
        out_tensor = output
    return np.asarray(out_tensor)


def predict_fn(input_data, model):
    models = model["models"]
    serving_fns = model["serving_fns"]
    config = model["config"]
    weights = config["weights"]
    optimal_threshold = config.get("optimal_threshold", 0.5)

    if len(input_data.shape) == 3:
        input_data = np.expand_dims(input_data, axis=0)

    input_tensor = tf.convert_to_tensor(input_data, dtype=tf.float32)

    predictions = []
    for i, model_name in enumerate(models.keys()):
        pred = _predict_single(serving_fns[model_name], input_tensor)
        predictions.append(pred * weights[i])

    ensemble_pred = np.sum(predictions, axis=0)
    predicted_class = (ensemble_pred > optimal_threshold).astype(int)

    return {
        "predictions": ensemble_pred.tolist(),
        "predicted_class": predicted_class.tolist(),
        "threshold_used": optimal_threshold,
    }


def output_fn(prediction, content_type):
    return json.dumps(prediction)
