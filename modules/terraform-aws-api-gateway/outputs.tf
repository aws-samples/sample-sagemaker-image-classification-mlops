# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "api_name" {
  description = "Name of the API Gateway"
  value       = aws_api_gateway_rest_api.this.name
}

output "api_id" {
  description = "ID of the API Gateway"
  value       = aws_api_gateway_rest_api.this.id
}

output "execution_arn" {
  description = "Execution ARN of the API Gateway"
  value       = aws_api_gateway_rest_api.this.execution_arn
}

################################################################################
# Stage
################################################################################

output "invoke_url" {
  description = "Invoke URL of the API Gateway"
  value       = aws_api_gateway_stage.this.invoke_url
}

output "stage_name" {
  description = "Stage name of the deployment"
  value       = aws_api_gateway_stage.this.stage_name
}

################################################################################
# Access control
################################################################################

output "api_key_value" {
  description = "Value of the frontend API key (empty when require_api_key = false). Sent as the x-api-key header."
  value       = var.require_api_key ? aws_api_gateway_api_key.frontend[0].value : ""
  sensitive   = true
}

output "api_key_id" {
  description = "ID of the frontend API key (null when require_api_key = false)"
  value       = var.require_api_key ? aws_api_gateway_api_key.frontend[0].id : null
}

output "web_acl_arn" {
  description = "ARN of the WAF web ACL associated with the stage (null when enable_waf = false)"
  value       = var.enable_waf ? aws_wafv2_web_acl.this[0].arn : null
}

output "access_log_group_name" {
  description = "CloudWatch log group for stage access logs (null when access logging is off)"
  value       = var.enable_access_logging ? aws_cloudwatch_log_group.access_logs[0].name : null
}
