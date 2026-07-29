# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "sns_topic_arn" {
  description = "SNS topic ARN"
  value       = aws_sns_topic.this.arn
}

################################################################################
# CloudWatch Alarms
################################################################################

output "alarm_names" {
  description = "Created alarm names"
  value       = { for k, v in aws_cloudwatch_metric_alarm.alarms : k => v.alarm_name }
}
