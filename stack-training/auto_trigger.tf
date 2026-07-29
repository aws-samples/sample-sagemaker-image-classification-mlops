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
          prefix = "medical_image_data/.batch_complete"
        }]
      }
    }
  })

  tags = local.common_tags
}

# Direct EventBridge target to SageMaker Pipeline
resource "aws_cloudwatch_event_target" "pipeline_trigger" {
  count = var.enable_auto_trigger ? 1 : 0

  rule      = aws_cloudwatch_event_rule.new_data_uploaded[0].name
  target_id = "SageMakerPipelineTargetFixed"
  arn       = aws_sagemaker_pipeline.medical_image_pipeline.arn
  role_arn  = aws_iam_role.eventbridge_sagemaker_role[0].arn
}

# IAM role for EventBridge to invoke SageMaker Pipeline
resource "aws_iam_role" "eventbridge_sagemaker_role" {
  count = var.enable_auto_trigger ? 1 : 0

  name = "${var.project_name}-eventbridge-sagemaker-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
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
        Resource = aws_sagemaker_pipeline.medical_image_pipeline.arn
      }
    ]
  })
}
