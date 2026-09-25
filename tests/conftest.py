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
os.environ["AWS_ACCESS_KEY_ID"] = "testing"
os.environ["AWS_SECRET_ACCESS_KEY"] = (
    "testing"  # pragma: allowlist secret - fake offline test credential
)
os.environ["AWS_SESSION_TOKEN"] = "testing"
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


@pytest.fixture
def breakhis_name():
    def make(tumor_class: str, patient: int, magnification: int, seq: int) -> str:
        kind = "A" if tumor_class == "B" else "DC"
        return f"breakhis_SOB_{tumor_class}_{kind}-14-{patient:05d}AB-{magnification}-{seq:03d}.png"

    return make
