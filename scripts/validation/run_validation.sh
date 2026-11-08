#!/bin/sh
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

set -e

CODE_DIR="/opt/ml/processing/input/code"

# A raw ProcessingJob entrypoint does not install requirements.txt, so install
# the pinned image dependencies here. No fallback: a failed install must fail
# the step rather than run with whatever versions happen to resolve.
# Inside the training VPC there is no route to PyPI, so install from the
# wheelhouse scripts/script_uploader.sh uploads next to this script.
if [ -d "${CODE_DIR}/wheels" ]; then
    pip install -q --no-index --find-links "${CODE_DIR}/wheels" -r "${CODE_DIR}/requirements.txt"
else
    pip install -q -r "${CODE_DIR}/requirements.txt"
fi

# All flags (--input-path, --output-path) arrive as ContainerArguments and are
# forwarded verbatim.
exec python3 "${CODE_DIR}/data_validator.py" "$@"
