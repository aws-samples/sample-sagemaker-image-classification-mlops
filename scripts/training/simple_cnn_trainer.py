#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Small CNN baseline the ensemble members are compared against. Architecture
only; the loop lives in `_common.py`.

Same data loading, image transform, class weights, augmentation, callbacks
and outputs as the other trainers, trained in one phase with every layer
trainable. With a test channel it also writes test_metrics.json. It is never
an ensemble member and is never registered (baseline_cnn in stack-training).
"""

import logging

from _common import trainer_main
from tensorflow.keras.layers import (
    BatchNormalization,
    Conv2D,
    Dense,
    Dropout,
    GlobalAveragePooling2D,
    Input,
    MaxPooling2D,
)
from tensorflow.keras.models import Model
from training_config import CONFIG

logger = logging.getLogger(__name__)

MODEL_NAME = "simple_cnn"


def build_model(learning_rate, weights_path=None):
    """Return (model, None): no backbone to freeze.

    With `weights_path` (your own weights for the whole model) they are loaded.
    """
    cfg = CONFIG["models"][MODEL_NAME]
    input_size = cfg["input_size"][0]

    inputs = Input(shape=(input_size, input_size, 3))
    x = inputs
    for filters in cfg["conv_filters"]:
        x = Conv2D(filters, 3, padding="same", activation="relu")(x)
        x = BatchNormalization()(x)
        x = MaxPooling2D()(x)
    x = GlobalAveragePooling2D()(x)
    x = Dense(cfg["dense_units"], activation="relu")(x)
    x = Dropout(cfg["dropout_rate"])(x)
    predictions = Dense(1, activation="sigmoid")(x)

    model = Model(inputs=inputs, outputs=predictions, name=MODEL_NAME)
    if weights_path:
        model.load_weights(weights_path)
    logger.info("%s model built with %d parameters", MODEL_NAME, model.count_params())
    return model, None


if __name__ == "__main__":
    trainer_main(MODEL_NAME, build_model)
