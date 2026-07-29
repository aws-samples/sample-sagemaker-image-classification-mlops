# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "bucket_name" {
  description = "Name of the S3 bucket"
  type        = string
}

variable "force_destroy" {
  description = "Allow bucket to be destroyed even if it contains objects"
  type        = bool
  default     = false
}

################################################################################
# Encryption
################################################################################

variable "kms_key_arn" {
  description = "ARN of the KMS key for encryption (optional)"
  type        = string
  default     = null
}

################################################################################
# Versioning
################################################################################

variable "enable_versioning" {
  description = "Enable versioning on the bucket"
  type        = bool
  default     = false
}

################################################################################
# Public Access
################################################################################

variable "block_public_access" {
  description = "Block all public access to the bucket"
  type        = bool
  default     = true
}

variable "enable_ssl_enforcement" {
  description = "Attach a bucket policy that denies all non-TLS (HTTP) access via the aws:SecureTransport condition. Default true. Set false when the caller manages the full bucket policy itself (e.g. the CloudTrail logs bucket has its own policy resource) to avoid two aws_s3_bucket_policy resources fighting over the same bucket."
  type        = bool
  default     = true
}

################################################################################
# EventBridge
################################################################################

variable "enable_eventbridge" {
  description = "Enable EventBridge notifications for S3 events"
  type        = bool
  default     = false
}

################################################################################
# Lifecycle
################################################################################

variable "abort_incomplete_multipart_days" {
  description = "Days after which incomplete multipart uploads are aborted. Applied as a baseline lifecycle rule on every bucket (stale multiparts don't show up in the console and silently accumulate cost)."
  type        = number
  default     = 7
}

variable "lifecycle_rules" {
  description = <<-EOT
    Optional lifecycle rules for the bucket. Each rule may specify any of:
    - noncurrent_version_days: expire non-current object versions after N days (versioned buckets only)
    - expiration_days: expire current objects after N days
    - abort_incomplete_multipart_days: abort stale multipart uploads after N days
    - prefix: apply rule only to objects under this key prefix
    For versioned buckets we strongly recommend at least
    noncurrent_version_days, otherwise old versions accumulate forever.
  EOT
  type = list(object({
    id                              = string
    status                          = optional(string, "Enabled")
    prefix                          = optional(string)
    noncurrent_version_days         = optional(number)
    expiration_days                 = optional(number)
    abort_incomplete_multipart_days = optional(number)
  }))
  default = []
}

################################################################################
# Tags
################################################################################

variable "tags" {
  description = "Tags to apply to the bucket"
  type        = map(string)
  default     = {}
}

################################################################################
# Server Access Logging
################################################################################

variable "logging_target_bucket" {
  description = "Name of a separate S3 bucket that receives server-access logs for this bucket. Null = no logging. The target bucket must grant PutObject to the log-delivery principal."
  type        = string
  default     = null
}

variable "logging_target_prefix" {
  description = "Object-key prefix under logging_target_bucket for this bucket's logs. Null = <source-bucket-name>/ (easy grouping when many buckets log to one destination)."
  type        = string
  default     = null
}
