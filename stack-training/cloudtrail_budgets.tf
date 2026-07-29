# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

resource "random_id" "cloudtrail_suffix" {
  count       = var.enable_cloudtrail ? 1 : 0
  byte_length = 4
}

module "s3_cloudtrail_logs" {
  count  = var.enable_cloudtrail ? 1 : 0
  source = "../modules/terraform-aws-s3"

  bucket_name         = "${var.project_name}-${var.environment}-cloudtrail-${random_id.cloudtrail_suffix[0].hex}"
  force_destroy       = var.bucket_defaults.force_destroy
  kms_key_arn         = module.kms.key_arn
  enable_versioning   = true
  block_public_access = true

  # This bucket has its own aws_s3_bucket_policy (CloudTrail write grants +
  # the SSL-only deny below), so the module must not also attach one.
  enable_ssl_enforcement = false

  # Expire old CloudTrail logs after 400 days - balances audit retention
  # (HIPAA requires 6 years but most orgs ship CloudTrail to a SIEM for
  # long-term retention and only keep ~1 year in S3).
  lifecycle_rules = [{
    id                              = "expire-old-logs"
    status                          = "Enabled"
    expiration_days                 = var.cloudtrail_retention_days
    noncurrent_version_days         = 30
    abort_incomplete_multipart_days = 7
  }]

  tags = merge(local.common_tags, { Purpose = "cloudtrail-logs" })
}

# Bucket policy that grants CloudTrail service principal the write access
# it needs. AWS-documented required statements.
resource "aws_s3_bucket_policy" "cloudtrail" {
  count  = var.enable_cloudtrail ? 1 : 0
  bucket = module.s3_cloudtrail_logs[0].bucket_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = module.s3_cloudtrail_logs[0].bucket_arn
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = "arn:aws:cloudtrail:${var.aws_region}:${data.aws_caller_identity.current.account_id}:trail/${var.project_name}-audit-trail"
          }
        }
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${module.s3_cloudtrail_logs[0].bucket_arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"  = "bucket-owner-full-control"
            "AWS:SourceArn" = "arn:aws:cloudtrail:${var.aws_region}:${data.aws_caller_identity.current.account_id}:trail/${var.project_name}-audit-trail"
          }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          module.s3_cloudtrail_logs[0].bucket_arn,
          "${module.s3_cloudtrail_logs[0].bucket_arn}/*"
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })
}

resource "aws_cloudtrail" "audit" {
  count = var.enable_cloudtrail ? 1 : 0

  name           = "${var.project_name}-audit-trail"
  s3_bucket_name = module.s3_cloudtrail_logs[0].bucket_id

  # Stream events to CloudWatch Logs for near-real-time alerting on
  # critical API calls (e.g., CreateAccessKey, PutBucketPolicy).
  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail[0].arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_cwl[0].arn

  # SNS topic for delivery notifications - downstream tooling (SecurityHub
  # forwarders, ML-ops alerting, etc.) subscribe here instead of polling S3.
  # Optional: CloudTrail cannot publish to an SNS topic encrypted with the
  # AWS-managed alias/aws/sns key (its key policy can't be edited to grant
  # CloudTrail), so the topic + this wiring are gated behind
  # enable_cloudtrail_sns. The audit trail itself works without it.
  sns_topic_name = var.enable_cloudtrail_sns ? aws_sns_topic.cloudtrail_notifications[0].name : null

  # Log file integrity validation lets us detect if logs are tampered with
  # after the fact. CloudTrail signs each log digest and a monthly summary.
  enable_log_file_validation = true

  # Cover all regions - audit trail for a single-region project still wants
  # to catch cross-region API calls (e.g., an attacker creating resources
  # in us-west-2 to hide them).
  is_multi_region_trail         = true
  include_global_service_events = true

  # Encrypt with the project KMS key (same key protects everything else).
  kms_key_id = module.kms.key_arn

  # Require bucket policy (+ SNS topic policy when enabled) in place before the
  # trail starts writing. depends_on tolerates the SNS resources having count 0.
  depends_on = [
    aws_s3_bucket_policy.cloudtrail,
    aws_sns_topic_policy.cloudtrail_notifications,
    aws_cloudwatch_log_group.cloudtrail,
  ]

  tags = merge(local.common_tags, { Purpose = "audit-trail" })
}

