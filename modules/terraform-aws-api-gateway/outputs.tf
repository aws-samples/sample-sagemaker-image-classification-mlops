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
