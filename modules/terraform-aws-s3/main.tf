# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

resource "aws_s3_bucket" "this" {
  bucket        = var.bucket_name
  force_destroy = var.force_destroy
  tags          = var.tags
}

################################################################################
# Encryption
################################################################################

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = var.kms_key_arn
      sse_algorithm     = var.kms_key_arn != null ? "aws:kms" : "AES256"
    }
  }
}

################################################################################
# Versioning
################################################################################

resource "aws_s3_bucket_versioning" "this" {
  count  = var.enable_versioning ? 1 : 0
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}

################################################################################
# Public Access
################################################################################

resource "aws_s3_bucket_public_access_block" "this" {
  count  = var.block_public_access ? 1 : 0
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

################################################################################
# SSL / TLS enforcement
################################################################################
#
# Deny every S3 action over plaintext HTTP. Without this, data-in-transit to
# buckets holding training data, model artifacts, CI/CD artifacts, and
# inference results can occur unencrypted. Disabled for buckets whose full
# policy is managed by the caller (see var.enable_ssl_enforcement) to avoid
# two aws_s3_bucket_policy resources targeting the same bucket.

resource "aws_s3_bucket_policy" "ssl_only" {
  count  = var.enable_ssl_enforcement ? 1 : 0
  bucket = aws_s3_bucket.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.this.arn,
          "${aws_s3_bucket.this.arn}/*"
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })

  # The public-access-block (block_public_policy = true) must exist before we
  # attach a bucket policy, otherwise the Deny-with-Principal "*" can be
  # misread as a public grant during apply ordering.
  depends_on = [aws_s3_bucket_public_access_block.this]
}

################################################################################
# EventBridge
################################################################################

resource "aws_s3_bucket_notification" "eventbridge" {
  count       = var.enable_eventbridge ? 1 : 0
  bucket      = aws_s3_bucket.this.id
  eventbridge = true
}

################################################################################
# Lifecycle
################################################################################

# Apply lifecycle rules. We ALWAYS include a baseline rule that aborts
# incomplete multipart uploads after `var.abort_incomplete_multipart_days`
# - stale multiparts silently accumulate storage cost because they're
# invisible to the console. On top of that, versioned buckets should set
# `noncurrent_version_days` in their caller-supplied rules so old object
# versions don't accumulate forever.
resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  # Always-on baseline: abort stale multipart uploads.
  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = var.abort_incomplete_multipart_days
    }
  }

  dynamic "rule" {
    for_each = var.lifecycle_rules
    content {
      id     = rule.value.id
      status = rule.value.status

      # Apply to all objects unless the caller provides a prefix filter.
      dynamic "filter" {
        for_each = rule.value.prefix != null ? [1] : []
        content {
          prefix = rule.value.prefix
        }
      }

      dynamic "noncurrent_version_expiration" {
        for_each = rule.value.noncurrent_version_days != null ? [1] : []
        content {
          noncurrent_days = rule.value.noncurrent_version_days
        }
      }

      dynamic "expiration" {
        for_each = rule.value.expiration_days != null ? [1] : []
        content {
          days = rule.value.expiration_days
        }
      }

      dynamic "abort_incomplete_multipart_upload" {
        for_each = rule.value.abort_incomplete_multipart_days != null ? [1] : []
        content {
          days_after_initiation = rule.value.abort_incomplete_multipart_days
        }
      }
    }
  }

  # Terraform needs to wait for versioning to be settled before the
  # lifecycle configuration references noncurrent-version rules.
  depends_on = [aws_s3_bucket_versioning.this]
}


################################################################################
# (Cross-region replication removed 2026-05 - no buckets in this project
#  needed DR coverage. Training data is a public dataset; models are
#  re-trainable; the CloudTrail and SBOM buckets don't need cross-region
#  redundancy. Add back to this module if a real DR requirement arises.)
################################################################################

################################################################################
# Server Access Logging (optional)
################################################################################
#
# When `logging_target_bucket` is set, every request to this bucket is logged
# to the target bucket under `logging_target_prefix`. Useful for audit trails
# on sensitive buckets (CloudTrail, raw data). Skip on high-traffic buckets
# where the log volume would dominate cost.

resource "aws_s3_bucket_logging" "this" {
  count = var.logging_target_bucket != null ? 1 : 0

  bucket        = aws_s3_bucket.this.id
  target_bucket = var.logging_target_bucket
  target_prefix = coalesce(var.logging_target_prefix, "${aws_s3_bucket.this.id}/")
}
