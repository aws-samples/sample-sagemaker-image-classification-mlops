# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Purpose     = "ci-cd-pipeline"
  }
}

# Look up the shared state-backend KMS key. CodeBuild projects + CodePipeline
# artifact store reuse this CMK so every project-owned encryption lives under
# one key policy. We read by alias so the key ARN isn't hardcoded.
data "aws_kms_alias" "state" {
  name = "alias/medical-image-classification-terraform-state"
}