# CloudWatch log group that CloudTrail streams events into. KMS-encrypted
# with the project CMK; 400-day retention to match S3 audit trail policy.
resource "aws_cloudwatch_log_group" "cloudtrail" {
  count = var.enable_cloudtrail ? 1 : 0

  name              = "/aws/cloudtrail/${var.project_name}"
  retention_in_days = var.cloudtrail_retention_days
  kms_key_id        = module.kms.key_arn
  tags              = merge(local.common_tags, { Purpose = "audit-trail" })
}

# IAM role that CloudTrail assumes to write to the log group.
resource "aws_iam_role" "cloudtrail_cwl" {
  count = var.enable_cloudtrail ? 1 : 0

  name = "${var.project_name}-cloudtrail-cwl-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "cloudtrail_cwl" {
  count = var.enable_cloudtrail ? 1 : 0

  name = "${var.project_name}-cloudtrail-cwl-policy"
  role = aws_iam_role.cloudtrail_cwl[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.cloudtrail[0].arn}:*"
    }]
  })
}

# SNS topic CloudTrail publishes log-file-delivery notifications to.
# Using AWS-managed alias/aws/sns so the CloudTrail service principal
# can publish without a custom key-policy grant.
resource "aws_sns_topic" "cloudtrail_notifications" {
  count = var.enable_cloudtrail && var.enable_cloudtrail_sns ? 1 : 0

  name              = "${var.project_name}-cloudtrail-notifications"
  kms_master_key_id = "alias/aws/sns"
  tags              = merge(local.common_tags, { Purpose = "audit-trail" })
}

resource "aws_sns_topic_policy" "cloudtrail_notifications" {
  count = var.enable_cloudtrail && var.enable_cloudtrail_sns ? 1 : 0

  arn = aws_sns_topic.cloudtrail_notifications[0].arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudTrailPublish"
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.cloudtrail_notifications[0].arn
      Condition = {
        StringEquals = {
          "AWS:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })
}

################################################################################
# AWS Budgets - spending guardrails
################################################################################
#
# Proactive alerts before AWS surprises you with a bill. The monthly budget
# notifies at 80% actual and 100% forecasted thresholds; lets on-call catch
# runaway training jobs or exposed API-gateway endpoints before month-end.

resource "aws_budgets_budget" "monthly" {
  count = var.monthly_budget_usd > 0 ? 1 : 0

  name              = "${var.project_name}-monthly"
  budget_type       = "COST"
  limit_amount      = tostring(var.monthly_budget_usd)
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2026-01-01_00:00"

  cost_filter {
    name = "TagKeyValue"
    # AWS expects "user:<TagKey>$<TagValue>". In plain HCL `$${...}` is an
    # escaped literal (no interpolation), so build it with format() to get the
    # literal `$` separator AND the interpolated project name. Otherwise the
    # filter never matches and the budget silently tracks whole-account spend.
    values = [format("user:Project$%s", var.project_name)]
  }

  # Notifications require at least one subscriber, so only emit them when
  # budget_alert_emails is non-empty. An email-less budget still tracks spend
  # in the console; it just can't push alerts.

  # 80% of actual spend - early warning.
  dynamic "notification" {
    for_each = length(var.budget_alert_emails) > 0 ? [1] : []
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = 80
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = var.budget_alert_emails
    }
  }

  # 100% forecasted - AWS projects this month will exceed the limit.
  dynamic "notification" {
    for_each = length(var.budget_alert_emails) > 0 ? [1] : []
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = 100
      threshold_type             = "PERCENTAGE"
      notification_type          = "FORECASTED"
      subscriber_email_addresses = var.budget_alert_emails
    }
  }

  tags = merge(local.common_tags, { Purpose = "cost-governance" })
}
