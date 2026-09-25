# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "role_name" {
  description = "Name of the IAM role"
  type        = string
}

variable "assume_role_policy" {
  description = "The assume role policy document"
  type        = string
}

variable "description" {
  description = "Description of the IAM role"
  type        = string
  default     = null
}

variable "path" {
  description = "Path for the IAM role"
  type        = string
  default     = "/"
}

variable "max_session_duration" {
  description = "Maximum session duration in seconds (3600-43200). Default is AWS default of 3600 (1 hour). Increase for long-running CodeBuild jobs."
  type        = number
  default     = 3600

  validation {
    condition     = var.max_session_duration >= 3600 && var.max_session_duration <= 43200
    error_message = "max_session_duration must be between 3600 (1 hour) and 43200 (12 hours)."
  }
}

variable "permissions_boundary_arn" {
  description = "ARN of the permissions boundary policy for the role (stack-backend-setup output workload_boundary_arn). The CI/CD CodeBuild role can only create or change roles that carry it."
  type        = string
  default     = null
}

################################################################################
# IAM Policies
################################################################################

variable "managed_policy_arns" {
  description = "List of managed policy ARNs to attach to the role"
  type        = list(string)
  default     = []
}

variable "inline_policies" {
  description = "Map of inline policy names to policy documents"
  type        = map(string)
  default     = {}
}

################################################################################
# Tags
################################################################################

variable "tags" {
  description = "Tags to apply to the role"
  type        = map(string)
  default     = {}
}
