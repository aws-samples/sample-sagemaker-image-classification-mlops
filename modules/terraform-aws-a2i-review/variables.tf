# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "name_prefix" {
  description = "Prefix for the A2I human-task UI and flow-definition names. Amazon A2I is in maintenance mode (no longer open to new customers): call this module only behind an opt-in flag that defaults to false."
  type        = string
}

variable "workteam_arn" {
  description = "ARN of the SageMaker workteam (private workforce) that reviews flagged cases. A2I cannot create a flow definition without a workteam, and a private workforce is created once per account via Cognito (outside this module). Leave empty to skip creating the flow definition (UI is still created)."
  type        = string
  default     = ""
}

variable "output_s3_uri" {
  description = "S3 URI where A2I writes human-review results (the radiologist decision becomes ground truth for the next retraining cycle)."
  type        = string
}

variable "execution_role_arn" {
  description = "IAM role ARN A2I assumes to read the task UI and write results to S3."
  type        = string
}

variable "task_title" {
  description = "Title shown to the reviewer in the worker portal."
  type        = string
  default     = "Review a low-confidence medical image prediction"
}

variable "task_description" {
  description = "Short description shown to the reviewer."
  type        = string
  default     = "The model was not confident. Confirm whether the image is benign or malignant."
}

variable "task_count" {
  description = "Number of distinct workers who review each flagged case (1-3)."
  type        = number
  default     = 1
}

variable "task_availability_lifetime_in_seconds" {
  description = "How long a task stays available to workers before it expires."
  type        = number
  default     = 86400
}

variable "tags" {
  description = "Tags to apply to all resources."
  type        = map(string)
  default     = {}
}
