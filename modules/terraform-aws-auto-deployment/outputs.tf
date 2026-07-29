# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "lambda_function_arn" {
  description = "ARN of the auto-deployment Lambda function"
  value       = aws_lambda_function.auto_deploy.arn
}

output "lambda_function_name" {
  description = "Name of the auto-deployment Lambda function"
  value       = aws_lambda_function.auto_deploy.function_name
}

################################################################################
# EventBridge Rule
################################################################################

output "eventbridge_rule_arn" {
  description = "ARN of the EventBridge rule"
  value       = aws_cloudwatch_event_rule.model_approved.arn
}

output "eventbridge_rule_name" {
  description = "Name of the EventBridge rule"
  value       = aws_cloudwatch_event_rule.model_approved.name
}
