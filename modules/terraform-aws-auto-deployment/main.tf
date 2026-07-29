# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

resource "aws_cloudwatch_event_rule" "model_approved" {
  name        = "${var.project_name}-model-approved"
  description = "Trigger auto-deployment when model is approved in registry"

  event_pattern = jsonencode({
    source      = ["aws.sagemaker"]
    detail-type = ["SageMaker Model Package State Change"]
    detail = {
      ModelApprovalStatus   = ["Approved"]
      ModelPackageGroupName = [var.model_package_group_name]
    }
  })

  tags = var.tags
}

# EventBridge target for Lambda function
resource "aws_cloudwatch_event_target" "deploy_lambda" {
  rule      = aws_cloudwatch_event_rule.model_approved.name
  target_id = "DeployModelTarget"
  arn       = aws_lambda_function.auto_deploy.arn
}

# Lambda permission for EventBridge
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.auto_deploy.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.model_approved.arn
}

################################################################################
# IAM
################################################################################

# IAM role for auto-deployment Lambda
resource "aws_iam_role" "auto_deploy_lambda_role" {
  name = "${var.project_name}-auto-deploy-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

# IAM policy for auto-deployment Lambda
# Scoped to project resources. The Lambda creates model + endpoint-config +
# UpdateEndpoint on the project endpoint only, so we don't need account-wide
# sagemaker:* on "*".
resource "aws_iam_role_policy" "auto_deploy_lambda_policy" {
  name = "${var.project_name}-auto-deploy-lambda-policy"
  role = aws_iam_role.auto_deploy_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          "arn:aws:logs:*:*:log-group:/aws/lambda/${var.project_name}-*",
          "arn:aws:logs:*:*:log-group:/aws/lambda/${var.project_name}-*:*",
        ]
      },
      {
        # Write operations scoped to project-prefixed resources
        Effect = "Allow"
        Action = [
          "sagemaker:CreateModel",
          "sagemaker:DescribeModel",
          "sagemaker:DeleteModel",
          "sagemaker:AddTags",
        ]
        Resource = [
          "arn:aws:sagemaker:*:*:model/${var.project_name}-*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "sagemaker:CreateEndpointConfig",
          "sagemaker:DescribeEndpointConfig",
          "sagemaker:DeleteEndpointConfig",
          "sagemaker:AddTags",
        ]
        Resource = [
          "arn:aws:sagemaker:*:*:endpoint-config/${var.project_name}-*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "sagemaker:UpdateEndpoint",
          "sagemaker:DescribeEndpoint",
        ]
        # UpdateEndpoint authorizes against BOTH the endpoint and the
        # endpoint-config it is pointed at, so the config ARN must be included
        # or the call fails with AccessDenied on the config resource.
        Resource = [
          "arn:aws:sagemaker:*:*:endpoint/${var.endpoint_name}",
          "arn:aws:sagemaker:*:*:endpoint-config/${var.project_name}-*",
        ]
      },
      {
        # Model package inspection is needed to read image + model_data from
        # the approved package. Scope to the project's model package group.
        Effect = "Allow"
        Action = [
          "sagemaker:DescribeModelPackage",
          "sagemaker:ListModelPackages",
        ]
        Resource = [
          "arn:aws:sagemaker:*:*:model-package-group/${var.model_package_group_name}",
          "arn:aws:sagemaker:*:*:model-package/${var.model_package_group_name}/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = var.sagemaker_role_arn
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "sagemaker.amazonaws.com"
          }
        }
      },
      # DLQ writes - Lambda needs SendMessage on its own dead-letter queue.
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.dlq.arn
      },
      # X-Ray tracing - required when tracing_config.mode = "Active".
      {
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
        ]
        Resource = "*"
      }
    ]
  })
}

################################################################################
# Lambda Function
################################################################################

################################################################################
# Lambda Function
################################################################################

# DLQ for async failures. The auto-deploy Lambda is invoked by EventBridge
# when a model is approved; without a DLQ, any error (race with a
# concurrent in-progress deployment, transient SageMaker 5xx, etc.) would
# disappear silently.
resource "aws_sqs_queue" "dlq" {
  name                      = "${var.project_name}-auto-deploy-dlq"
  message_retention_seconds = 1209600 # 14 days - max SQS allows
  # Prefer a customer-managed CMK when the caller passes one; fall back
  # to alias/aws/sqs for callers who haven't wired a key yet.
  kms_master_key_id = coalesce(var.env_kms_key_arn, "alias/aws/sqs")

  tags = var.tags
}

