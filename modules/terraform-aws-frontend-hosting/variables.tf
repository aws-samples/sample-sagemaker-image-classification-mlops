# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "bucket_name" {
  description = "Name of the S3 bucket for frontend hosting"
  type        = string
}

################################################################################
# Template
################################################################################

variable "html_template_path" {
  description = "Path to the HTML template file"
  type        = string
}

variable "template_vars" {
  description = "Variables to inject into the HTML template"
  type        = map(string)
  default     = {}
}

################################################################################
# Tags
################################################################################

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}

################################################################################
# S3 Options
################################################################################

variable "force_destroy" {
  description = "Allow bucket to be destroyed even if it contains objects"
  type        = bool
  default     = false
}

################################################################################
# Access Logging
################################################################################

variable "access_log_bucket_domain" {
  description = "S3 bucket **regional domain name** (e.g. `my-log-bucket.s3.us-east-1.amazonaws.com`) that receives CloudFront access logs. Leave empty to disable access logging. The bucket must have `aws_s3_bucket_ownership_controls` set to `BucketOwnerPreferred` or the log-delivery writes will fail."
  type        = string
  default     = ""
}

################################################################################
# Encryption
################################################################################

variable "kms_key_arn" {
  description = "KMS CMK ARN used for S3 bucket encryption. Null = AES-256 (AWS-managed). CloudFront doesn't read through SSE-KMS objects so this only matters for direct S3 reads, which we block via public-access-block + OAC."
  type        = string
  default     = null
}
