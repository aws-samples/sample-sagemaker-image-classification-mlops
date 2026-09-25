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
# Terraform state backend (from stack-backend-setup outputs)
################################################################################

variable "state_bucket_name" {
  description = "Name of the Terraform state bucket (stack-backend-setup output state_bucket_id). CodeBuild uses it to initialise the training and inference backends."
  type        = string

  validation {
    condition     = var.state_bucket_name != "" && var.state_bucket_name != "your-project-tfstate-1a2b3c4d"
    error_message = "Set state_bucket_name to the stack-backend-setup output state_bucket_id."
  }
}

variable "state_bucket_region" {
  description = "Region of the state bucket. If empty, aws_region is used."
  type        = string
  default     = ""
}

variable "state_kms_key_alias" {
  description = "Alias of the state encryption KMS key, including the alias/ prefix (stack-backend-setup output kms_key_alias). If empty, alias/<project_name>-terraform-state is used."
  type        = string
  default     = ""
}

variable "workload_boundary_name" {
  description = "Name of the permissions boundary policy created by stack-backend-setup. If empty, <project_name>-workload-boundary is used."
  type        = string
  default     = ""
}

################################################################################
# GitHub
################################################################################

variable "github_owner" {
  description = "GitHub organization or user that owns your copy of this repository"
  type        = string

  validation {
    condition     = var.github_owner != "" && var.github_owner != "your-github-org"
    error_message = "Set github_owner to the GitHub organization or user that owns your fork."
  }
}

variable "github_repo" {
  description = "Name of your copy of this repository on GitHub"
  type        = string

  validation {
    condition     = var.github_repo != "" && var.github_repo != "your-repo"
    error_message = "Set github_repo to the name of your fork."
  }
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
  description = "Name of the SageMaker Model Package Group (stack-training output model_package_group_name). If empty, <project_name>-model-package-group is used."
  type        = string
  default     = ""
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
