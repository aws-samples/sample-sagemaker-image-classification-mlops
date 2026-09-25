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
  description = "Percentage of endpoint invocations captured for drift detection. Must match the endpoint module."
  type        = number
  default     = 100
}

variable "data_capture_input" {
  description = "Also capture request payloads in auto-deployed endpoint configs. Must match the endpoint module (default false: Output only)."
  type        = bool
  default     = false
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
# Drift baseline
################################################################################

variable "model_artifacts_bucket" {
  description = "Bucket holding the ensemble artefacts. After each deploy the Lambda copies the package's predictions.json (next to model.tar.gz) from here to drift_baseline_key in the monitoring bucket. Empty disables the baseline refresh."
  type        = string
  default     = ""
}

variable "drift_baseline_key" {
  description = "Object key in the monitoring bucket that the drift job reads its baseline scores from."
  type        = string
  default     = "monitoring/baselines/output-only/statistics.json"
}

variable "artifacts_kms_key_arn" {
  description = "KMS key that encrypts the model artefacts and monitoring buckets, for the baseline copy. Null when they use SSE-S3."
  type        = string
  default     = null
}

################################################################################
# Serving image
################################################################################

variable "serving_image_uri" {
  description = "Inference image every auto-deployed model runs on, pinned by digest. Pass the same value as the endpoint module's serving_image_uri so Terraform-created and auto-deployed models share one image. Empty = use the image recorded in the model package."
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

variable "permissions_boundary_arn" {
  description = "ARN of the permissions boundary attached to the IAM roles this module creates. null leaves them unbounded."
  type        = string
  default     = null
}

variable "volume_kms_key_arn" {
  description = "KMS key ARN for the ML storage volume of the endpoint configs the Lambda creates (real-time mode). Null leaves the volume on the SageMaker default key."
  type        = string
  default     = null
}
