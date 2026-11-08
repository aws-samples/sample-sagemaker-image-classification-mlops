#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""EfficientNetV2-M trainer - architecture only. Loop lives in `_common.py`."""

import logging

from _common import trainer_main
from tensorflow.keras.applications import EfficientNetV2M
from tensorflow.keras.layers import Dense, Dropout, GlobalAveragePooling2D
from tensorflow.keras.models import Model
from training_config import CONFIG

logger = logging.getLogger(__name__)

MODEL_NAME = "efficientnet"


def build_model(learning_rate, weights_path=None):
    """Return (model, backbone or None) for EfficientNetV2-M with a binary head.

    The backbone starts from random initialisation, or from your own weights
    file (`weights_path`); only then is it returned, for two-phase fine-tuning.
    """
    # Inputs arrive already normalised by the shared loader (the same transform
    # evaluation and serving use), so the backbone's own rescaling layer, which
    # expects 0-255 pixels, is switched off.
    cfg = CONFIG["models"][MODEL_NAME]
    input_size = cfg["input_size"][0]

    base = EfficientNetV2M(
        weights=None,
        include_top=False,
        input_shape=(input_size, input_size, 3),
        include_preprocessing=False,
    )
    if weights_path:
        base.load_weights(weights_path)

    x = GlobalAveragePooling2D()(base.output)
    x = Dense(cfg["dense_units"], activation="relu")(x)
    x = Dropout(cfg["dropout_rate"])(x)
    predictions = Dense(1, activation="sigmoid")(x)

    model = Model(inputs=base.input, outputs=predictions)
    logger.info("%s model built with %d parameters", MODEL_NAME, model.count_params())
    return model, (base if weights_path else None)


if __name__ == "__main__":
    trainer_main(MODEL_NAME, build_model)
