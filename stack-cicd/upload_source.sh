#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

set -e

# Usage: ./upload_source.sh [folder_path]
# Default to current directory if no path provided
FOLDER_PATH=${1:-.}

# Get S3 bucket name from terraform output
BUCKET_NAME=$(terraform output -raw artifacts_bucket)

if [ -z "$BUCKET_NAME" ]; then
    echo "Error: Could not get S3 bucket name from terraform output"
    exit 1
fi

echo "Creating source.zip from $FOLDER_PATH..."

# Create temporary zip file
TEMP_ZIP="/tmp/source_$(date +%s).zip"

cd "$FOLDER_PATH"

# Check if .gitignore exists and create exclude patterns
if [ -f ".gitignore" ]; then
    echo "Using .gitignore to exclude files..."
    # Create zip excluding common patterns from .gitignore
    zip -r "$TEMP_ZIP" . \
        -x "*.pyc" "__pycache__/*" "*.py[cod]" \
        -x "venv/*" "env/*" "test_env/*" \
        -x ".terraform/*" "*/.terraform/*" "**/.terraform/*" "*.tfstate*" "*.tfplan*" ".terraform.lock.hcl" "*/.terraform.lock.hcl" \
        -x "data/*" "models/*" "*.h5" "*.pkl" \
        -x "*.log" "logs/*" "*.tmp" \
        -x ".DS_Store" ".git/*" \
        -x "*.zip" "*.tar.gz" "output/*" "artifacts/*"
else
    echo "No .gitignore found, zipping all files..."
    zip -r "$TEMP_ZIP" .
fi

echo "Uploading to S3 bucket: $BUCKET_NAME"
if aws s3 cp "$TEMP_ZIP" "s3://$BUCKET_NAME/source.zip"; then
    echo "Successfully uploaded source.zip to S3"
    echo "Pipeline should trigger automatically"
else
    echo "Error uploading to S3"
    exit 1
fi

# Cleanup
rm -f "$TEMP_ZIP"