# CloudWatch alarm on DLQ depth > 0 - anything in the DLQ means an approval
# event was lost and needs operator attention.
resource "aws_cloudwatch_metric_alarm" "dlq_visible" {
  alarm_name          = "${var.project_name}-auto-deploy-dlq-visible"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "Auto-deploy Lambda DLQ has unprocessed messages - an approval event failed to deploy."
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.dlq.name
  }

  alarm_actions = var.sns_topic_arn != null ? [var.sns_topic_arn] : []

  tags = var.tags
}

# Lambda function for auto-deployment
resource "aws_lambda_function" "auto_deploy" {
  filename      = data.archive_file.auto_deploy_zip.output_path
  function_name = "${var.project_name}-auto-deploy"
  role          = aws_iam_role.auto_deploy_lambda_role.arn
  handler       = "auto_deploy_handler.lambda_handler"
  runtime       = "python3.13"
  timeout       = 900

  source_code_hash = data.archive_file.auto_deploy_zip.output_base64sha256

  # Cap concurrency - this Lambda is EventBridge-triggered on model approval,
  # which happens at most a handful of times per day. A cap of 5 protects
  # the account's concurrency pool from a runaway event storm.
  reserved_concurrent_executions = 5

  # Encrypt environment variables at rest with the project CMK (env vars
  # contain endpoint names, bucket names - not secret but principle of
  # consistency across resources).
  kms_key_arn = var.env_kms_key_arn

  # Active X-Ray tracing so we can see the full EventBridge → Lambda →
  # SageMaker call chain when a deploy misbehaves.
  tracing_config {
    mode = "Active"
  }

  # Async failures go to SQS. Retried twice by Lambda, then dropped here.
  dead_letter_config {
    target_arn = aws_sqs_queue.dlq.arn
  }

  environment {
    variables = {
      SAGEMAKER_ROLE                   = var.sagemaker_role_arn
      ENDPOINT_NAME                    = var.endpoint_name
      PROJECT_NAME                     = var.project_name
      MODEL_PACKAGE_GROUP_NAME         = var.model_package_group_name
      MONITORING_BUCKET                = var.monitoring_bucket
      INSTANCE_TYPE                    = var.endpoint_instance_type
      DATA_CAPTURE_SAMPLING_PERCENTAGE = tostring(var.data_capture_sampling_percentage)
      PATCHED_IMAGE_URI                = var.patched_image_uri
      # Serverless inference opt-in - mirrors the Terraform module flag so
      # the Lambda builds endpoint configs matching the initial deploy.
      USE_SERVERLESS_INFERENCE   = tostring(var.use_serverless_inference)
      SERVERLESS_MEMORY_SIZE_MB  = tostring(var.serverless_memory_size_mb)
      SERVERLESS_MAX_CONCURRENCY = tostring(var.serverless_max_concurrency)
    }
  }

  tags = var.tags
}

# Archive Lambda function code
data "archive_file" "auto_deploy_zip" {
  type        = "zip"
  output_path = "${path.module}/auto_deploy_handler.zip"
  source_file = "${path.module}/auto_deploy_handler.py"
}

################################################################################
# CloudWatch
################################################################################

# CloudWatch Log Group for Lambda
resource "aws_cloudwatch_log_group" "auto_deploy_logs" {
  name              = "/aws/lambda/${aws_lambda_function.auto_deploy.function_name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.log_kms_key_arn
  tags              = var.tags
}

# CloudWatch alarm for deployment failures
resource "aws_cloudwatch_metric_alarm" "deployment_failure" {
  alarm_name          = "${var.project_name}-deployment-failure"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = "300"
  statistic           = "Sum"
  threshold           = "1"
  alarm_description   = "This metric monitors auto-deployment failures"

  dimensions = {
    FunctionName = aws_lambda_function.auto_deploy.function_name
  }

  alarm_actions = var.sns_topic_arn != null ? [var.sns_topic_arn] : []

  tags = var.tags
}
