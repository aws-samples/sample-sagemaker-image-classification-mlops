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
# Authentication
################################################################################

variable "authorization_type" {
  description = <<-EOT
    Method authorization for POST /predict and GET /results/{id}.
    "NONE" (default) relies on the API key, usage plan and WAF only: the key
    meters callers but is public once it ships in the static frontend.
    To authenticate users instead:
      - "AWS_IAM": callers sign requests with SigV4; grant execute-api:Invoke
        on this API's execution ARN to the calling role (for a browser, use
        Cognito identity pool credentials).
      - "COGNITO_USER_POOLS": set cognito_user_pool_arns; callers send the user
        pool ID token in the Authorization header.
    Both can be combined with require_api_key.
  EOT
  type        = string
  default     = "NONE"

  validation {
    condition     = contains(["NONE", "AWS_IAM", "COGNITO_USER_POOLS"], var.authorization_type)
    error_message = "authorization_type must be NONE, AWS_IAM or COGNITO_USER_POOLS."
  }
}

variable "cognito_user_pool_arns" {
  description = "Cognito user pool ARNs for the COGNITO_USER_POOLS authorizer. Required when authorization_type = \"COGNITO_USER_POOLS\"."
  type        = list(string)
  default     = []

  validation {
    condition     = var.authorization_type != "COGNITO_USER_POOLS" || length(var.cognito_user_pool_arns) > 0
    error_message = "cognito_user_pool_arns must list at least one user pool when authorization_type = COGNITO_USER_POOLS."
  }
}

variable "require_api_key" {
  description = "Require the x-api-key header on POST /predict and GET /results/{id}. Creates one API key attached to the usage plan (the usage plan is created whenever this is true). The key is output as api_key_value (sensitive)."
  type        = bool
  default     = true
}

################################################################################
# CORS
################################################################################

variable "cors_allowed_origin" {
  description = "Origin returned in Access-Control-Allow-Origin, for example https://d111111abcdef8.cloudfront.net. Only this origin can call the API from a browser."
  type        = string
}

################################################################################
# Throttling
################################################################################

# Stage-wide throttle for every request. The account default is 10,000
# requests per second; a medical-image demo caps far lower.
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
# Usage Plan
################################################################################

variable "create_usage_plan" {
  description = "Create the usage plan even when require_api_key = false. The plan is always created when an API key is required."
  type        = bool
  default     = true
}

variable "usage_plan_rate_limit" {
  description = "Per-key rate limit (requests per second)"
  type        = number
  default     = 10
}

variable "usage_plan_burst_limit" {
  description = "Per-key burst limit"
  type        = number
  default     = 20
}

variable "usage_plan_quota_limit" {
  description = "Per-key quota - maximum requests in the usage_plan_quota_period"
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
# AWS WAF
################################################################################

variable "enable_waf" {
  description = "Associate a regional AWS WAF web ACL with the stage: AWS managed common and known-bad-inputs rule sets plus a per-IP rate-based rule. WAF logs go to a CloudWatch log group with the x-api-key header redacted."
  type        = bool
  default     = true
}

variable "waf_rate_limit" {
  description = "Requests per client IP in any 5-minute window before the WAF rate-based rule blocks that IP."
  type        = number
  default     = 300

  validation {
    condition     = var.waf_rate_limit >= 10 && var.waf_rate_limit <= 2000000000
    error_message = "waf_rate_limit must be between 10 and 2,000,000,000."
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

variable "permissions_boundary_arn" {
  description = "ARN of the permissions boundary attached to the IAM roles this module creates. null leaves them unbounded."
  type        = string
  default     = null
}
