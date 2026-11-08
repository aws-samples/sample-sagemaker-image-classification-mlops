# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Shared fixtures. No test reaches AWS: clients are moto or botocore Stubber."""

from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

# Fake credentials and a region so boto3 clients can be built offline.
for _name in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN"):
    os.environ[_name] = "testing"
os.environ["AWS_DEFAULT_REGION"] = "us-east-1"
os.environ.pop("AWS_PROFILE", None)


def load_module(relpath: str, name: str):
    """Import a script that is not part of a package, by path."""
    path = ROOT / relpath
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


CLASSES = ("class_a", "class_b")


@pytest.fixture
def image_name():
    """``g<group>__[<subgroup>__]img_<seq>.png``, the dataset_layout naming convention."""

    def make(group: int, seq: int, subgroup: str | None = None) -> str:
        middle = f"{subgroup}__" if subgroup else ""
        return f"g{group:03d}__{middle}img_{seq:03d}.png"

    return make
