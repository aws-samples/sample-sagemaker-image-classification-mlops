# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

data "aws_caller_identity" "current" {}

locals {
  kms_key_alias          = var.kms_key_alias != "" ? var.kms_key_alias : "${var.project_name}-terraform-state"
  workload_boundary_name = var.workload_boundary_name != "" ? var.workload_boundary_name : "${var.project_name}-workload-boundary"
  # Resource-name prefix of the stacks the boundary governs.
  workload_prefix   = var.workload_project_name != "" ? var.workload_project_name : var.project_name
  state_bucket_name = var.bucket_name != "" ? var.bucket_name : "${var.project_name}-tfstate-${random_id.suffix[0].hex}"
}

module "kms" {
  source  = "terraform-aws-modules/kms/aws"
  version = "~> 4.0"

  description             = "Encryption key for ${var.project_name} Terraform state"
  deletion_window_in_days = var.kms_key_deletion_window_days
  enable_key_rotation     = true

  # Default policy includes the account root; key_administrators adds further principals.
  key_administrators = var.kms_key_administrators

  # The stack-cicd CodeBuild log groups are encrypted with this key: the
  # CloudWatch Logs key policy statement, limited by encryption context to
  # those log groups.
  key_statements = [
    {
      sid = "AllowCloudWatchLogsForCodeBuildLogGroups"
      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:Describe*",
      ]
      resources = ["*"]
      principals = [{
        type        = "Service"
        identifiers = ["logs.${var.aws_region}.amazonaws.com"]
      }]
      condition = [{
        test     = "ArnLike"
        variable = "kms:EncryptionContext:aws:logs:arn"
        values   = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${local.workload_prefix}-*"]
      }]
    },
  ]

  aliases = [local.kms_key_alias]
}

################################################################################
# Random suffix (only when bucket_name is not provided)
################################################################################

resource "random_id" "suffix" {
  count       = var.bucket_name == "" ? 1 : 0
  byte_length = 4
}

################################################################################
# S3 bucket for remote state
################################################################################

# KICS: Terraform state bucket; no S3 access logging in the sample, CloudTrail records API access
# kics-scan ignore-line
module "state_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 5.0"

  bucket = local.state_bucket_name

  force_destroy = var.force_destroy

  # Security: block all public access, enforce TLS, require SSE-KMS
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  attach_deny_insecure_transport_policy = true
  attach_require_latest_tls_policy      = true

  # Encryption at rest with the KMS key above
  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        kms_master_key_id = module.kms.key_arn
        sse_algorithm     = "aws:kms"
      }
      bucket_key_enabled = true
    }
  }

  # Versioning is required for safe state storage (rollback, history)
  # KICS: versioning is enabled below (status = Enabled); KICS does not read the module input
  # kics-scan ignore-line
  versioning = {
    status     = "Enabled"
    mfa_delete = "Disabled"
  }

  # Retain old state versions then expire
  lifecycle_rule = [{
    id     = "expire-noncurrent-state-versions"
    status = "Enabled"

    noncurrent_version_expiration = {
      noncurrent_days = var.noncurrent_version_retention_days
    }

    abort_incomplete_multipart_upload_days = 7
  }]

  # Ownership controls
  control_object_ownership = true
  object_ownership         = "BucketOwnerEnforced"
}

################################################################################
# Permissions boundary for workload roles
################################################################################

