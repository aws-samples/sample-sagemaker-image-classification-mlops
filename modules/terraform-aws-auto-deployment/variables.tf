# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "project_name" {
  description = "Name of the project"
  type        = string
}

variable "model_package_group_name" {
  description = "Name of the SageMaker model package group"
  type        = string
}

################################################################################
# SageMaker Endpoint
################################################################################

variable "endpoint_name" {
  description = "Name of the SageMaker endpoint to update"
  type        = string
}

variable "endpoint_instance_type" {
  description = "EC2 instance type for the endpoint production variant"
  type        = string
  default     = "ml.m5.xlarge"
}

variable "data_capture_sampling_percentage" {
  description = "Percentage of endpoint invocations captured for Model Monitor"
  type        = number
  default     = 100
}

variable "sagemaker_role_arn" {
  description = "ARN of the SageMaker execution role"
  type        = string
}

variable "monitoring_bucket" {
  description = "Name of the monitoring S3 bucket for data capture"
  type        = string
}

################################################################################
# Patched Inference Image
################################################################################

variable "patched_image_uri" {
  description = "ECR URI (optional) of a CVE-patched inference image. When set, the auto-deployer swaps the public DLC image for this one on every deployment."
  type        = string
  default     = ""
}

################################################################################
# Serverless Inference
################################################################################

variable "use_serverless_inference" {
  description = "When true, the auto-deploy Lambda creates serverless endpoint configs instead of instance-based ones. Must match the endpoint module's flag."
  type        = bool
  default     = false
}

variable "serverless_memory_size_mb" {
  description = "Memory (MB) per serverless worker when use_serverless_inference = true."
  type        = number
  default     = 3072
}

variable "serverless_max_concurrency" {
  description = "Max concurrent invocations per serverless variant when use_serverless_inference = true."
  type        = number
  default     = 10
}

################################################################################
# Notifications
################################################################################

variable "sns_topic_arn" {
  description = "ARN of SNS topic for alerts (optional)"
  type        = string
  default     = null
}

################################################################################
# CloudWatch
################################################################################

variable "log_retention_days" {
  description = "CloudWatch log retention in days for the auto-deployment Lambda"
  type        = number
  default     = 14
}

variable "log_kms_key_arn" {
  description = "KMS key ARN used to encrypt the CloudWatch log group. Null = no customer-managed encryption (logs still encrypted at rest with AWS-managed key)."
  type        = string
  default     = null
}

variable "env_kms_key_arn" {
  description = "KMS CMK ARN used to encrypt Lambda environment variables. Null = AWS-managed key (still encrypted)."
  type        = string
  default     = null
}

################################################################################
# Tags
################################################################################

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
