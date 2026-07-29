# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "project_name" {
  description = "Name of the project"
  type        = string
  default     = "medical-image-classification"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

################################################################################
# GitHub
################################################################################

variable "github_owner" {
  description = "GitHub repository owner"
  type        = string
  default     = "xsagarx-aws"
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
  default     = "Medical_Image_Classification"
}

variable "github_branch" {
  description = "GitHub branch to track"
  type        = string
  default     = "main"
}

################################################################################
# SageMaker
################################################################################

variable "model_package_group_name" {
  description = "Name of the SageMaker Model Package Group"
  type        = string
  default     = "medical-image-classification-model-package-group"
}

################################################################################
# Deep Learning Container
################################################################################

# DLC references used by the baseline model script to register a baseline
# against the same image the inference pipeline will serve. Defaults target
# the canonical commercial-region DLC registry; override for GovCloud / CN.
variable "dlc_account_id" {
  description = "AWS account ID that hosts the Deep Learning Containers ECR registry"
  type        = string
  default     = "763104351884"
}

variable "inference_image_tag" {
  description = "DLC tensorflow-inference tag. Use the floating major.minor tag (no -v1.X suffix) to auto-pick up AWS patches."
  type        = string
  default     = "2.19.0-cpu-py312-ubuntu22.04-sagemaker"
}

################################################################################
# Manual Approval
################################################################################

variable "require_manual_approval" {
  description = "Insert a manual approval action before the Inference-Deploy stage. Strongly recommended for medical ML: a human must review the model card + drift metrics before a new model reaches prod."
  type        = bool
  default     = true
}

variable "approval_notification_emails" {
  description = "Email addresses to notify when the pipeline pauses at the manual approval gate. Subscribers must confirm the SNS subscription after the first apply."
  type        = list(string)
  default     = []
}
