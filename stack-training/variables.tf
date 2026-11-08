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
  description = "ARN of the permissions boundary attached to every IAM role this stack creates (stack-backend-setup output workload_boundary_arn). Required: make and the CI/CD stages pass it as TF_VAR_permissions_boundary_arn."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:policy/", var.permissions_boundary_arn))
    error_message = "permissions_boundary_arn must be the IAM policy ARN of the workload boundary (stack-backend-setup output workload_boundary_arn)."
  }
}

################################################################################
# Pipeline Steps
################################################################################

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

variable "kms_deletion_window_days" {
  description = "Waiting period in days before the project KMS key is deleted (7 to 30)."
  type        = number
  default     = 30
}

variable "kms_key_administrators" {
  description = "IAM role or user ARNs that administer the project KMS key. Empty keeps the account root as administrator, so the key can never become unmanageable; list existing principals only (the deploy role and a break-glass role)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.kms_key_administrators : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(role|user)/.+$", a))])
    error_message = "kms_key_administrators entries must be IAM role or user ARNs."
  }
}

variable "enable_kms_key_rotation" {
  description = "Enable KMS key rotation"
  type        = bool
  default     = true
}

################################################################################
# Data
################################################################################

variable "training_data_path" {
  description = "Prefix in the raw-data bucket that holds the images, one folder per label: <prefix><label>/<file>."
  type        = string
  default     = "images/"
}

variable "positive_class" {
  description = "Label folder name of the positive class (the class recall is measured on). Empty means the second class folder in alphabetical order. Passed to the pipeline steps as POSITIVE_CLASS."
  type        = string
  default     = ""
}

variable "backbone_weights_s3_uri" {
  description = "Optional S3 URI of your own backbone weights: a prefix holding one <model>.weights.h5 per model, or a single .h5 file. The training jobs may read every object whose key starts with the URI's key (the S3Prefix channel downloads them all). Add the bucket and that prefix to boundary_extra_s3_arns in stack-backend-setup. Empty trains from random initialisation."
  type        = string
  default     = ""

  validation {
    condition     = var.backbone_weights_s3_uri == "" || can(regex("^s3://[^/]+/.+$", var.backbone_weights_s3_uri))
    error_message = "backbone_weights_s3_uri must be empty or an s3://bucket/key URI."
  }
}

variable "training_input_mode" {
  description = "SageMaker training input mode"
  type        = string
  default     = "FastFile"
}

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

variable "enable_training_monitoring" {
  description = "Enable training monitoring"
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days."
  type        = number
  default     = 365
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

variable "bucket_defaults" {
  description = "Default configuration for S3 buckets"
  type = object({
    force_destroy       = bool
    enable_versioning   = bool
    block_public_access = bool
  })
  # force_destroy is true so terraform destroy empties and deletes every
  # bucket of this stack (training data, model artifacts, audit logs) in one
  # step. Set it to false to keep the buckets and their data on destroy.
  default = {
    force_destroy       = true
    enable_versioning   = true
    block_public_access = true
  }
}

################################################################################
# SageMaker Images
################################################################################

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
    # Model packages register on the patched Amazon Linux 2023 serving image
    # that stack-inference builds from; TensorFlow Serving 2.20 loads the
    # models the 2.19 training images save.
    tensorflow_gpu_tag       = "2.19.0-gpu-py312-cu125-ubuntu22.04-sagemaker"
    tensorflow_cpu_tag       = "2.19.0-cpu-py312-ubuntu22.04-sagemaker"
    tensorflow_inference_tag = "2.20-cpu-py312-amzn2023-sagemaker"
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
  default     = "images/.batch_complete"
}

################################################################################
# Upload quarantine
################################################################################

variable "enable_upload_quarantine" {
  description = "Check every object uploaded under training_data_path in the raw-data bucket with a Lambda (allowed extension, opens with Pillow as that format, minimum size) and move failing files to quarantine_prefix with a .reason.json next to each. The pipeline validation step still checks every image."
  type        = bool
  default     = true
}

variable "quarantine_prefix" {
  description = "Key prefix in the raw-data bucket that failing uploads are moved to. Must end with / and sit outside training_data_path so neither the pipeline trigger nor the preprocessing input reads it."
  type        = string
  default     = "quarantine/"

  validation {
    condition = alltrue([
      endswith(var.quarantine_prefix, "/"),
      !startswith(var.quarantine_prefix, var.training_data_path),
      !startswith(var.training_data_path, var.quarantine_prefix),
      !startswith(var.auto_trigger_marker_key, var.quarantine_prefix),
    ])
    error_message = "quarantine_prefix must end with / and must not overlap training_data_path or auto_trigger_marker_key."
  }
}

