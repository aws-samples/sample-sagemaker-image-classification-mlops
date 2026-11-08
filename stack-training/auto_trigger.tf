# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

resource "aws_cloudwatch_event_rule" "new_data_uploaded" {
  count = var.enable_auto_trigger ? 1 : 0

  name        = "${var.project_name}-new-data-uploaded"
  description = "Trigger SageMaker pipeline when a new data batch is uploaded"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = {
        name = [module.s3_raw_data.bucket_id]
      }
      object = {
        key = [{
          prefix = var.auto_trigger_marker_key
        }]
      }
    }
  })
}

# Direct EventBridge target to SageMaker Pipeline. Stamps the execution with
# RetrainingReason=data_upload so the registered model package records why it
# was trained.
resource "aws_cloudwatch_event_target" "pipeline_trigger" {
  count = var.enable_auto_trigger ? 1 : 0

  rule      = aws_cloudwatch_event_rule.new_data_uploaded[0].name
  target_id = "SageMakerPipelineTargetFixed"
  arn       = aws_sagemaker_pipeline.image_pipeline.arn
  role_arn  = aws_iam_role.eventbridge_sagemaker_role[0].arn

  sagemaker_pipeline_target {
    pipeline_parameter_list {
      name  = "RetrainingReason"
      value = "data_upload"
    }
  }
}

resource "aws_iam_role" "eventbridge_sagemaker_role" {
  count = var.enable_auto_trigger ? 1 : 0

  name                 = "${var.project_name}-eventbridge-sagemaker-role"
  description          = "Lets the ${var.project_name} EventBridge upload rule start the SageMaker pipeline"
  permissions_boundary = var.permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Condition = {
          StringEqualsIfExists = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
          ArnLikeIfExists      = { "aws:SourceArn" = "arn:aws:events:${var.aws_region}:${data.aws_caller_identity.current.account_id}:rule/${var.project_name}-*" }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "eventbridge_sagemaker_policy" {
  count = var.enable_auto_trigger ? 1 : 0

  name = "${var.project_name}-eventbridge-sagemaker-policy"
  role = aws_iam_role.eventbridge_sagemaker_role[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sagemaker:StartPipelineExecution"
        ]
        Resource = aws_sagemaker_pipeline.image_pipeline.arn
      }
    ]
  })
}
