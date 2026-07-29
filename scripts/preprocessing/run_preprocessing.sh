#!/bin/sh
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

set -e

CODE_DIR="/opt/ml/processing/input/code"

# Install SMOTE / image deps. Fall back to explicit packages if the
# requirements file is missing for any reason.
pip install -q -r "${CODE_DIR}/requirements.txt" 2>/dev/null \
  || pip install -q imbalanced-learn Pillow scikit-learn numpy

# All flags (--input-path, --output-path, --target-size, --apply-smote) arrive
# as ContainerArguments and are forwarded verbatim.
exec python3 "${CODE_DIR}/data_preprocessor.py" "$@"
