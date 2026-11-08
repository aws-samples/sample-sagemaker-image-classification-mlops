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

  # CloudTrail publishing to an SNS topic encrypted with this CMK. The key
  # policy statement from the Amazon SNS key management guide, limited with
  # aws:SourceAccount and aws:SourceArn to this account's trails (or the one
  # trail the caller names) against the confused deputy problem.
  cloudtrail_sns_statements = var.enable_cloudtrail_sns_grant ? [
    {
      Sid       = "AllowCloudTrailPublishToEncryptedTopic"
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action = [
        "kms:GenerateDataKey*",
        "kms:Decrypt",
      ]
      Resource = "*"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
        ArnLike = {
          "aws:SourceArn" = coalesce(var.cloudtrail_source_arn, "arn:aws:cloudtrail:*:${data.aws_caller_identity.current.account_id}:trail/*")
        }
      }
    }
  ] : []

  # CloudWatch alarms publishing to an SNS topic encrypted with this CMK
  # (the Amazon SNS key management guide lists cloudwatch.amazonaws.com as the
  # event source principal). Limited to alarms in this account and Region.
  cloudwatch_alarm_statements = var.enable_cloudwatch_alarms_grant ? [
    {
      Sid       = "AllowCloudWatchAlarmsToEncryptedTopic"
      Effect    = "Allow"
      Principal = { Service = "cloudwatch.amazonaws.com" }
      Action = [
        "kms:GenerateDataKey*",
        "kms:Decrypt",
      ]
      Resource = "*"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
        ArnLike = {
          "aws:SourceArn" = "arn:aws:cloudwatch:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:alarm:*"
        }
      }
    }
  ] : []

  # CloudFront reading SSE-KMS objects through origin access control (the
  # CloudFront OAC guide's key policy statement), limited to distributions in
  # this account because the distribution ID is not known here.
  cloudfront_statements = var.enable_cloudfront_grant ? [
    {
      Sid       = "AllowCloudFrontOacDecrypt"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = ["kms:Decrypt"]
      Resource  = "*"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
        ArnLike = {
          "aws:SourceArn" = "arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/*"
        }
      }
    }
  ] : []
}

# nosemgrep: terraform.aws.security.aws-kms-no-rotation.aws-kms-no-rotation - enable_key_rotation defaults to true and every caller passes true
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
        # The default key policy's grant statement for AWS services. Without
        # it, setting key_administrators leaves IAM policies unable to allow
        # kms:CreateGrant, which SageMaker volumes and Lambda need.
        Sid    = "EnableGrantsForAwsResources"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = [
          "kms:CreateGrant",
          "kms:ListGrants",
          "kms:RevokeGrant",
        ]
        Resource  = "*"
        Condition = { Bool = { "kms:GrantIsForAWSResource" = "true" } }
      },
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${data.aws_region.current.region}.amazonaws.com"
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
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*"
          }
        }
      }
    ], local.cloudtrail_statements, local.cloudtrail_sns_statements, local.cloudwatch_alarm_statements, local.cloudfront_statements)
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
