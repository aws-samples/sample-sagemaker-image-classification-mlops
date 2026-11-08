# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "project_name" {
  description = "Project identifier used to prefix resource names"
  type        = string
}

variable "repository_name" {
  description = "Name of the private ECR repository that will hold the patched image"
  type        = string
}

variable "aws_region" {
  description = "AWS region (used at buildspec runtime for ECR login)"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID that owns the target ECR repository"
  type        = string
}

################################################################################
# Source image
################################################################################

variable "source_registry" {
  description = "ECR registry hostname for the source DLC (e.g. 763104351884.dkr.ecr.us-east-1.amazonaws.com)"
  type        = string
}

variable "source_repository" {
  description = "DLC repository name (e.g. tensorflow-inference)"
  type        = string
}

variable "source_tag" {
  description = "Source DLC image tag to base the patched image on"
  type        = string
}

variable "rebuild_schedule_expression" {
  description = "EventBridge schedule for rebuilding the patched image. Weekly by default (Saturdays 05:00 UTC), the day before the stack's Sunday endpoint refresh rolls the newest image out."
  type        = string
  default     = "cron(0 5 ? * SAT *)"
}

################################################################################
# Security
################################################################################

variable "kms_key_arn" {
  description = "KMS key used to encrypt the ECR repository contents"
  type        = string
}

variable "sbom_bucket" {
  description = "S3 bucket (name only, not ARN) where Syft-generated CycloneDX SBOM files are written after each build. Leave empty to disable SBOM generation. Generated files land at s3://<bucket>/sboms/<date-tag>.cdx.json."
  type        = string
  default     = ""
}

variable "sbom_bucket_arn" {
  description = "ARN of the SBOM bucket (required when sbom_bucket is set). Separate from sbom_bucket so the IAM policy can reference the full ARN without string interpolation at apply time."
  type        = string
  default     = ""
}

################################################################################
# Tags
################################################################################

variable "tags" {
  description = "Tags applied to every resource"
  type        = map(string)
  default     = {}
}

variable "build_image_on_create" {
  description = "Trigger one CodeBuild run at apply time (and wait) so a patched image exists before the endpoint and auto-deploy Lambda pin its digest. Requires AWS CLI on the Terraform runner. When false, an image must already be in the repository (built by a separate stage) or the apply fails reading it."
  type        = bool
  default     = true
}

variable "permissions_boundary_arn" {
  description = "ARN of the permissions boundary attached to the IAM roles this module creates. null leaves them unbounded."
  type        = string
  default     = null
}

variable "syft_version" {
  description = "Syft release (without the v) installed to generate the image SBOM."
  type        = string
  default     = "1.56.0"
}

variable "syft_linux_amd64_sha256" {
  description = "SHA-256 of syft_<syft_version>_linux_amd64.tar.gz from that release's checksums.txt. Null uses the checksum pinned for the default syft_version; set it whenever you change syft_version, or the build fails the checksum check."
  type        = string
  default     = null

  validation {
    condition     = var.syft_linux_amd64_sha256 == null || can(regex("^[0-9a-f]{64}$", var.syft_linux_amd64_sha256))
    error_message = "syft_linux_amd64_sha256 must be null or a 64-character lowercase hex SHA-256."
  }
}

variable "scan_block_severity" {
  description = "Scan gate: a new image with an Amazon ECR scan finding at or above this severity is deleted and its build fails, so neither an apply nor the weekly endpoint refresh can pin it; the endpoint keeps the last image that passed. CRITICAL, HIGH, MEDIUM, LOW, or NONE to turn the gate off. With Amazon Inspector enhanced scanning the gate reads the findings through inspector2:ListFindings, which the build role holds."
  type        = string
  default     = "CRITICAL"

  validation {
    condition     = contains(["CRITICAL", "HIGH", "MEDIUM", "LOW", "NONE"], var.scan_block_severity)
    error_message = "scan_block_severity must be CRITICAL, HIGH, MEDIUM, LOW or NONE."
  }
}

variable "log_retention_days" {
  description = "Retention of the build's CloudWatch log group, in days."
  type        = number
  default     = 365
}

variable "alarm_actions" {
  description = "Actions (for example an SNS topic ARN) for the alarm on a failed image build."
  type        = list(string)
  default     = []
}
