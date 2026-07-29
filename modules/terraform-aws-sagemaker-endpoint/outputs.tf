# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "model_name" {
  description = "Name of the SageMaker model"
  value       = aws_sagemaker_model.this.name
}

################################################################################
# Endpoint Configuration
################################################################################

output "endpoint_config_name" {
  description = "Name of the SageMaker endpoint configuration"
  value       = aws_sagemaker_endpoint_configuration.this.name
}

output "endpoint_name" {
  description = "Name of the SageMaker endpoint"
  value       = aws_sagemaker_endpoint.this.name
}

################################################################################
# SageMaker Endpoint
################################################################################

output "endpoint_arn" {
  description = "ARN of the SageMaker endpoint"
  value       = aws_sagemaker_endpoint.this.arn
}

################################################################################
# CloudWatch Alarms
################################################################################

output "error_rate_alarm_arn" {
  description = "ARN of the endpoint error rate CloudWatch alarm"
  value       = aws_cloudwatch_metric_alarm.endpoint_error_rate.arn
}

output "error_rate_alarm_name" {
  description = "Name of the endpoint error rate CloudWatch alarm"
  value       = aws_cloudwatch_metric_alarm.endpoint_error_rate.alarm_name
}

output "latency_alarm_arn" {
  description = "ARN of the endpoint latency CloudWatch alarm"
  value       = aws_cloudwatch_metric_alarm.endpoint_latency.arn
}

output "latency_alarm_name" {
  description = "Name of the endpoint latency CloudWatch alarm"
  value       = aws_cloudwatch_metric_alarm.endpoint_latency.alarm_name
}

################################################################################
# Auto-Scaling
################################################################################

output "autoscaling_target_resource_id" {
  description = "Resource ID of the auto-scaling target (null when running in serverless mode)"
  value       = length(aws_appautoscaling_target.this) > 0 ? aws_appautoscaling_target.this[0].resource_id : null
}
