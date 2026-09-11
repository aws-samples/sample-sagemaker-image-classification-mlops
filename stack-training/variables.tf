# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "project_name" {
  description = "Name of the project"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}


################################################################################
# Pipeline Steps
################################################################################

# Pipeline steps configuration
variable "pipeline_steps" {
  description = "Configuration for pipeline processing steps"
  type = map(object({
    instance_type  = string
    instance_count = number
    volume_size    = number
    script_name    = string
    step_name      = string
    step_type      = string
    enable_cache   = bool
    cache_expiry   = string
  }))
}

################################################################################
# KMS
################################################################################

# KMS Configuration
variable "kms_deletion_window_days" {
  description = "KMS key deletion window (days)"
  type        = number
  default     = 7
}

variable "enable_kms_key_rotation" {
  description = "Enable KMS key rotation"
  type        = bool
  default     = true
}

################################################################################
# Data
################################################################################

# Data paths
variable "training_data_path" {
  description = "Training data S3 path"
  type        = string
  default     = "medical_image_data/"
}

# Training input mode
variable "training_input_mode" {
  description = "SageMaker training input mode"
  type        = string
  default     = "FastFile"
}

# Data configuration
variable "data_config" {
  description = "Data processing configuration"
  type = object({
    content_type     = string
    compression_type = string
    s3_data_type     = string
    s3_input_mode    = string
    s3_upload_mode   = string
  })
  default = {
    content_type     = "application/x-image"
    compression_type = "None"
    s3_data_type     = "S3Prefix"
    s3_input_mode    = "File"
    s3_upload_mode   = "EndOfJob"
  }
}

################################################################################
# Monitoring
################################################################################

# Monitoring configuration
variable "enable_training_monitoring" {
  description = "Enable training monitoring"
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "CloudWatch log retention days"
  type        = number
  default     = 30
}

variable "log_groups" {
  description = "Map of log groups to create"
  type = map(object({
    name = string
  }))
  default = {}
}

variable "dashboard_name" {
  description = "CloudWatch dashboard name"
  type        = string
  default     = null
}

variable "dashboard_config" {
  description = "Dashboard configuration JSON"
  type        = string
  default     = ""
}

variable "log_group_names" {
  description = "Log group names for metric filters"
  type        = map(string)
  default     = {}
}

variable "metric_namespaces" {
  description = "Metric namespaces for CloudWatch metrics"
  type        = map(string)
  default     = {}
}

################################################################################
# Training Models
################################################################################

# Training models configuration
variable "models" {
  description = "Configuration for all training models"
  type = map(object({
    script_name     = string
    tar_file        = string
    step_name       = string
    hyperparameters = map(string)
    volume_size     = number
    instance_count  = number
    max_runtime     = number
    instance_type   = string
    enable_cache    = bool
    cache_expiry    = string
  }))
}

################################################################################
# Training Compute Optimization
################################################################################

# Managed Spot Training and Warm Pools shared across all training steps.
# Spot can reduce training cost by 50-90% (see docs/sagemaker-modernization-analysis.md §4.1).
# Warm Pools keep provisioned clusters alive between back-to-back runs to skip ~3-5 min provisioning.
variable "enable_managed_spot_training" {
  description = "Use EC2 Spot for all training steps. Requires checkpoint support in trainers."
  type        = bool
  default     = true
}

variable "spot_max_wait_buffer_seconds" {
  description = "Extra wait time (seconds) SageMaker holds for Spot capacity on top of MaxRuntime"
  type        = number
  default     = 1800
}

variable "training_keep_alive_seconds" {
  description = "KeepAlivePeriodInSeconds for warm pools. Set to 0 to disable."
  type        = number
  default     = 1800
}

variable "pipeline_max_parallel_steps" {
  description = "Max concurrent steps a pipeline execution can run. Lets the three model trainers run in parallel."
  type        = number
  default     = 4
}

################################################################################
# S3 Buckets
################################################################################

# Bucket configuration defaults
variable "bucket_defaults" {
  description = "Default configuration for S3 buckets"
  type = object({
    force_destroy       = bool
    enable_versioning   = bool
    block_public_access = bool
  })
  default = {
    force_destroy       = true
    enable_versioning   = true
    block_public_access = true
  }
}

################################################################################
# SageMaker Images
################################################################################

# SageMaker container images
variable "sagemaker_images" {
  description = "SageMaker container image configurations"
  type = object({
    sklearn_tag              = string
    tensorflow_gpu_tag       = string
    tensorflow_cpu_tag       = string
    tensorflow_inference_tag = string
  })
  default = {
    # SageMaker prebuilt DLC tags. We pin the floating canonical tag (no -v1.X
    # suffix) so SageMaker resolves to the latest AWS-published patch of each
    # major.minor. The patched-inference-image pipeline (see
    # modules/patched-inference-image) layers additional CVE fixes on top
    # of the inference image for endpoint hosts.
    # Catalog: https://aws.github.io/deep-learning-containers/
    sklearn_tag              = "1.4-2-cpu-py3"
    tensorflow_gpu_tag       = "2.19.0-gpu-py312-cu125-ubuntu22.04-sagemaker"
    tensorflow_cpu_tag       = "2.19.0-cpu-py312-ubuntu22.04-sagemaker"
    tensorflow_inference_tag = "2.19.0-cpu-py312-ubuntu22.04-sagemaker"
  }
}

################################################################################
# EventBridge
################################################################################

variable "enable_auto_trigger" {
  description = "Enable auto-trigger of pipeline on new data upload"
  type        = bool
  default     = true
}

################################################################################
# Quality Gate
################################################################################


