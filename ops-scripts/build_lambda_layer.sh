#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Build Lambda layer with Pillow and numpy for Python 3.13
# This script creates a Lambda-compatible layer using Amazon Linux 2023 environment

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LAYER_DIR="$PROJECT_ROOT/stack-inference/lambda-layers"
LAYER_ZIP="$LAYER_DIR/pillow-numpy-layer.zip"
BUILD_DIR="/tmp/lambda-layer-build"

# Versions pinned to match Lambda runtime and CodeBuild buildspec
PYTHON_VERSION="3.13"
PILLOW_VERSION="12.2.0"
NUMPY_VERSION="2.4.4"

echo "=========================================="
echo "Building Lambda Layer: Pillow + NumPy"
echo "  Python:  $PYTHON_VERSION"
echo "  Pillow:  $PILLOW_VERSION"
echo "  NumPy:   $NUMPY_VERSION"
echo "=========================================="

# Clean up any previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/python/lib/python${PYTHON_VERSION}/site-packages"

echo "Installing packages for Python ${PYTHON_VERSION} Lambda runtime..."

PIP_CMD="$(command -v uv || command -v pip3 || command -v pip)"
if [ -z "$PIP_CMD" ]; then
    echo "ERROR: neither uv nor pip found on PATH" >&2
    echo "Install uv: curl -LsSf https://astral.sh/uv/install.sh | sh" >&2
    exit 1
fi

# uv has a slightly different invocation - it takes the install subcommand
# as `uv pip install ...`. Detect which tool we resolved to and build the
# appropriate argv.
if [[ "$PIP_CMD" == *"uv" ]]; then
    echo "Using uv (10-100x faster than pip)"
    INSTALL_CMD=("$PIP_CMD" pip install)
    # uv uses --python-platform instead of --platform + --implementation
    PLATFORM_ARGS=(--python-platform x86_64-manylinux2014 --python-version "$PYTHON_VERSION" --only-binary=:all:)
else
    echo "Using pip (install uv for ~10x speedup: https://astral.sh/uv)"
    INSTALL_CMD=("$PIP_CMD" install)
    PLATFORM_ARGS=(--platform manylinux2014_x86_64 --implementation cp --python-version "$PYTHON_VERSION" --only-binary=:all:)
fi

# Install packages to the Lambda layer structure
# Using manylinux2014 platform ensures compatibility with Lambda's Amazon Linux 2023
"${INSTALL_CMD[@]}" \
    --target="$BUILD_DIR/python/lib/python${PYTHON_VERSION}/site-packages" \
    "${PLATFORM_ARGS[@]}" \
    --upgrade \
    "Pillow==${PILLOW_VERSION}" \
    "numpy==${NUMPY_VERSION}"

# Verify installation
echo ""
echo "Verifying installed packages..."
INSTALLED_PILLOW=$(python3 -c "import sys; sys.path.insert(0, '$BUILD_DIR/python/lib/python${PYTHON_VERSION}/site-packages'); from PIL import __version__; print(__version__)" 2>/dev/null || echo "N/A")
INSTALLED_NUMPY=$(python3 -c "import sys; sys.path.insert(0, '$BUILD_DIR/python/lib/python${PYTHON_VERSION}/site-packages'); import numpy; print(numpy.__version__)" 2>/dev/null || echo "N/A")

echo "  Pillow version: $INSTALLED_PILLOW"
echo "  NumPy version: $INSTALLED_NUMPY"

# Create the zip file
echo ""
echo "Creating Lambda layer zip..."
mkdir -p "$LAYER_DIR"
cd "$BUILD_DIR"
rm -f "$LAYER_ZIP"
zip -r9 "$LAYER_ZIP" python/

# Show final size
LAYER_SIZE=$(du -h "$LAYER_ZIP" | cut -f1)
echo ""
echo "=========================================="
echo "Lambda layer built successfully!"
echo "  Location: $LAYER_ZIP"
echo "  Size: $LAYER_SIZE"
echo "=========================================="

# Cleanup
rm -rf "$BUILD_DIR"
