# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "api_gateway_url" {
  description = "API Gateway URL for inference"
  value       = module.api_gateway.invoke_url
}

################################################################################
# S3
################################################################################

output "inference_bucket_name" {
  description = "S3 bucket name for inference data"
  value       = local.training_outputs.inference_bucket
}

################################################################################
# Lambda
################################################################################

output "lambda_function_names" {
  description = "Lambda function names"
  value = {
    inference_api = module.inference_lambda["inference_api"].function_name
  }
}

################################################################################
# SNS
################################################################################

output "sns_topic_arn" {
  description = "SNS topic ARN for alerts"
  value       = module.sns_alerts.sns_topic_arn
}

################################################################################
# CloudWatch
################################################################################

output "dashboard_url" {
  description = "CloudWatch inference dashboard URL"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.inference_dashboard.dashboard_name}"
}

output "log_groups" {
  description = "CloudWatch log group names"
  value       = local.log_groups
}

################################################################################
# Auto-Deployment
################################################################################

output "auto_deployment_lambda_arn" {
  description = "ARN of the auto-deployment Lambda function"
  value       = module.auto_deployment.lambda_function_arn
}

output "auto_deployment_eventbridge_rule" {
  description = "Name of the EventBridge rule for auto-deployment"
  value       = module.auto_deployment.eventbridge_rule_name
}

################################################################################
# Frontend
################################################################################

output "frontend_cloudfront_url" {
  description = "CloudFront URL for frontend"
  value       = module.frontend_hosting.cloudfront_url
}

output "frontend_s3_bucket" {
  description = "S3 bucket name for frontend"
  value       = module.frontend_hosting.s3_bucket_name
}

output "frontend_cloudfront_distribution_id" {
  description = "CloudFront distribution ID for cache invalidation"
  value       = module.frontend_hosting.cloudfront_distribution_id
}

################################################################################
# Endpoint Alarms
################################################################################

output "endpoint_error_rate_alarm_name" {
  description = "Name of the CloudWatch alarm for endpoint error rate (used for auto-rollback)"
  value       = module.sagemaker_endpoint.error_rate_alarm_name
}

output "endpoint_latency_alarm_name" {
  description = "Name of the CloudWatch alarm for endpoint latency (used for auto-rollback)"
  value       = module.sagemaker_endpoint.latency_alarm_name
}

output "endpoint_error_rate_alarm_arn" {
  description = "ARN of the CloudWatch alarm for endpoint error rate"
  value       = module.sagemaker_endpoint.error_rate_alarm_arn
}

output "endpoint_latency_alarm_arn" {
  description = "ARN of the CloudWatch alarm for endpoint latency"
  value       = module.sagemaker_endpoint.latency_alarm_arn
}

################################################################################
# SageMaker Endpoint
################################################################################

output "endpoint_arn" {
  description = "ARN of the SageMaker endpoint"
  value       = module.sagemaker_endpoint.endpoint_arn
}

output "endpoint_name" {
  description = "Name of the SageMaker endpoint"
  value       = module.sagemaker_endpoint.endpoint_name
}