variable "clinical_quality_gate" {
  description = "Clinical quality gate the ensemble must clear before it can be registered. Recall is highest because a missed malignant case (false negative) is the costly error. Must mirror CLINICAL_QUALITY_THRESHOLDS in scripts/evaluation/model_evaluator.py and scripts/ensemble/ensemble_creator.py."
  type = object({
    accuracy  = number
    recall    = number
    precision = number
    auc_roc   = number
  })
  default = {
    accuracy  = 0.85
    recall    = 0.95
    precision = 0.80
    auc_roc   = 0.90
  }
}

variable "fairness_gate" {
  description = "Fairness gate the ensemble must clear before registration (Part 4). max_disparity bounds the larger of demographic-parity difference and equal-opportunity difference, computed by scripts/bias/compute_bias.py with Fairlearn. Must mirror DEFAULT_THRESHOLD in that script. sensitive_feature is reported in the bias report; the public datasets used here carry no demographic metadata, so magnification is an honest subgroup proxy - supply a real attribute for clinical use."
  type = object({
    max_disparity     = number
    sensitive_feature = string
  })
  default = {
    max_disparity     = 0.10
    sensitive_feature = "magnification"
  }
}

variable "preprocessing_target_size" {
  description = "Target square resolution (pixels) the preprocessing job resizes every image to before training. 512 preserves fine diagnostic features like microcalcifications; the trainers downsample to their own input_size from there."
  type        = number
  default     = 512
}

variable "retraining_reason" {
  description = "Reason for retraining (manual, data_upload, drift_detected)"
  type        = string
  default     = "manual"
}

################################################################################
# Network
################################################################################

variable "enable_network_isolation" {
  description = "Enable network isolation for SageMaker training and processing jobs"
  type        = bool
  default     = false
}

################################################################################
# Audit & Compliance
################################################################################

variable "enable_cloudtrail" {
  description = "Create an account-wide CloudTrail with log-file integrity validation. Required for medical ML audit trails."
  type        = bool
  default     = true
}

variable "enable_cloudtrail_sns" {
  description = "Attach an SNS delivery-notification topic to the CloudTrail. Off by default: CloudTrail cannot publish to a topic encrypted with the AWS-managed alias/aws/sns key, so enabling this requires a CMK whose policy grants the CloudTrail service principal. The trail and S3/CloudWatch delivery work without it."
  type        = bool
  default     = false
}

variable "cloudtrail_retention_days" {
  description = "Days to retain CloudTrail logs in S3 before lifecycle deletion. HIPAA requires 6 years of audit retention - typically achieved by shipping to a SIEM, not keeping everything in S3."
  type        = number
  default     = 400
}

################################################################################
# Cost Governance
################################################################################

variable "monthly_budget_usd" {
  description = "Monthly spending budget in USD (project-scoped via tag filter). Set to 0 to disable the AWS Budgets resource entirely."
  type        = number
  default     = 200

  validation {
    condition     = var.monthly_budget_usd >= 0
    error_message = "monthly_budget_usd must be non-negative."
  }
}

variable "budget_alert_emails" {
  description = "Email addresses that receive AWS Budgets alerts at 80% actual and 100% forecasted thresholds."
  type        = list(string)
  default     = []
}

################################################################################
# Supply-Chain (SBOM)
################################################################################

variable "enable_sbom_bucket" {
  description = "Create a dedicated S3 bucket to receive Syft-generated CycloneDX SBOMs from the patched-image CodeBuild. Low monthly cost; safe to leave on even if you don't wire the patched image yet."
  type        = bool
  default     = true
}

variable "sbom_retention_days" {
  description = "How long SBOM JSON files are kept before S3 expires them."
  type        = number
  default     = 730 # 2 years - matches the retention most SCA tools default to

  validation {
    condition     = var.sbom_retention_days >= 30
    error_message = "sbom_retention_days must be at least 30."
  }
}

variable "min_images_per_class" {
  description = "Minimum images required per class (benign/malignant) for the validation step to pass. Production default is 100; lower it for small test datasets."
  type        = number
  default     = 100
}

################################################################################
# Lineage / audit (DVC-style)
################################################################################

variable "dataset_version" {
  description = "Dataset version identifier (e.g. DVC hash dataset-v2.3-sha256:...) recorded on the registered model package for audit lineage. Pass from CI; defaults to 'unversioned'."
  type        = string
  default     = "unversioned"
}

variable "code_commit_sha" {
  description = "Git commit SHA that produced this model, recorded on the model package for audit lineage. Pass from CI; defaults to 'local'."
  type        = string
  default     = "local"
}

################################################################################
# Responsible AI / observability toggles
################################################################################

variable "enable_model_card" {
  description = "Create a SageMaker Model Card documenting intended use, risk rating, and clinical context for the model package group (Part 2/4)."
  type        = bool
  default     = true
}

variable "model_card_risk_rating" {
  description = "Risk rating recorded on the Model Card. High for clinical decision-support models."
  type        = string
  default     = "High"
}

variable "enable_debugger" {
  description = "Attach SageMaker Debugger built-in rules (Overfit, LossNotDecreasing) to the training steps (Part 2). Off by default; managed MLflow plus CloudWatch covers the same need."
  type        = bool
  default     = false
}

variable "debugger_rule_image" {
  description = "Region-specific SageMaker Debugger rule-evaluator image. us-east-1 default; see https://docs.aws.amazon.com/sagemaker/latest/dg/debugger-docker-images-rules.html"
  type        = string
  default     = "503895931360.dkr.ecr.us-east-1.amazonaws.com/sagemaker-debugger-rules:latest"
}

variable "enable_experiments" {
  description = "Associate each training step with a SageMaker Experiment trial component via ExperimentConfig (Part 2)."
  type        = bool
  default     = true
}

