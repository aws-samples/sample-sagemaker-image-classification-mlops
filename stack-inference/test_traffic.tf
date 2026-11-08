# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Optional synthetic traffic for test deployments: once an hour, at a random
# minute (the flexible window), a Lambda sends 1 to test_traffic_max_requests
# images from the raw-data bucket to the inference function. The drift job
# needs drift_detector_min_samples predictions in its lookback window before it
# publishes, so an idle test endpoint never exercises monitoring. The schedule
# stops at test_traffic_end_date. Off by default; never enable it on an
# endpoint that serves real users.

locals {
  test_traffic_count  = var.test_traffic_enabled ? 1 : 0
  test_traffic_prefix = try(data.terraform_remote_state.training.outputs.training_data_path, "images/")
}

module "test_traffic_role" {
  source = "../modules/terraform-aws-iam"
  count  = local.test_traffic_count

  role_name                = "${var.project_name}-test-traffic-role"
  description              = "Execution role for the ${var.project_name} synthetic test traffic Lambda function"
  permissions_boundary_arn = var.permissions_boundary_arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  inline_policies = {
    test_traffic = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          # X-Ray trace writes support only "*".
          Effect   = "Allow"
          Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
          Resource = "*"
        },
        {
          # Writes only to this function's own log group, which the Lambda
          # module creates.
          Effect   = "Allow"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.project_name}-test-traffic:*"
        },
        {
          Effect   = "Allow"
          Action   = "s3:ListBucket"
          Resource = "arn:aws:s3:::${data.terraform_remote_state.training.outputs.raw_data_bucket}"
          Condition = {
            StringLike = { "s3:prefix" = ["${local.test_traffic_prefix}*"] }
          }
        },
        {
          Effect   = "Allow"
          Action   = "s3:GetObject"
          Resource = "arn:aws:s3:::${data.terraform_remote_state.training.outputs.raw_data_bucket}/${local.test_traffic_prefix}*"
        },
        {
          Effect   = "Allow"
          Action   = "kms:Decrypt"
          Resource = local.training_outputs.kms_key_arn
        },
        {
          Effect   = "Allow"
          Action   = "lambda:InvokeFunction"
          Resource = module.inference_lambda["inference_api"].function_arn
        },
      ]
    })
  }
}

module "test_traffic_lambda" {
  source = "../modules/terraform-aws-lambda"
  count  = local.test_traffic_count

  source_dir = "${path.module}/test-traffic"
  # Its own zip: the module default path is shared with the inference functions.
  archive_output_path = "${path.module}/test-traffic.zip"
  function_name       = "${var.project_name}-test-traffic"
  description         = "Synthetic test traffic for the inference function (test deployments only)"
  execution_role_arn  = module.test_traffic_role[0].role_arn
  handler             = "test_traffic.lambda_handler"
  timeout             = 300
  memory_size         = 256
  enable_xray_tracing = true
  environment_variables = {
    RAW_BUCKET      = data.terraform_remote_state.training.outputs.raw_data_bucket
    RAW_PREFIX      = local.test_traffic_prefix
    TARGET_FUNCTION = module.inference_lambda["inference_api"].function_name
    MAX_REQUESTS    = tostring(var.test_traffic_max_requests)
    EXPLAIN_RATE    = tostring(var.test_traffic_explain_rate)
  }

  log_retention_days = var.log_retention_days
  log_kms_key_arn    = local.training_outputs.kms_key_arn
  env_kms_key_arn    = local.training_outputs.kms_key_arn
}

resource "aws_iam_role" "test_traffic_scheduler" {
  count = local.test_traffic_count

  name                 = "${var.project_name}-test-traffic-scheduler-role"
  description          = "Lets EventBridge Scheduler invoke the ${var.project_name} test traffic Lambda function"
  permissions_boundary = var.permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals    = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnLikeIfExists = { "aws:SourceArn" = "arn:aws:scheduler:${var.aws_region}:${data.aws_caller_identity.current.account_id}:schedule/default/${var.project_name}-test-traffic" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "test_traffic_scheduler" {
  count = local.test_traffic_count

  name = "${var.project_name}-test-traffic-scheduler-policy"
  role = aws_iam_role.test_traffic_scheduler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = module.test_traffic_lambda[0].function_arn
    }]
  })
}

resource "aws_scheduler_schedule" "test_traffic" {
  count = local.test_traffic_count

  name                         = "${var.project_name}-test-traffic"
  description                  = "Hourly synthetic test traffic at a random minute (test deployments only)"
  schedule_expression          = "rate(1 hour)"
  schedule_expression_timezone = "UTC"
  end_date                     = var.test_traffic_end_date
  state                        = "ENABLED"

  flexible_time_window {
    mode                      = "FLEXIBLE"
    maximum_window_in_minutes = 60
  }

  target {
    arn      = module.test_traffic_lambda[0].function_arn
    role_arn = aws_iam_role.test_traffic_scheduler[0].arn

    retry_policy {
      maximum_retry_attempts = 0
    }
  }
}
