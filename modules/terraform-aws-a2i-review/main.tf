# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

resource "aws_sagemaker_human_task_ui" "this" {
  human_task_ui_name = "${var.name_prefix}-review-ui"

  ui_template {
    content = file("${path.module}/task-ui-template.liquid.html")
  }

  tags = var.tags
}

resource "aws_sagemaker_flow_definition" "this" {
  count = var.workteam_arn != "" ? 1 : 0

  flow_definition_name = "${var.name_prefix}-review-flow"
  role_arn             = var.execution_role_arn

  human_loop_config {
    human_task_ui_arn                     = aws_sagemaker_human_task_ui.this.arn
    workteam_arn                          = var.workteam_arn
    task_count                            = var.task_count
    task_description                      = var.task_description
    task_title                            = var.task_title
    task_availability_lifetime_in_seconds = var.task_availability_lifetime_in_seconds
  }

  output_config {
    s3_output_path = var.output_s3_uri
  }

  tags = var.tags
}
