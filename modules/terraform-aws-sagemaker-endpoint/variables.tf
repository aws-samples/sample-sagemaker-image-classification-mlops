# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "project_name" {
  description = "Name of the project"
  type        = string
}

variable "endpoint_name" {
  description = "Name of the SageMaker endpoint"
  type        = string
}

variable "execution_role_arn" {
  description = "ARN of the IAM execution role for SageMaker"
  type        = string
}

variable "model_package_group_name" {
  description = "Name of the SageMaker Model Package Group"
  type        = string
}

variable "aws_region" {
  description = "AWS region for SageMaker API calls"
  type        = string
}

################################################################################
# Endpoint Configuration
################################################################################

variable "use_serverless_inference" {
  description = <<-EOT
    When true, provision a SageMaker Serverless Inference variant instead of
    an instance-based real-time variant. Serverless scales to zero when idle
    (large cost savings for low-traffic endpoints like a blog demo) but loses
    several features:

      - No DataCaptureConfig on the endpoint config (Model Monitor cannot
        read captured payloads; your inference handler must log predictions
        itself if drift detection matters).
      - No Application Auto Scaling (scales internally via max_concurrency).
      - Cold starts of 1-5 seconds after idle periods.
      - Max memory = 6 GB, max concurrent requests per variant = 200.

    Default is false to preserve the project's compliance/monitoring story.
    Opt in only when the cost win outweighs these tradeoffs.
  EOT
  type        = bool
  default     = false
}

variable "serverless_memory_size_mb" {
  description = "Memory (MB) allocated per serverless inference request. Valid values: 1024, 2048, 3072, 4096, 5120, 6144. Only used when use_serverless_inference = true."
  type        = number
  default     = 3072

  validation {
    condition     = contains([1024, 2048, 3072, 4096, 5120, 6144], var.serverless_memory_size_mb)
    error_message = "serverless_memory_size_mb must be one of: 1024, 2048, 3072, 4096, 5120, 6144."
  }
}

variable "serverless_max_concurrency" {
  description = "Maximum concurrent invocations per serverless variant (1-200). Only used when use_serverless_inference = true."
  type        = number
  default     = 10

  validation {
    condition     = var.serverless_max_concurrency >= 1 && var.serverless_max_concurrency <= 200
    error_message = "serverless_max_concurrency must be between 1 and 200."
  }
}

variable "initial_instance_count" {
  description = "Initial number of instances for the endpoint"
  type        = number
  default     = 1
}

variable "instance_type" {
  description = "Instance type for the SageMaker endpoint"
  type        = string
  default     = "ml.m5.xlarge"
}

variable "data_capture_sampling_percentage" {
  description = "Percentage of data to capture for monitoring (0-100)"
  type        = number
  default     = 100
}

variable "monitoring_bucket" {
  description = "S3 bucket name for data capture and monitoring output"
  type        = string
}

variable "volume_kms_key_arn" {
  description = "KMS key ARN used to encrypt the ML storage volume attached to real-time (instance-based) inference variants. The volume buffers the model artifact and in-flight inference data (potential PHI for a medical model), so it should use the project CMK rather than the AWS-managed default key. Ignored for serverless variants, which do not attach a volume. Null falls back to the default key."
  type        = string
  default     = null
}

variable "shadow_model_name" {
  description = "Name of an existing SageMaker model to run as a shadow variant (Part 3 shadow testing). The shadow receives a copy of production traffic but its predictions are not returned to callers. Null = no shadow variant. Real-time only."
  type        = string
  default     = null
}

variable "initial_variant_weight" {
  description = "Initial traffic weight for the primary production variant. With one variant this is always 100% of traffic; exposing it lets callers add a weighted canary variant and shift traffic via update_endpoint_weights_and_capacities."
  type        = number
  default     = 1
}

################################################################################
# Auto-Scaling
################################################################################

variable "min_capacity" {
  description = "Minimum number of instances for auto-scaling"
  type        = number
  default     = 1
}

variable "max_capacity" {
  description = "Maximum number of instances for auto-scaling"
  type        = number
  default     = 3
}

variable "target_concurrent_requests_per_model" {
  description = "Target concurrent in-flight requests per model container. Uses the SageMaker high-resolution metric (10s granularity) for sub-minute scale-out detection."
  type        = number
  default     = 5
}

################################################################################
# CloudWatch Alarms
################################################################################

variable "error_rate_threshold" {
  description = "Error rate threshold percentage for the CloudWatch alarm"
  type        = number
  default     = 5
}

variable "latency_threshold" {
  description = "Latency threshold in milliseconds for the CloudWatch alarm"
  type        = number
  default     = 30000
}

################################################################################
# Tags
################################################################################

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

################################################################################
# Deployment
################################################################################

variable "traffic_shift_wait_interval" {
  description = "Wait interval in seconds between each linear traffic shift step"
  type        = number
  default     = 60
}


variable "termination_wait_seconds" {
  description = "Seconds to wait after deployment before terminating old fleet"
  type        = number
  default     = 120
}

variable "deployment_max_timeout" {
  description = "Maximum deployment timeout in seconds (600-14400)"
  type        = number
  default     = 3600
}
