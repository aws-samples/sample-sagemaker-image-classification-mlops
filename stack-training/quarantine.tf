# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Upload quarantine: a Lambda checks every object created under the training
# image prefix of the raw-data bucket (allowed extension, opens with Pillow as
# that format, minimum size) and moves failing files to quarantine_prefix,
# which is outside the prefix the pipeline reads, with a .reason.json next to
# each one. The trigger is an EventBridge rule on the bucket's Object Created
# events, the same event source the pipeline auto-trigger uses (S3 allows one
# notification configuration per bucket, and this one sends to EventBridge).
# The validation step in the pipeline still checks every image, so a file the
# Lambda has not reached yet when the pipeline starts is caught there.

locals {
  upload_quarantine_name = "${var.project_name}-upload-quarantine"

  # The Pillow + NumPy layer zip that stack-inference also uses, built by the
  # same script with the same pinned versions (Pillow 12.3.0 for python3.13).
  # `make layer` builds it before `make deploy-training`; otherwise the apply
  # builds it when missing (needs bash, zip and uv or pip).
  quarantine_layer_zip    = "${path.module}/../stack-inference/lambda-layers/pillow-numpy-layer.zip"
  quarantine_layer_script = "${path.module}/../ops-scripts/build_lambda_layer.sh"

  quarantine_metric_namespace = "${var.project_name}/DataQuality"
}

resource "terraform_data" "quarantine_layer_build" {
  count = var.enable_upload_quarantine ? 1 : 0

  # A change to the build script (pinned versions) replaces the layer.
  triggers_replace = [filesha256(local.quarantine_layer_script)]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "[ -f '${local.quarantine_layer_zip}' ] || bash '${local.quarantine_layer_script}'"
  }
}

resource "aws_lambda_layer_version" "quarantine_pillow" {
  count = var.enable_upload_quarantine ? 1 : 0

  filename   = local.quarantine_layer_zip
  layer_name = "${local.upload_quarantine_name}-pillow"

  compatible_runtimes = ["python3.13"]
  description         = "Pillow for the upload quarantine Lambda"

  depends_on = [terraform_data.quarantine_layer_build]

  lifecycle {
    replace_triggered_by = [terraform_data.quarantine_layer_build]
  }
}

# Failed asynchronous invocations (after Lambda's two retries) land here, so a
# file that could not be checked is visible instead of silently skipped.
resource "aws_sqs_queue" "upload_quarantine_dlq" {
  count = var.enable_upload_quarantine ? 1 : 0

  name                      = "${local.upload_quarantine_name}-dlq"
  message_retention_seconds = 1209600 # 14 days, the SQS maximum
  kms_master_key_id         = module.kms.key_arn
}

resource "aws_cloudwatch_metric_alarm" "upload_quarantine_dlq" {
  count = var.enable_upload_quarantine ? 1 : 0

  alarm_name          = "${local.upload_quarantine_name}-dlq-visible"
  alarm_description   = "Upload quarantine Lambda DLQ has messages: an uploaded file could not be checked. The pipeline validation step still checks it."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.upload_quarantine_dlq[0].name
  }
}

resource "aws_cloudwatch_event_rule" "upload_quarantine" {
  count = var.enable_upload_quarantine ? 1 : 0

  name        = local.upload_quarantine_name
  description = "Check each image uploaded under the training prefix and quarantine files that fail"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = {
        name = [module.s3_raw_data.bucket_id]
      }
      object = {
        key = [{
          prefix = var.training_data_path
        }]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "upload_quarantine" {
  count = var.enable_upload_quarantine ? 1 : 0

  rule      = aws_cloudwatch_event_rule.upload_quarantine[0].name
  target_id = "UploadQuarantineLambda"
  arn       = module.upload_quarantine_lambda[0].function_arn
}

module "upload_quarantine_role" {
  source = "../modules/terraform-aws-iam"
  count  = var.enable_upload_quarantine ? 1 : 0

  role_name                = "${local.upload_quarantine_name}-role"
  permissions_boundary_arn = var.permissions_boundary_arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
      }
    ]
  })

  inline_policies = {
    upload_quarantine = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          # The module pre-creates the log group; the function only writes.
          Effect   = "Allow"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.upload_quarantine_name}:*"
        },
        {
          # Read each uploaded image and delete the ones it moves.
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:DeleteObject"]
          Resource = "${module.s3_raw_data.bucket_arn}/${var.training_data_path}*"
        },
        {
          # Without ListBucket a missing key reads as AccessDenied rather
          # than NoSuchKey; scoped to the training prefix.
          Effect   = "Allow"
          Action   = ["s3:ListBucket"]
          Resource = module.s3_raw_data.bucket_arn
          Condition = {
            StringLike = { "s3:prefix" = "${var.training_data_path}*" }
          }
        },
        {
          # Write the quarantined copy and its reason file.
          Effect   = "Allow"
          Action   = ["s3:PutObject"]
          Resource = "${module.s3_raw_data.bucket_arn}/${var.quarantine_prefix}*"
        },
        {
          # The bucket, the DLQ and the environment variables use the project
          # CMK.
          Effect   = "Allow"
          Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
          Resource = module.kms.key_arn
        },
        {
          Effect   = "Allow"
          Action   = ["sqs:SendMessage"]
          Resource = aws_sqs_queue.upload_quarantine_dlq[0].arn
        },
        {
          # PutMetricData has no resource-level scoping; the condition limits
          # it to this namespace.
          Effect   = "Allow"
          Action   = ["cloudwatch:PutMetricData"]
          Resource = "*"
          Condition = {
            StringEquals = { "cloudwatch:namespace" = local.quarantine_metric_namespace }
          }
        },
        {
          Effect   = "Allow"
          Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
          Resource = "*"
        },
      ]
    })
  }
}

module "upload_quarantine_lambda" {
  source = "../modules/terraform-aws-lambda"
  count  = var.enable_upload_quarantine ? 1 : 0

  source_dir          = "${path.module}/lambda/upload_quarantine"
  archive_output_path = "${path.module}/lambda/upload_quarantine.zip"
  function_name       = local.upload_quarantine_name
  description         = "Quarantines uploaded training images that fail format or size checks"
  execution_role_arn  = module.upload_quarantine_role[0].role_arn
  handler             = "upload_quarantine.lambda_handler"
  timeout             = 60
  memory_size         = 512
  layers              = [aws_lambda_layer_version.quarantine_pillow[0].arn]

  environment_variables = {
    IMAGE_PREFIX      = var.training_data_path
    QUARANTINE_PREFIX = var.quarantine_prefix
    MARKER_KEY        = var.auto_trigger_marker_key
    MIN_IMAGE_SIZE_PX = tostring(var.quarantine_min_image_size_px)
    METRIC_NAMESPACE  = local.quarantine_metric_namespace
  }

  log_retention_days = var.log_retention_days
  log_kms_key_arn    = module.kms.key_arn
  env_kms_key_arn    = module.kms.key_arn

  enable_xray_tracing            = true
  dead_letter_target_arn         = aws_sqs_queue.upload_quarantine_dlq[0].arn
  reserved_concurrent_executions = var.upload_quarantine_reserved_concurrency

  permissions = {
    eventbridge = {
      statement_id = "AllowExecutionFromEventBridge"
      action       = "lambda:InvokeFunction"
      principal    = "events.amazonaws.com"
      source_arn   = aws_cloudwatch_event_rule.upload_quarantine[0].arn
    }
  }
}
