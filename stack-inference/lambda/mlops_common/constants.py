# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Constants every stage must agree on."""

# Per-channel normalisation: pixels are scaled to 0-1, then (x - mean) / std.
# Keep these values when you load weights trained with the same statistics.
CHANNEL_MEAN = (0.485, 0.456, 0.406)
CHANNEL_STD = (0.229, 0.224, 0.225)

IMAGE_EXTENSIONS = (".jpg", ".jpeg", ".png")

DEFAULT_SEED = 42
