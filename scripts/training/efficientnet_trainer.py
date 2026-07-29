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
    """Return (model, base_model) for EfficientNetV2-M with a binary head.

    Freezing and compilation are owned by the two-phase training loop in
    `_common.run_two_phase_fit`; this function only assembles the architecture
    and returns the backbone so the loop can unfreeze its top layers in Phase 2.
    """
    cfg = CONFIG["models"][MODEL_NAME]
    input_size = cfg["input_size"][0]

    if weights_path:
        logger.info("Loading pre-trained weights from %s", weights_path)
        base = EfficientNetV2M(
            weights=None, include_top=False, input_shape=(input_size, input_size, 3)
        )
        base.load_weights(weights_path)
    else:
        logger.info("Downloading ImageNet weights (requires internet)")
        base = EfficientNetV2M(
            weights="imagenet", include_top=False, input_shape=(input_size, input_size, 3)
        )

    x = GlobalAveragePooling2D()(base.output)
    x = Dense(cfg["dense_units"], activation="relu")(x)
    x = Dropout(cfg["dropout_rate"])(x)
    predictions = Dense(1, activation="sigmoid")(x)

    model = Model(inputs=base.input, outputs=predictions)
    logger.info("%s model built with %d parameters", MODEL_NAME, model.count_params())
    return model, base


if __name__ == "__main__":
    trainer_main(MODEL_NAME, build_model)
