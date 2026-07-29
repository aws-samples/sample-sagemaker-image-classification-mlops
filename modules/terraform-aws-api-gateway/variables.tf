# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "api_name" {
  description = "Name of the API Gateway"
  type        = string
}

variable "stage_name" {
  description = "Stage name for API Gateway deployment"
  type        = string
}

################################################################################
# Lambda Integration
################################################################################

variable "lambda_function_arn" {
  description = "ARN of the Lambda function to integrate with"
  type        = string
}

################################################################################
# CORS
################################################################################

variable "cors_origins" {
  description = "List of allowed CORS origins"
  type        = list(string)
  default     = ["*"]
}

################################################################################
# Throttling
################################################################################

# Stage-wide throttle - applies to every request (authenticated or not).
# AWS account default is 10k req/sec burst, 5k rate. For a medical-image
# demo endpoint we aggressively cap to prevent bill-inflation attacks.
variable "throttling_rate_limit" {
  description = "Stage-wide throttling rate limit (requests per second across all methods)"
  type        = number
  default     = 20

  validation {
    condition     = var.throttling_rate_limit > 0
    error_message = "throttling_rate_limit must be greater than zero."
  }
}

variable "throttling_burst_limit" {
  description = "Stage-wide throttling burst limit (max concurrent requests in a short burst)"
  type        = number
  default     = 50

  validation {
    condition     = var.throttling_burst_limit > 0
    error_message = "throttling_burst_limit must be greater than zero."
  }
}

################################################################################
# Usage Plan (optional)
################################################################################

variable "create_usage_plan" {
  description = "Create an API Gateway usage plan. Enables per-API-key quotas and throttles for authenticated clients."
  type        = bool
  default     = false
}

variable "usage_plan_rate_limit" {
  description = "Per-client rate limit (req/sec) when usage plan is enabled"
  type        = number
  default     = 10
}

variable "usage_plan_burst_limit" {
  description = "Per-client burst limit when usage plan is enabled"
  type        = number
  default     = 20
}

variable "usage_plan_quota_limit" {
  description = "Per-client quota - maximum requests in the `usage_plan_quota_period`"
  type        = number
  default     = 10000
}

variable "usage_plan_quota_period" {
  description = "Quota period for usage plan - DAY / WEEK / MONTH"
  type        = string
  default     = "MONTH"

  validation {
    condition     = contains(["DAY", "WEEK", "MONTH"], var.usage_plan_quota_period)
    error_message = "usage_plan_quota_period must be one of DAY, WEEK, MONTH."
  }
}

################################################################################
# Access logging + X-Ray
################################################################################

variable "enable_access_logging" {
  description = "Create a CloudWatch Logs destination for API Gateway access logs and wire up the IAM role + account settings required to write to it."
  type        = bool
  default     = true
}

variable "enable_xray_tracing" {
  description = "Enable AWS X-Ray tracing on the API Gateway stage. Lets you see end-to-end latency from API GW through Lambda to SageMaker."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Retention in days for the API Gateway access log group"
  type        = number
  default     = 90
}

variable "log_kms_key_arn" {
  description = "Optional KMS key ARN for encrypting the access log group"
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
