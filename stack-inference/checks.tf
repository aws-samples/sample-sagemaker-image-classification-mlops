# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

check "cloudfront_distribution_health" {
  data "aws_cloudfront_distribution" "health" {
    id = module.frontend_hosting.cloudfront_distribution_id
  }

  assert {
    condition     = data.aws_cloudfront_distribution.health.enabled
    error_message = "CloudFront distribution '${module.frontend_hosting.cloudfront_distribution_id}' is not enabled"
  }
}

# Note: SageMaker endpoint health check is not possible via data source
# (aws_sagemaker_endpoint data source does not exist in the AWS provider).
# Use the CLI to verify: aws sagemaker describe-endpoint --endpoint-name medical-image-classification-endpoint