variable "quarantine_min_image_size_px" {
  description = "Uploads whose width or height is below this many pixels are quarantined. Matches the validation step's MIN_RESOLUTION default (112)."
  type        = number
  default     = 112

  validation {
    condition     = var.quarantine_min_image_size_px >= 1
    error_message = "quarantine_min_image_size_px must be at least 1."
  }
}

variable "upload_quarantine_reserved_concurrency" {
  description = "Reserved concurrency for the upload quarantine Lambda. A full dataset upload sends one event per image; the cap keeps it from using the account's whole Lambda concurrency, and throttled events are retried by Lambda's asynchronous queue."
  type        = number
  default     = 10
}

################################################################################
# Quality Gate
################################################################################


variable "quality_gate" {
  description = "Defaults of the AccuracyThreshold, RecallThreshold, PrecisionThreshold and AucThreshold pipeline parameters: the bars the ensemble must clear before it is registered. Recall is highest because a missed positive (false negative) is the costly error. The Condition step, the evaluation and ensemble steps (QUALITY_GATE) and the model package metadata read the parameter values, so a bar can be moved per execution."
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
  description = "Fairness gate the ensemble must clear before registration. max_disparity bounds the larger of demographic-parity difference and equalized-odds difference, computed by scripts/bias/compute_bias.py with Fairlearn. Must mirror DEFAULT_THRESHOLD in that script. sensitive_feature names the subgroup attribute reported in the bias report; use an attribute your data carries."
  type = object({
    max_disparity     = number
    sensitive_feature = string
  })
  default = {
    max_disparity     = 0.10
    sensitive_feature = "subgroup"
  }
}

variable "allow_not_evaluable" {
  description = "Let the fairness gate pass when the test split has fewer than two subgroups of fairness_gate.sensitive_feature, so disparity cannot be measured (status not_evaluable). Default false fails the pipeline instead; set true only for small demo datasets."
  type        = bool
  default     = false
}

variable "preprocessing_target_size" {
  description = "Target square resolution (pixels) the preprocessing job resizes every image to; the trainers downsample to their own input_size from there."
  type        = number
  default     = 512
}

variable "inference_results_retention_days" {
  description = "Days the inference-results bucket keeps the uploaded images and predictions under predictions/, and noncurrent object versions, before S3 expires them."
  type        = number
  default     = 30

  validation {
    condition     = var.inference_results_retention_days >= 1
    error_message = "inference_results_retention_days must be at least 1."
  }
}

variable "processed_data_retention_days" {
  description = "Days the processed-data bucket keeps each pipeline execution's validation report and train/validation/test splits (under executions/<execution-id>/) before S3 expires them."
  type        = number
  default     = 30

  validation {
    condition     = var.processed_data_retention_days >= 1
    error_message = "processed_data_retention_days must be at least 1."
  }
}

variable "baseline_cnn" {
  description = "Optional training step for a small CNN trained from scratch (scripts/training/simple_cnn_trainer.py), the baseline the transfer-learning members are compared against. It trains on the same splits, also scores the test split (test_metrics.json in its model artifact), and is never part of the ensemble or registered. Upload the tarball with scripts/script_uploader.sh first."
  type = object({
    enabled         = bool
    instance_type   = string
    volume_size     = number
    max_runtime     = number
    hyperparameters = map(string)
  })
  default = {
    enabled       = false
    instance_type = "ml.c5.2xlarge"
    volume_size   = 50
    max_runtime   = 7200
    hyperparameters = {
      TRAINING_EPOCHS        = "30"
      TRAINING_BATCH_SIZE    = "32"
      TRAINING_LEARNING_RATE = "0.001"
    }
  }
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
  description = "Run the training jobs with network isolation (no outbound network access from the training container); backbone_weights_s3_uri still reaches them as an input channel. Processing jobs are not isolated: they reach Amazon S3 through the training VPC (training_vpc_enabled)."
  type        = bool
  default     = true
}

variable "training_vpc_enabled" {
  description = "Run every Processing and Training job of the pipeline in a VPC this stack creates (network.tf): private subnets in two Availability Zones, no internet gateway, no NAT gateway, an S3 gateway endpoint limited to the project buckets, and a security group whose only egress is HTTPS to S3. The processing steps then install their pinned packages from the wheelhouse scripts/script_uploader.sh uploads. Ignored when vpc_config is set; false runs the jobs in the SageMaker service network as before."
  type        = bool
  default     = true
}

