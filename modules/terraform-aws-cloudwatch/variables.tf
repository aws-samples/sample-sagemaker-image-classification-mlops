# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "aws_region" {
  description = "AWS region for monitoring"
  type        = string
}

################################################################################
# Training Monitoring
################################################################################

variable "enable_training_monitoring" {
  description = "Enable ML training monitoring (uses hardcoded ML metrics)"
  type        = bool
  default     = false
}

variable "training_models" {
  description = "List of training models to monitor (only used when enable_training_monitoring = true)"
  type        = list(string)
  default     = []
}

variable "log_group_names" {
  description = "Log group names for metric filters (only used when enable_training_monitoring = true)"
  type        = map(string)
  default     = {}
}

variable "metric_namespaces" {
  description = "Metric namespaces for CloudWatch metrics (only used when enable_training_monitoring = true)"
  type        = map(string)
  default     = {}
}

################################################################################
# Generic Monitoring
################################################################################

variable "log_groups" {
  description = "Map of log groups to create (generic mode only)"
  type = map(object({
    name              = string
    retention_in_days = optional(number, 14)
  }))
  default = {}
}

variable "log_retention_days" {
  description = "Default CloudWatch log retention in days (generic mode only)"
  type        = number
  default     = 14
}

variable "kms_key_arn" {
  description = "KMS key ARN for log group encryption (generic mode only)"
  type        = string
  default     = null
}

variable "dashboard_name" {
  description = "CloudWatch dashboard name (generic mode only, training mode auto-generates)"
  type        = string
  default     = null
}

variable "dashboard_config" {
  description = "Dashboard configuration JSON (generic mode only)"
  type        = string
  default     = ""
}

variable "metric_filters" {
  description = "Map of metric filters to create (generic mode only)"
  type = map(object({
    log_group_name = string
    pattern        = string
    metric_transformation = object({
      name      = string
      namespace = string
      value     = string
      unit      = optional(string, "None")
    })
  }))
  default = {}
}

################################################################################
# Tags
################################################################################

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}
