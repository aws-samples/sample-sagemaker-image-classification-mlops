#!/bin/sh
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

set -e

CODE_DIR="/opt/ml/processing/input/code"

# A raw ProcessingJob entrypoint does not auto-install requirements.txt the way
# the SageMaker Python SDK's ScriptProcessor does, so install Fairlearn here.
# Fall back to an unpinned install if the requirements file is missing.
pip install -q -r "${CODE_DIR}/requirements.txt" 2>/dev/null \
  || pip install -q fairlearn

# All flags arrive as ContainerArguments and are forwarded verbatim.
exec python3 "${CODE_DIR}/compute_fairness.py" "$@"