variable "training_vpc_cidr" {
  description = "IPv4 CIDR of the training VPC (training_vpc_enabled). It is split into two private subnets; each job instance takes up to two addresses."
  type        = string
  default     = "10.42.0.0/24"

  validation {
    condition     = can(cidrhost(var.training_vpc_cidr, 0)) && tonumber(split("/", var.training_vpc_cidr)[1]) <= 26
    error_message = "training_vpc_cidr must be an IPv4 CIDR block of /26 or larger."
  }
}

variable "training_vpc_monitoring_endpoint" {
  description = "Add a CloudWatch metrics (com.amazonaws.<region>.monitoring) interface endpoint to the training VPC so the scheduled drift and fairness jobs can run in it and still publish their metrics. Interface endpoints are billed per Availability Zone hour (two AZs here)."
  type        = bool
  default     = true
}

variable "training_vpc_flow_logs" {
  description = "Send VPC flow logs (accepted and rejected) of the training VPC to a CloudWatch log group encrypted with the project key, kept for log_retention_days."
  type        = bool
  default     = true
}

variable "vpc_config" {
  description = "Optional VPC of your own for the training and processing jobs; it takes precedence over training_vpc_enabled. The subnets need a route to Amazon S3 (gateway endpoint), and the processing steps install their packages from the wheelhouse in the scripts bucket, or from PyPI when it is reachable."
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

# On by default so every API call is audited: management events account-wide
# plus data events for the project buckets and Lambda functions. In an account
# an organization trail already covers, the management events are recorded
# twice; turn this off there and add the data events to that trail instead.
variable "enable_cloudtrail" {
  description = "Create a multi-region CloudTrail trail with log-file integrity validation that records management events and data events (S3 object-level calls on the project buckets, invocations of the project Lambda functions). Set false when an organization trail already records this account."
  type        = bool
  default     = true
}

variable "enable_cloudtrail_sns" {
  description = "Attach an SNS delivery-notification topic to the CloudTrail. Off by default. The topic is encrypted with the project CMK, whose key policy then grants the CloudTrail service principal (CloudTrail cannot publish to a topic on the AWS-managed alias/aws/sns key). The trail and S3/CloudWatch delivery work without it."
  type        = bool
  default     = false
}

variable "enable_s3_access_logging" {
  description = "Create an access-log bucket (SSE-S3, which S3 server access logging requires) and send every project bucket's server access logs to it."
  type        = bool
  default     = true
}

variable "access_log_retention_days" {
  description = "Days the access-log bucket keeps S3 server access logs."
  type        = number
  default     = 365
}

variable "audit_bucket_force_destroy" {
  description = "Let terraform destroy delete the CloudTrail log bucket with its logs. Default false keeps the audit logs; empty the bucket (or set true) before destroying the stack."
  type        = bool
  default     = false
}

variable "cloudtrail_retention_days" {
  description = "Days to retain CloudTrail logs in S3 before lifecycle deletion. Ship to a SIEM or archive if your audit policy needs longer."
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
  description = "Minimum images required per class for the validation step to pass. Lower it for small test datasets."
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
  description = "Create a SageMaker Model Card documenting intended use and risk rating for the model package group."
  type        = bool
  default     = true
}

variable "model_card_risk_rating" {
  description = "Risk rating recorded on the Model Card (Low, Medium, High or Unknown)."
  type        = string
  default     = "High"
}

variable "enable_debugger" {
  description = "Attach SageMaker Debugger built-in rules (Overfit, LossNotDecreasing) to the training steps. Off by default; the CloudWatch training metrics (and MLflow when enable_mlflow = true) cover the same need. Amazon SageMaker Debugger is no longer open to new customers; existing customers can continue to use it."
  type        = bool
  default     = false
}

variable "debugger_rule_image" {
  description = "SageMaker Debugger rule-evaluator image URI for your Region, pinned to a version tag (see https://docs.aws.amazon.com/sagemaker/latest/dg/debugger-docker-images-rules.html). Required when enable_debugger = true."
  type        = string
  default     = null

  validation {
    condition     = !var.enable_debugger || (var.debugger_rule_image != null && !endswith(coalesce(var.debugger_rule_image, ":latest"), ":latest"))
    error_message = "Set debugger_rule_image to a version-tagged image URI when enable_debugger = true."
  }
}

variable "enable_mlflow" {
  description = "Create a managed SageMaker MLflow tracking server (Small) for experiment tracking. Off by default because it is billed for every hour it runs."
  type        = bool
  default     = false
}

variable "enable_experiments" {
  description = "Associate each training step with a SageMaker Experiment trial component via ExperimentConfig."
  type        = bool
  default     = true
}

