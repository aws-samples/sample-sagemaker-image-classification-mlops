# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  # When no explicit administrators are provided, grant the AWS account root
  # the default "can admin this key" bundle. When administrators ARE provided,
  # only they get admin - root loses admin but retains IAM-evaluated access
  # via its standard identity policies.
  default_admin_arns = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
  admin_arns         = length(var.key_administrators) > 0 ? var.key_administrators : local.default_admin_arns

  # Optional grant so the CloudTrail service can encrypt log files with this
  # CMK. Scoped to trails in this account via the EncryptionContext condition.
  cloudtrail_statements = var.enable_cloudtrail_grant ? [
    {
      Sid       = "AllowCloudTrailEncrypt"
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action = [
        "kms:GenerateDataKey*",
        "kms:DescribeKey",
      ]
      Resource = "*"
      Condition = {
        StringLike = {
          "kms:EncryptionContext:aws:cloudtrail:arn" = "arn:aws:cloudtrail:*:${data.aws_caller_identity.current.account_id}:trail/*"
        }
      }
    }
  ] : []
}

resource "aws_kms_key" "this" {
  description             = var.description
  deletion_window_in_days = var.deletion_window_days
  enable_key_rotation     = var.enable_key_rotation
  tags                    = var.tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid    = "EnableKeyAdministration"
        Effect = "Allow"
        Principal = {
          AWS = local.admin_arns
        }
        Action = [
          "kms:Create*",
          "kms:Describe*",
          "kms:Enable*",
          "kms:List*",
          "kms:Put*",
          "kms:Update*",
          "kms:Revoke*",
          "kms:Disable*",
          "kms:Get*",
          "kms:Delete*",
          "kms:TagResource",
          "kms:UntagResource",
          "kms:ScheduleKeyDeletion",
          "kms:CancelKeyDeletion",
        ]
        Resource = "*"
      },
      {
        # Data-plane actions - the account root (or the caller's equivalent)
        # can always encrypt/decrypt. This is necessary for IAM role policies
        # to grant usage to downstream services (SageMaker, Lambda, etc.).
        Sid    = "EnableKeyUsage"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${data.aws_region.current.id}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          ArnEquals = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:*"
          }
        }
      }
    ], local.cloudtrail_statements)
  })
}

################################################################################
# KMS Alias
################################################################################

resource "aws_kms_alias" "this" {
  count         = var.alias_name != null ? 1 : 0
  name          = var.alias_name
  target_key_id = aws_kms_key.this.key_id
}
