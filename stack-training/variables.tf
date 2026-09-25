# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "project_name" {
  description = "Name of the project, used as the prefix of every resource name. Lowercase letters, digits and hyphens. Together with environment it is capped so the longest derived name (the inference-results bucket) stays within the 63-character S3 limit."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,30}[a-z0-9]$", var.project_name))
    error_message = "project_name must be 2 to 32 characters of lowercase letters, digits and hyphens, and must start and end with a letter or digit."
  }

  validation {
    # "<project>-<environment>-inference-results-<8 hex>" must fit in 63.
    condition     = length(var.project_name) + length(var.environment) <= 35
    error_message = "project_name and environment together must be at most 35 characters so derived bucket names stay within 63 characters."
  }
}

variable "environment" {
  description = "Environment name"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.environment))
    error_message = "environment must be lowercase letters, digits and hyphens (it is part of S3 bucket names)."
  }
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "permissions_boundary_arn" {
  description = "ARN of the permissions boundary attached to every IAM role this stack creates (stack-backend-setup output workload_boundary_arn). Required when CI/CD CodeBuild applies the stack; null leaves the roles unbounded."
  type        = string
  default     = null
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
# Spot can reduce training cost by up to 90%. Warm Pools keep provisioned
# clusters alive between back-to-back runs to skip about 3-5 minutes of
# provisioning.
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
  # force_destroy stays false so terraform destroy cannot delete training
  # data, model artifacts or audit logs. Set it to true for a throwaway
  # environment you want to tear down in one step.
  default = {
    force_destroy       = false
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

variable "auto_trigger_marker_key" {
  description = "Object key prefix in the raw-data bucket whose creation starts the pipeline. scripts/data_uploader.sh writes this marker after a batch upload completes."
  type        = string
  default     = "medical_image_data/.batch_complete"
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
  description = "Fairness gate the ensemble must clear before registration (Part 4). max_disparity bounds the larger of demographic-parity difference and equalized-odds difference, computed by scripts/bias/compute_bias.py with Fairlearn. Must mirror DEFAULT_THRESHOLD in that script. sensitive_feature is reported in the bias report; the public datasets used here carry no demographic metadata, so magnification is an honest subgroup proxy - supply a real attribute for clinical use."
  type = object({
    max_disparity     = number
    sensitive_feature = string
  })
  default = {
    max_disparity     = 0.10
    sensitive_feature = "magnification"
  }
}

variable "allow_not_evaluable" {
  description = "Let the fairness gate pass when the test split has fewer than two subgroups of fairness_gate.sensitive_feature, so disparity cannot be measured (status not_evaluable). Default false fails the pipeline instead; set true only for small demo datasets."
  type        = bool
  default     = false
}

variable "preprocessing_target_size" {
  description = "Target square resolution (pixels) the preprocessing job resizes every image to before training. 512 preserves fine diagnostic features like microcalcifications; the trainers downsample to their own input_size from there."
  type        = number
  default     = 512
}

variable "retraining_reason" {
  description = "Default of the RetrainingReason pipeline parameter (manual, data_upload, drift_detected), recorded on the registered model package. The upload trigger passes data_upload and the drift alarm passes drift_detected per execution."
  type        = string
  default     = "manual"
}

################################################################################
# Network
################################################################################

variable "enable_network_isolation" {
  description = "Run the training jobs with network isolation (no outbound network access from the training container). The trainers then read ImageNet weights from s3://<scripts-bucket>/pretrained-weights/, so run scripts/download_pretrained_weights.py once before the first pipeline execution. Processing jobs are not isolated because they install Python dependencies at start-up."
  type        = bool
  default     = true
}

variable "vpc_config" {
  description = "Optional VPC for the training and processing jobs. Null runs them in the SageMaker service network. The subnets need a route to Amazon S3 (gateway endpoint), SageMaker API, CloudWatch Logs and ECR (interface endpoints or NAT); processing jobs also pip install packages, which needs a route to PyPI or a mirror."
  type = object({
    subnet_ids         = list(string)
    security_group_ids = list(string)
  })
  default = null

  validation {
    condition     = var.vpc_config == null || (length(try(var.vpc_config.subnet_ids, [])) >= 1 && length(try(var.vpc_config.subnet_ids, [])) <= 16 && length(try(var.vpc_config.security_group_ids, [])) >= 1 && length(try(var.vpc_config.security_group_ids, [])) <= 5)
    error_message = "vpc_config needs 1 to 16 subnet_ids and 1 to 5 security_group_ids."
  }
}

################################################################################
# Audit & Compliance
################################################################################

# Off by default: most accounts are already covered by an organization trail,
# and a second multi-region trail duplicates cost. Enable it only in an
# account that no organization trail covers.
variable "enable_cloudtrail" {
  description = "Create a multi-region CloudTrail trail with log-file integrity validation for this account. Leave false when an organization trail already records this account's API activity."
  type        = bool
  default     = false
}

variable "enable_cloudtrail_sns" {
  description = "Attach an SNS delivery-notification topic to the CloudTrail. Off by default. The topic is encrypted with the project CMK, whose key policy then grants the CloudTrail service principal (CloudTrail cannot publish to a topic on the AWS-managed alias/aws/sns key). The trail and S3/CloudWatch delivery work without it."
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

variable "budget_start_date" {
  description = "Start of the AWS Budgets period, in the format YYYY-MM-DD_HH:MM (UTC)."
  type        = string
  default     = "2026-01-01_00:00"

  validation {
    condition     = can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}:[0-9]{2}$", var.budget_start_date))
    error_message = "budget_start_date must look like 2026-01-01_00:00."
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
  default     = 730

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
  description = "Default of the DatasetVersion pipeline parameter (for example a DVC hash such as dataset-v2.3-sha256:...), recorded on the registered model package for audit lineage. Override per execution from CI."
  type        = string
  default     = "unversioned"
}

variable "code_commit_sha" {
  description = "Default of the CodeCommitSha pipeline parameter: the Git commit that produced the model, recorded on the model package for audit lineage. Override per execution from CI."
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
  description = "Attach SageMaker Debugger built-in rules (Overfit, LossNotDecreasing) to the training steps (Part 2). Off by default; the CloudWatch training metrics (and MLflow when enable_mlflow = true) cover the same need."
  type        = bool
  default     = false
}

variable "debugger_rule_image" {
  description = "Region-specific SageMaker Debugger rule-evaluator image. us-east-1 default; see https://docs.aws.amazon.com/sagemaker/latest/dg/debugger-docker-images-rules.html"
  type        = string
  default     = "503895931360.dkr.ecr.us-east-1.amazonaws.com/sagemaker-debugger-rules:latest"
}

variable "enable_mlflow" {
  description = "Create a managed SageMaker MLflow tracking server (Small) for experiment tracking. Off by default because it is billed for every hour it runs."
  type        = bool
  default     = false
}

variable "enable_experiments" {
  description = "Associate each training step with a SageMaker Experiment trial component via ExperimentConfig (Part 2)."
  type        = bool
  default     = true
}

