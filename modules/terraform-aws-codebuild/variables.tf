# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "name" {
  description = "Name of the CodeBuild project"
  type        = string
}

variable "description" {
  description = "Description of the CodeBuild project"
  type        = string
  default     = null
}

variable "service_role_arn" {
  description = "ARN of the IAM role for CodeBuild"
  type        = string
}

variable "build_timeout" {
  description = "Build timeout in minutes"
  type        = number
  default     = 60
}

################################################################################
# Artifacts
################################################################################

variable "artifacts_type" {
  description = "Type of build output artifacts"
  type        = string
  default     = "CODEPIPELINE"
}

################################################################################
# Environment
################################################################################

variable "compute_type" {
  description = "Compute type for the build environment"
  type        = string
  default     = "BUILD_GENERAL1_MEDIUM"
}

variable "build_image" {
  description = "Docker image for the build environment. Default is the latest AL2023-based curated CodeBuild image."
  type        = string
  default     = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
}

variable "environment_type" {
  description = "Type of build environment"
  type        = string
  default     = "LINUX_CONTAINER"
}

variable "image_pull_credentials_type" {
  description = "Type of credentials for pulling the build image"
  type        = string
  default     = "CODEBUILD"
}

variable "environment_variables" {
  description = "Environment variables for the build"
  type = list(object({
    name  = string
    value = string
  }))
  default = []
}

################################################################################
# Source
################################################################################

variable "source_type" {
  description = "Type of source provider"
  type        = string
  default     = "CODEPIPELINE"
}

variable "buildspec_path" {
  description = "Path to the buildspec file"
  type        = string
}

################################################################################
# VPC (optional)
################################################################################

variable "vpc_config" {
  description = "Optional VPC configuration - enables CodeBuild to reach private resources (RDS, internal APIs, private artifact repos). Leave null for public-internet builds."
  type = object({
    vpc_id             = string
    subnets            = list(string)
    security_group_ids = list(string)
  })
  default = null
}

################################################################################
# Tags
################################################################################

variable "tags" {
  description = "Tags to apply to the CodeBuild project"
  type        = map(string)
  default     = {}
}

################################################################################
# Encryption + Logging
################################################################################

variable "encryption_key_arn" {
  description = "KMS CMK ARN used to encrypt the CodeBuild output/cache. Null = AWS-managed alias/aws/s3 (still encrypted, just not customer-managed). Recommended for production to keep key access within the project's KMS policy."
  type        = string
  default     = null
}

variable "log_group_name" {
  description = "CloudWatch Logs group that CodeBuild writes to. Null = CodeBuild auto-creates `/aws/codebuild/<project-name>` with no KMS encryption."
  type        = string
  default     = null
}

variable "log_stream_name" {
  description = "CloudWatch Logs stream name prefix. Null = default (build ID)."
  type        = string
  default     = null
}
