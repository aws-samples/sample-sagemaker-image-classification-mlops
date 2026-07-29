# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "project_name" {
  description = "Name of the project, used as prefix for the state bucket and KMS alias"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "project_name must be lowercase alphanumeric with hyphens only."
  }
}

variable "environment" {
  description = "Deployment environment"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "aws_region" {
  description = "AWS region where the state bucket and KMS key are created"
  type        = string
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

################################################################################
# State Bucket
################################################################################

variable "bucket_name" {
  description = "Name of the S3 bucket for Terraform remote state. If empty, a name is generated from project_name and a random suffix."
  type        = string
  default     = ""
}

variable "force_destroy" {
  description = "Allow Terraform to delete the state bucket even if it contains objects. Set to true only in dev."
  type        = bool
  default     = false
}

variable "noncurrent_version_retention_days" {
  description = "Days to retain non-current state file versions before permanent deletion"
  type        = number
  default     = 90
}

################################################################################
# KMS
################################################################################

variable "kms_key_deletion_window_days" {
  description = "Waiting period (days) before the KMS key is deleted after destroy. 7-30."
  type        = number
  default     = 30

  validation {
    condition     = var.kms_key_deletion_window_days >= 7 && var.kms_key_deletion_window_days <= 30
    error_message = "kms_key_deletion_window_days must be between 7 and 30."
  }
}

variable "kms_key_administrators" {
  description = "IAM ARNs allowed to administer the state encryption KMS key. Defaults to the caller's account root."
  type        = list(string)
  default     = []
}
