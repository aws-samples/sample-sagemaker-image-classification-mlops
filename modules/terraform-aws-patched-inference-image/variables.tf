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
