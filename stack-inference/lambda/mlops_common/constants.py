# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Constants every stage must agree on."""

# ImageNet channel statistics. Pixels are scaled to 0-1, then normalised per
# channel as (x - mean) / std. The pretrained backbones expect this input.
IMAGENET_MEAN = (0.485, 0.456, 0.406)
IMAGENET_STD = (0.229, 0.224, 0.225)

IMAGE_EXTENSIONS = (".jpg", ".jpeg", ".png")

# Class directories in label order. Keras flow_from_directory sorts class
# directories alphabetically, so benign is 0 and malignant (the positive class)
# is 1. The evaluation loaders use the same order.
CLASS_DIRS = ("breast_benign", "breast_malignant")
CLASS_NAMES = ("benign", "malignant")

DEFAULT_SEED = 42
