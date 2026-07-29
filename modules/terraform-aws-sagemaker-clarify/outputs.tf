# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "monitoring_schedule_arn" {
  description = "ARN of the Clarify bias monitoring schedule"
  value       = try(aws_sagemaker_monitoring_schedule.bias[0].arn, null)
}

output "monitoring_schedule_name" {
  description = "Name of the Clarify bias monitoring schedule"
  value       = try(aws_sagemaker_monitoring_schedule.bias[0].name, null)
}

output "job_definition_arn" {
  description = "ARN of the Clarify data quality job definition"
  value       = try(aws_sagemaker_data_quality_job_definition.bias[0].arn, null)
}
