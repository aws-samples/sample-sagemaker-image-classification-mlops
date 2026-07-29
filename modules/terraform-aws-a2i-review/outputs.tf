# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "human_task_ui_arn" {
  description = "ARN of the A2I human task UI."
  value       = aws_sagemaker_human_task_ui.this.arn
}

output "flow_definition_arn" {
  description = "ARN of the A2I flow definition the inference handler targets with start_human_loop. Empty when no workteam_arn was supplied."
  value       = var.workteam_arn != "" ? aws_sagemaker_flow_definition.this[0].arn : ""
}
