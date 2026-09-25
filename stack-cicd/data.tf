# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Purpose     = "ci-cd-pipeline"
  }

  state_bucket_region      = var.state_bucket_region != "" ? var.state_bucket_region : var.aws_region
  state_kms_key_alias      = var.state_kms_key_alias != "" ? var.state_kms_key_alias : "alias/${var.project_name}-terraform-state"
  workload_boundary_name   = var.workload_boundary_name != "" ? var.workload_boundary_name : "${var.project_name}-workload-boundary"
  model_package_group_name = var.model_package_group_name != "" ? var.model_package_group_name : "${var.project_name}-model-package-group"

  account_id = data.aws_caller_identity.current.account_id

  # Roles this stack creates for CI/CD itself. CodeBuild may manage every other
  # project role, but never these two, so it cannot widen its own permissions.
  ci_role_arns = [
    "arn:aws:iam::${local.account_id}:role/${var.project_name}-codebuild-role",
    "arn:aws:iam::${local.account_id}:role/${var.project_name}-codepipeline-role",
  ]

  # Managed policies CodeBuild may attach to project roles: the project's own
  # customer-managed policies plus the AWS managed policies the stacks use.
  attachable_policy_arns = [
    "arn:aws:iam::${local.account_id}:policy/${var.project_name}-*",
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
    "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs",
  ]

  # Passed to every Terraform-running CodeBuild project: backend settings for
  # `terraform init` and the variables the training and inference stacks read.
  terraform_environment = [
    { name = "PROJECT_NAME", value = var.project_name },
    { name = "TF_STATE_BUCKET", value = var.state_bucket_name },
    { name = "TF_STATE_REGION", value = local.state_bucket_region },
    { name = "TF_STATE_KMS_KEY_ID", value = local.state_kms_key_alias },
    { name = "TF_VAR_state_bucket_name", value = var.state_bucket_name },
    { name = "TF_VAR_state_bucket_region", value = local.state_bucket_region },
    { name = "TF_VAR_permissions_boundary_arn", value = data.aws_iam_policy.workload_boundary.arn },
  ]
}

data "aws_caller_identity" "current" {}

# Shared state-backend KMS key. CodeBuild projects and the CodePipeline
# artifact store reuse this CMK so every CI/CD encryption lives under one key
# policy. Read by alias so the key ARN is not hardcoded.
data "aws_kms_alias" "state" {
  name = local.state_kms_key_alias
}

# Permissions boundary created by stack-backend-setup. Every role CodeBuild
# creates or edits must carry it.
data "aws_iam_policy" "workload_boundary" {
  name = local.workload_boundary_name
}