# Every IAM role the training and inference stacks create carries this
# boundary, and the CI/CD CodeBuild role may only create or change roles that
# carry it. A role's effective permissions are the intersection of its own
# policies and the boundary, so no project role (including one CodeBuild
# edits) can grant itself IAM, Organizations or account-level access. It
# lives in this stack because it must exist before the first local or CI
# apply of the other stacks.
resource "aws_iam_policy" "workload_boundary" {
  # A boundary is a ceiling, not a grant: each role's own policies stay scoped
  # to project resources, and the boundary only removes everything else.
  #checkov:skip=CKV_AWS_286:Permissions boundary, grants nothing on its own
  #checkov:skip=CKV_AWS_288:Permissions boundary, grants nothing on its own
  #checkov:skip=CKV_AWS_289:Permissions boundary, grants nothing on its own
  #checkov:skip=CKV_AWS_290:Permissions boundary, grants nothing on its own
  #checkov:skip=CKV_AWS_355:Permissions boundary, grants nothing on its own
  name        = local.workload_boundary_name
  description = "Permissions boundary for ${var.project_name} workload roles"

  # KICS: permissions boundary: a ceiling that grants nothing on its own
  # kics-scan ignore-line
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WorkloadServices"
        Effect = "Allow"
        # nosemgrep: terraform.lang.security.iam.no-iam-creds-exposure.no-iam-creds-exposure, terraform.lang.security.iam.no-iam-data-exfiltration.no-iam-data-exfiltration, terraform.lang.security.iam.no-iam-resource-exposure.no-iam-resource-exposure - permissions boundary, a ceiling that grants nothing on its own
        Action = [
          "application-autoscaling:*",
          "bedrock:*",
          "cloudwatch:*",
          "ecr:*",
          "events:*",
          "inspector2:ListFindings",
          "logs:*",
          "sagemaker:*",
          "sagemaker-mlflow:*",
          "sns:*",
          "sqs:*",
          "sts:GetCallerIdentity",
          "xray:*",
        ]
        Resource = "*"
      },
      {
        # Project buckets only, plus any extra bucket a workload must read
        # (for example the one holding backbone_weights_s3_uri).
        Sid    = "ProjectBuckets"
        Effect = "Allow"
        Action = ["s3:*"]
        Resource = concat(
          [
            "arn:aws:s3:::${local.workload_prefix}-*",
            "arn:aws:s3:::${local.workload_prefix}-*/*",
          ],
          var.boundary_extra_s3_arns,
        )
      },
      {
        # Bucket names are global, so the project prefix must not reach a
        # bucket of the same name in another account.
        Sid    = "DenyProjectNamedBucketsInOtherAccounts"
        Effect = "Deny"
        Action = ["s3:*"]
        Resource = [
          "arn:aws:s3:::${local.workload_prefix}-*",
          "arn:aws:s3:::${local.workload_prefix}-*/*",
        ]
        Condition = {
          StringNotEqualsIfExists = { "s3:ResourceAccount" = data.aws_caller_identity.current.account_id }
        }
      },
      {
        Sid    = "ProjectFunctionsAndBuilds"
        Effect = "Allow"
        Action = [
          "lambda:*",
          "codebuild:*",
        ]
        Resource = [
          "arn:aws:lambda:*:${data.aws_caller_identity.current.account_id}:function:${local.workload_prefix}-*",
          "arn:aws:codebuild:*:${data.aws_caller_identity.current.account_id}:project/${local.workload_prefix}-*",
          "arn:aws:codebuild:*:${data.aws_caller_identity.current.account_id}:report-group/${local.workload_prefix}-*",
        ]
      },
      {
        # Project keys carry the Project tag (provider default_tags).
        Sid      = "ProjectKeys"
        Effect   = "Allow"
        Action   = ["kms:*"]
        Resource = "arn:aws:kms:*:${data.aws_caller_identity.current.account_id}:key/*"
        Condition = {
          StringEquals = { "aws:ResourceTag/Project" = local.workload_prefix }
        }
      },
      {
        # Jobs in a VPC (training VPC or vpc_config) manage their own ENIs.
        Sid    = "VpcJobNetworking"
        Effect = "Allow"
        # nosemgrep: terraform.lang.security.iam.no-iam-resource-exposure.no-iam-resource-exposure, terraform.lang.security.iam.no-iam-resource-exposure - permissions boundary; ENI actions only reach jobs that set vpc_config
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:CreateNetworkInterfacePermission",
          "ec2:DeleteNetworkInterface",
          "ec2:DeleteNetworkInterfacePermission",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeVpcs",
          "ec2:DescribeDhcpOptions",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
        ]
        Resource = "*"
      },
      {
        # SageMaker pipelines and jobs pass the project execution role to the
        # jobs they start. Nothing else in IAM is reachable through the boundary.
        Sid    = "PassProjectRoles"
        Effect = "Allow"
        # nosemgrep: terraform.lang.security.iam.no-iam-resource-exposure.no-iam-resource-exposure, terraform.lang.security.iam.no-iam-resource-exposure - permissions boundary; PassRole limited to project-prefixed roles
        Action   = ["iam:GetRole", "iam:PassRole"]
        Resource = "arn:aws:iam::*:role/${local.workload_prefix}-*"
      },
      {
        # The CI/CD roles match the project prefix but must never be handed to
        # a workload service.
        Sid    = "DenyPassingCiRoles"
        Effect = "Deny"
        Action = ["iam:PassRole"]
        Resource = [
          "arn:aws:iam::*:role/${local.workload_prefix}-codebuild-role",
          "arn:aws:iam::*:role/${local.workload_prefix}-codepipeline-role",
        ]
      },
      {
        # The stack-cicd deploy projects run as the CI/CD role and match the
        # project prefix above. A workload role that could start one (with a
        # buildspec override), open a sandbox in it or change it would run
        # commands as that role, so all CodeBuild access to them is denied.
        Sid    = "DenyCiBuildProjects"
        Effect = "Deny"
        Action = ["codebuild:*"]
        Resource = [
          "arn:aws:codebuild:*:${data.aws_caller_identity.current.account_id}:project/${local.workload_prefix}-baseline-model-creation",
          "arn:aws:codebuild:*:${data.aws_caller_identity.current.account_id}:project/${local.workload_prefix}-training-deploy",
          "arn:aws:codebuild:*:${data.aws_caller_identity.current.account_id}:project/${local.workload_prefix}-script-upload",
          "arn:aws:codebuild:*:${data.aws_caller_identity.current.account_id}:project/${local.workload_prefix}-inference-deploy",
        ]
      },
    ]
  })
}
