#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Refresh the inference Lambda's copy of mlops_common from scripts/mlops_common.
# Terraform zips stack-inference/lambda/ as the Lambda package, so the shared
# preprocess() and score parsing must sit inside that directory.
# tests/test_vendored_copy.py fails when the two copies differ.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${ROOT}/scripts/mlops_common"
DST="${ROOT}/stack-inference/lambda/mlops_common"

rm -rf "$DST"
mkdir -p "$DST"
find "$SRC" -maxdepth 1 -name "*.py" -exec cp {} "$DST/" \;
echo "Synced $(find "$DST" -name '*.py' | wc -l | tr -d ' ') files to ${DST#"$ROOT"/}"
