# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "topic_name" {
  description = "SNS topic name"
  type        = string
}

variable "email_endpoint" {
  description = "Email endpoint for alerts"
  type        = string
  default     = ""
}

################################################################################
# CloudWatch Alarms
################################################################################

variable "alarms" {
  description = "CloudWatch alarms configuration"
  type = map(object({
    alarm_name          = string
    comparison_operator = string
    evaluation_periods  = string
    metric_name         = string
    namespace           = string
    period              = string
    statistic           = string
    threshold           = string
    alarm_description   = string
    treat_missing_data  = optional(string, "notBreaching")
    dimensions          = optional(map(string))
  }))
  default = {}
}

################################################################################
# Composite Alarm
################################################################################

variable "composite_alarm" {
  description = "Composite alarm configuration"
  type = object({
    alarm_name        = string
    alarm_description = string
    alarm_rule        = string
  })
  default = null
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
# Encryption
################################################################################

variable "kms_master_key_id" {
  description = "KMS key ID/ARN/alias used for SNS server-side encryption. Null/empty = alias/aws/sns (AWS-managed, still encrypted). Pass a customer-managed key ARN for tighter control."
  type        = string
  default     = null
}
