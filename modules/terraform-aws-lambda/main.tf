# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.module}/lambda_function.zip"
}

resource "aws_lambda_function" "this" {
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  function_name    = var.function_name
  role             = var.execution_role_arn
  handler          = var.handler
  runtime          = var.runtime
  timeout          = var.timeout
  memory_size      = var.memory_size
  layers           = var.layers
  description      = var.description

  # KMS key used to encrypt environment variables at rest. Null = the
  # AWS-managed Lambda key (still encrypted). Pass a CMK for tighter
  # access control.
  kms_key_arn = var.env_kms_key_arn

  # Reserved concurrency caps how many simultaneous executions this function
  # can have - protects both the function's own runtime and prevents it from
  # starving other functions in the account. -1 = unset / account default.
  reserved_concurrent_executions = var.reserved_concurrent_executions

  # X-Ray tracing - end-to-end trace visibility for debugging latency and
  # errors across API GW → Lambda → SageMaker.
  dynamic "tracing_config" {
    for_each = var.enable_xray_tracing ? [1] : []
    content {
      mode = "Active"
    }
  }

  # Dead-letter queue - Lambda sends failed invocation events here after
  # exhausting retries. Without a DLQ, EventBridge-triggered failures are
  # silently dropped; with one, we can alarm on visible-message count and
  # replay events after fixing the bug.
  dynamic "dead_letter_config" {
    for_each = var.dead_letter_target_arn != null ? [1] : []
    content {
      target_arn = var.dead_letter_target_arn
    }
  }

  dynamic "environment" {
    for_each = var.environment_variables != null ? [1] : []
    content {
      variables = var.environment_variables
    }
  }

  tags = var.tags

  # The log group must exist before the Lambda first writes to it; otherwise
  # AWS auto-creates it with infinite retention and Terraform can't adopt it
  # without import.
  depends_on = [aws_cloudwatch_log_group.this]
}

################################################################################
# CloudWatch Log Group
################################################################################

# Pre-create the Lambda log group so Terraform owns retention + encryption.
# Without this, the first Lambda invocation auto-creates the group with
# infinite retention (never expires, no KMS), and Terraform can't adopt it
# without a manual `terraform import`.
resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.log_kms_key_arn

  tags = var.tags
}

################################################################################
# Lambda Permissions
################################################################################

resource "aws_lambda_permission" "permissions" {
  for_each = var.permissions

  statement_id  = each.value.statement_id
  action        = each.value.action
  function_name = aws_lambda_function.this.function_name
  principal     = each.value.principal
  source_arn    = each.value.source_arn
}
