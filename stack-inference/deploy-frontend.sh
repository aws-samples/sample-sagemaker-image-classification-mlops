#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Refresh the static frontend after `terraform apply` in stack-inference.
#
# Terraform renders static-frontend/index.html.tpl (API URL and API key) and
# uploads it to the frontend bucket, so this script only invalidates the
# CloudFront cache and prints the URLs. It never runs `terraform apply`.
#
# Usage: ./deploy-frontend.sh [aws-profile]
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

PROFILE_ARGS=()
if [ -n "${1:-}" ]; then
    PROFILE_ARGS=(--profile "$1")
elif [ -n "${AWS_PROFILE:-}" ]; then
    PROFILE_ARGS=(--profile "$AWS_PROFILE")
fi

if ! terraform output -raw frontend_cloudfront_distribution_id >/dev/null 2>&1; then
    echo "ERROR: no stack-inference outputs found. Run terraform apply in stack-inference first." >&2
    exit 1
fi

API_URL=$(terraform output -raw api_gateway_url)
FRONTEND_URL=$(terraform output -raw frontend_cloudfront_url)
DISTRIBUTION_ID=$(terraform output -raw frontend_cloudfront_distribution_id)

echo "Invalidating CloudFront distribution ${DISTRIBUTION_ID}..."
aws cloudfront create-invalidation "${PROFILE_ARGS[@]}" \
    --distribution-id "$DISTRIBUTION_ID" --paths "/index.html" >/dev/null

echo ""
echo "Frontend URL: ${FRONTEND_URL}"
echo "API URL:      ${API_URL}"
echo ""
echo "The page sends the API key in the x-api-key header. For command-line calls:"
echo "  terraform output -raw api_key_value"
