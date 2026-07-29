# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

module "kms" {
  source  = "terraform-aws-modules/kms/aws"
  version = "~> 4.0"

  description             = "Encryption key for ${var.project_name} Terraform state"
  deletion_window_in_days = var.kms_key_deletion_window_days
  enable_key_rotation     = true

  # Default policy includes the account root; key_administrators adds further principals.
  key_administrators = var.kms_key_administrators

  aliases = ["${var.project_name}-terraform-state"]
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

module "state_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 5.0"

  bucket = var.bucket_name != "" ? var.bucket_name : "${var.project_name}-tfstate-${random_id.suffix[0].hex}"

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
