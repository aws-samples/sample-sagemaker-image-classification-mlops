# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "enable_bias_monitoring" {
  description = "Whether to create the Clarify bias monitoring schedule"
  type        = bool
  default     = true
}

# NOTE on dedicated ModelBiasMonitor (Part 4): a SageMaker
# aws_sagemaker_model_bias_job_definition requires a ground-truth label feed AND
# a demographic facet to compute fairness drift. This histopathology dataset has
# neither (benign/malignant tiles, no patient metadata), so a dedicated model-
# bias monitor would be non-functional here. The Clarify schedule below + the
# in-pipeline bias report (scripts/evaluation/report_generator.py) are the
# working substitutes. Add the dedicated monitor once demographic facets and a
# ground-truth feed exist.

################################################################################
# Identifiers
################################################################################

variable "bias_monitoring_name" {
  description = "Name for the Clarify bias monitoring schedule"
  type        = string
}

variable "endpoint_name" {
  description = "SageMaker endpoint to monitor"
  type        = string
}

################################################################################
# Clarify Configuration
################################################################################

variable "clarify_image_uri" {
  description = "SageMaker Clarify container image URI"
  type        = string
}

variable "label_column" {
  description = "Name of the label column (or 'prediction' for output bias)"
  type        = string
  default     = "prediction"
}

variable "bias_schedule_expression" {
  description = "CRON or rate expression for scheduling bias analysis"
  type        = string
  default     = "cron(0 0 * * ? *)" # daily
}

################################################################################
# Infrastructure
################################################################################

variable "execution_role_arn" {
  description = "IAM role ARN used by Clarify processing jobs"
  type        = string
}

variable "results_bucket" {
  description = "S3 bucket where bias analysis outputs are written"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN for encrypting output artifacts"
  type        = string
}

variable "processing_instance_type" {
  description = "Instance type for Clarify processing jobs"
  type        = string
  default     = "ml.m5.xlarge"
}

variable "job_max_runtime_seconds" {
  description = "Maximum runtime for a single Clarify job"
  type        = number
  default     = 3600
}

################################################################################
# Baseline
################################################################################

variable "baseline_statistics_s3_uri" {
  description = "S3 URI of the baseline statistics.json file. When empty, no baseline is configured."
  type        = string
  default     = ""
}

variable "baseline_constraints_s3_uri" {
  description = "S3 URI of the baseline constraints.json file. When empty, no baseline is configured."
  type        = string
  default     = ""
}

################################################################################
# Tags
################################################################################

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}
