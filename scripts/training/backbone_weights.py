# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Locate your own backbone weights for a trainer (optional; random initialisation otherwise)."""

from __future__ import annotations

import os


def resolve_weights_path(model_name: str) -> str | None:
    """Your own backbone weights file for this model, or None to train from random initialisation.

    Set BACKBONE_WEIGHTS_S3_URI to load weights: the pipeline then mounts that
    S3 location as the ``weights`` input channel (SM_CHANNEL_WEIGHTS), so it
    also works under network isolation. The file used is
    ``<model_name>.weights.h5``, or the only ``.h5`` file in the channel.
    Raises RuntimeError when the URI is set but no single file matches.
    """
    uri = os.environ.get("BACKBONE_WEIGHTS_S3_URI", "").strip()
    if not uri:
        return None
    channel = os.environ.get("SM_CHANNEL_WEIGHTS", "")
    if not channel or not os.path.isdir(channel):
        raise RuntimeError(
            f"BACKBONE_WEIGHTS_S3_URI is set ({uri}) but the weights channel is missing"
        )
    files = sorted(
        os.path.join(root, name)
        for root, _dirs, names in os.walk(channel)
        for name in names
        if name.endswith(".h5")
    )
    named = [f for f in files if os.path.basename(f) == f"{model_name}.weights.h5"]
    if named:
        return named[0]
    if len(files) == 1:
        return files[0]
    raise RuntimeError(
        f"weights channel holds {len(files)} .h5 file(s) and none is {model_name}.weights.h5"
    )
