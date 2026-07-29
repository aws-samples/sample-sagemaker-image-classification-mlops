# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

resource "aws_codebuild_project" "this" {
  name          = var.name
  description   = var.description
  service_role  = var.service_role_arn
  build_timeout = var.build_timeout

  # KMS CMK used to encrypt the build output + cache. Null = AWS-managed
  # key (still encrypted, just using alias/aws/s3).
  encryption_key = var.encryption_key_arn

  artifacts {
    type = var.artifacts_type
  }

  environment {
    compute_type                = var.compute_type
    image                       = var.build_image
    type                        = var.environment_type
    image_pull_credentials_type = var.image_pull_credentials_type

    dynamic "environment_variable" {
      for_each = var.environment_variables
      content {
        name  = environment_variable.value.name
        value = environment_variable.value.value
      }
    }
  }

  source {
    type      = var.source_type
    buildspec = var.buildspec_path
  }

  # CloudWatch Logs always on - cheap, auditable, and the default place
  # anyone investigating a failed build will look. Caller can point at an
  # existing log group via var.log_group_name to reuse KMS encryption set
  # up elsewhere, otherwise CodeBuild auto-creates one.
  logs_config {
    cloudwatch_logs {
      status      = "ENABLED"
      group_name  = var.log_group_name
      stream_name = var.log_stream_name
    }
  }

  # Optional VPC config - CodeBuild ENI-attached, for private artifact pulls
  # or DB access. Leave unset for fully public builds (default).
  dynamic "vpc_config" {
    for_each = var.vpc_config != null ? [var.vpc_config] : []
    content {
      vpc_id             = vpc_config.value.vpc_id
      subnets            = vpc_config.value.subnets
      security_group_ids = vpc_config.value.security_group_ids
    }
  }

  tags = var.tags
}
