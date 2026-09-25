# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "source_dir" {
  description = "Path to Lambda source code directory"
  type        = string
}

variable "function_name" {
  description = "Lambda function name"
  type        = string
}

variable "execution_role_arn" {
  description = "Lambda execution role ARN"
  type        = string
}

variable "handler" {
  description = "Lambda function handler"
  type        = string
}

variable "runtime" {
  description = "Lambda runtime"
  type        = string
  default     = "python3.13"
}

variable "timeout" {
  description = "Lambda timeout in seconds"
  type        = number
  default     = 300
}

variable "memory_size" {
  description = "Lambda memory size in MB"
  type        = number
  default     = 512
}

variable "environment_variables" {
  description = "Environment variables for Lambda"
  type        = map(string)
  default     = null
}

variable "description" {
  description = "Description of the Lambda function"
  type        = string
  default     = null
}

################################################################################
# Lambda Permissions
################################################################################

variable "permissions" {
  description = "Lambda permissions"
  type = map(object({
    statement_id = string
    action       = string
    principal    = string
    source_arn   = string
  }))
  default = {}
}

variable "layers" {
  description = "List of Lambda Layer ARNs"
  type        = list(string)
  default     = []
}

################################################################################
# Tags
################################################################################

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}

################################################################################
# CloudWatch Logs
################################################################################

variable "log_retention_days" {
  description = "CloudWatch log retention in days for the Lambda log group"
  type        = number
  default     = 14
}

variable "log_kms_key_arn" {
  description = "KMS key ARN to encrypt the Lambda log group (optional)"
  type        = string
  default     = null
}

################################################################################
# X-Ray + DLQ + Concurrency
################################################################################

variable "enable_xray_tracing" {
  description = "Enable Active X-Ray tracing on the Lambda function. Recommended for production - gives end-to-end latency visibility across API Gateway, Lambda and downstream AWS services."
  type        = bool
  default     = true
}

variable "dead_letter_target_arn" {
  description = "ARN of an SQS queue or SNS topic that receives failed async invocation events after Lambda exhausts its retry policy. Null = no DLQ (synchronous/API GW invocations don't need one)."
  type        = string
  default     = null
}

variable "reserved_concurrent_executions" {
  description = "Reserved concurrency cap for this function. -1 = use account-default unreserved concurrency. Set to a positive integer to (a) cap max concurrent executions (cost control) or (b) reserve capacity (protect critical functions)."
  type        = number
  default     = -1
}

variable "env_kms_key_arn" {
  description = "KMS CMK ARN used to encrypt Lambda environment variables. Null = AWS-managed key (still encrypted at rest)."
  type        = string
  default     = null
}
