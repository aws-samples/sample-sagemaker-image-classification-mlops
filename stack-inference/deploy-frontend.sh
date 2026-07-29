#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Deploy Frontend Script
set -e

echo "🚀 Deploying Medical Image Classification Frontend..."

# Check if we're in the right directory
if [ ! -f "main.tf" ]; then
    echo "❌ Error: Please run this script from the inference directory"
    exit 1
fi

# Check if HTML file exists
if [ ! -f "static-frontend/index.html" ]; then
    echo "❌ Error: Frontend HTML file not found at static-frontend/index.html"
    exit 1
fi

echo "📋 Step 1: Initializing Terraform..."
terraform init

echo "📋 Step 2: Planning deployment..."
terraform plan

echo "📋 Step 3: Applying infrastructure..."
terraform apply -auto-approve

echo "📋 Step 4: Getting outputs..."
API_URL=$(terraform output -raw api_gateway_url)
FRONTEND_URL=$(terraform output -raw frontend_cloudfront_url)
S3_BUCKET=$(terraform output -raw frontend_s3_bucket)

echo "📋 Step 5: Updating HTML with API endpoint..."
# Update the HTML file with the actual API Gateway URL
sed -i.bak "s|https://your-api-gateway-url.execute-api.us-east-1.amazonaws.com/prod/predict|${API_URL}/predict|g" static-frontend/index.html

echo "📋 Step 6: Re-uploading updated HTML..."
aws s3 cp static-frontend/index.html s3://${S3_BUCKET}/index.html --content-type "text/html"

echo "📋 Step 7: Invalidating CloudFront cache..."
DISTRIBUTION_ID=$(terraform output -raw frontend_cloudfront_distribution_id 2>/dev/null || echo "")
if [ ! -z "$DISTRIBUTION_ID" ]; then
    aws cloudfront create-invalidation --distribution-id $DISTRIBUTION_ID --paths "/*"
    echo "✅ CloudFront cache invalidated"
else
    echo "⚠️  CloudFront distribution ID not found, skipping cache invalidation"
fi

echo ""
echo "🎉 Frontend deployment completed successfully!"
echo ""
echo "📱 Frontend URL: $FRONTEND_URL"
echo "🔗 API Gateway URL: $API_URL"
echo ""
echo "📝 Next steps:"
echo "1. Wait 2-3 minutes for CloudFront distribution to deploy"
echo "2. Open the frontend URL in your browser"
echo "3. Upload a medical histopathology image"
echo "4. Get AI-powered predictions!"
echo ""
echo "💡 Note: If you see 'API endpoint not configured' error, wait a few minutes for DNS propagation"
