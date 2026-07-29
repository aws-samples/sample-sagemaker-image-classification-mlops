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
# API Gateway
################################################################################

variable "api_stage_name" {
  description = "API Gateway stage name"
  type        = string
  default     = "prod"
}

variable "api_throttling_rate_limit" {
  description = "API Gateway stage-wide throttle - requests per second. Low default (20) protects a demo endpoint from bill-inflation attacks."
  type        = number
  default     = 20
}

variable "api_throttling_burst_limit" {
  description = "API Gateway stage-wide burst limit - max concurrent requests."
  type        = number
  default     = 50
}

variable "max_image_bytes" {
  description = "Max size of a base64-encoded image accepted by the /predict endpoint. Images above this size return HTTP 413 without invoking SageMaker. Default 5 MB is generous for 224x224 histopathology."
  type        = number
  default     = 5242880 # 5 MB
}

variable "inference_lambda_reserved_concurrency" {
  description = "Reserved concurrent executions for the inference API Lambda. Caps blast-radius of a traffic spike on /predict and prevents starvation of other functions in the account. -1 = unreserved (account default)."
  type        = number
  default     = 50
}

################################################################################
# Lambda
################################################################################

variable "lambda_timeout" {
  description = "Lambda function timeout in seconds"
  type        = number
  default     = 300
}

variable "lambda_memory_size" {
  description = "Lambda function memory size in MB"
  type        = number
  default     = 1024
}

################################################################################
# Monitoring
################################################################################

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 14
}

variable "alert_email" {
  description = "Email address for alerts"
  type        = string
  default     = ""
}

################################################################################
# Auto-Scaling
################################################################################

variable "endpoint_min_capacity" {
  description = "Minimum number of instances for auto-scaling"
  type        = number
  default     = 1
}

variable "endpoint_max_capacity" {
  description = "Maximum number of instances for auto-scaling"
  type        = number
  default     = 3
}

variable "target_concurrent_requests_per_model" {
  description = "Target concurrent in-flight requests per model container. Uses the SageMaker high-resolution metric (10s granularity) for sub-minute scale-out."
  type        = number
  default     = 5
}

################################################################################
# Deployment
################################################################################

variable "termination_wait_seconds" {
  description = "Seconds to wait after deployment before terminating old fleet"
  type        = number
  default     = 120
}

variable "deployment_max_timeout" {
  description = "Maximum deployment timeout in seconds (600-14400)"
  type        = number
  default     = 3600
}

################################################################################
# SageMaker Endpoint
################################################################################

variable "endpoint_instance_type" {
  description = "Instance type for SageMaker endpoint"
  type        = string
  default     = "ml.m5.xlarge"
}

variable "endpoint_initial_instance_count" {
  description = "Initial number of instances for SageMaker endpoint"
  type        = number
  default     = 1
}

variable "data_capture_sampling_percentage" {
  description = "Percentage of data to capture for monitoring (0-100)"
  type        = number
  default     = 100
}

################################################################################
# Serverless Inference (opt-in)
################################################################################

variable "use_serverless_inference" {
  description = <<-EOT
    Opt-in flag to deploy the endpoint as a SageMaker Serverless Inference
    variant instead of an always-on instance. Recommended for low-traffic
    demo/blog endpoints: scales to zero when idle and can cut the monthly
    bill from ~$170 to ~$5-10. Not recommended when Model Monitor data
    capture or strict p50 latency matter - see the sagemaker-endpoint
    module README for the full tradeoff list.
  EOT
  type        = bool
  default     = false
}

variable "serverless_memory_size_mb" {
  description = "Memory (MB) per serverless inference worker. Valid values: 1024, 2048, 3072, 4096, 5120, 6144."
  type        = number
  default     = 3072
}

variable "serverless_max_concurrency" {
  description = "Maximum concurrent invocations per serverless variant (1-200)."
  type        = number
  default     = 10
}

################################################################################
# Model Monitor
################################################################################

variable "model_monitor_config" {
  description = "Model Monitor configuration"
  type = object({
    setup_on_deploy        = bool
    data_quality_schedule  = string
    model_quality_schedule = string
    instance_type          = string
    volume_size            = number
    max_runtime            = number
  })
  default = {
    setup_on_deploy        = true
    data_quality_schedule  = "cron(0 * * * ? *)"
    model_quality_schedule = "cron(0 */6 * * ? *)"
    instance_type          = "ml.m5.xlarge"
    volume_size            = 30
    max_runtime            = 3600
  }
}

################################################################################
# Network
################################################################################


################################################################################
# Clarify Bias Monitoring
################################################################################

variable "enable_bias_monitoring" {
  description = "Enable SageMaker Clarify bias monitoring schedule"
  type        = bool
  default     = true
}

variable "enable_model_monitor" {
  description = "Enable the SageMaker Model Monitor data-quality schedule (drift detection on the prediction-score distribution). Always off for serverless endpoints, which do not support data capture."
  type        = bool
  default     = true
}

variable "bias_schedule_expression" {
  description = "CRON or rate expression for Clarify bias analysis (defaults to daily midnight UTC)"
  type        = string
  default     = "cron(0 0 * * ? *)"
}

################################################################################
# Patched Inference Image
################################################################################

variable "patched_image_source_tag" {
  description = "DLC source tag to base the patched inference image on. Use the floating major.minor tag (no -v1.X suffix) to auto-pick up the latest AWS patch version."
  type        = string
  default     = "2.19.0-cpu-py312-ubuntu22.04-sagemaker"
}

variable "dlc_ecr_registry" {
  description = "ECR registry hostname for the AWS Deep Learning Containers. Defaults to commercial-region canonical DLC registry. Override for GovCloud/CN: see https://github.com/aws/deep-learning-containers/blob/master/available_images.md"
  type        = string
  default     = "" # Empty = construct from aws_region at the provider level (see locals in data.tf)
}

variable "dlc_source_repository" {
  description = "DLC repository name to pull and patch (e.g. tensorflow-inference, pytorch-inference)"
  type        = string
  default     = "tensorflow-inference"
}

################################################################################
# Drift detection -> retraining (closed loop)
################################################################################

variable "drift_threshold" {
  description = "Model Monitor baseline-drift value (on the prediction-score distribution) above which the drift alarm fires and retraining is triggered. Matches the constraints baseline emit threshold."
  type        = number
  default     = 0.2
}

variable "drift_feature_name" {
  description = "Feature name whose feature_baseline_drift_<name> CloudWatch metric the drift alarm watches. For an image model only the model output is monitored, so this is the prediction score column from the output-only baseline."
  type        = string
  default     = "prediction_score"
}

variable "drift_alarm_period" {
  description = "Evaluation period (seconds) for the drift alarm. Should be >= the monitoring schedule interval (hourly = 3600) so each scheduled monitor run produces one data point."
  type        = number
  default     = 3600
}

################################################################################
# Hybrid inference (Amazon Bedrock)
################################################################################

variable "enable_bedrock_hybrid_inference" {
  description = "When true, the inference Lambda routes low-confidence predictions to an Amazon Bedrock foundation model for additional reasoning and a natural-language explanation (Part 3 hybrid inference). Adds bedrock:InvokeModel to the Lambda role."
  type        = bool
  default     = false
}

variable "bedrock_model_id" {
  description = "Bedrock model id (inference profile) used for low-confidence hybrid reasoning. Nova Pro is multimodal and accepts the base64 image. See https://docs.aws.amazon.com/nova/latest/userguide/modalities-image-examples.html"
  type        = string
  default     = "us.amazon.nova-pro-v1:0"
}

variable "bedrock_confidence_threshold" {
  description = "Predictions with confidence below this route to Bedrock for additional reasoning. 0.70 per the blog."
  type        = number
  default     = 0.70
}

################################################################################
# Human-in-the-loop review (Amazon A2I)
################################################################################

variable "enable_human_review" {
  description = "When true, create the A2I human-review flow and let the inference Lambda route low-confidence predictions to a radiologist review queue (Part 4 human-in-the-loop). Requires review_workteam_arn for the flow definition to be created."
  type        = bool
  default     = false
}

variable "review_workteam_arn" {
  description = "ARN of the SageMaker private workteam that reviews flagged cases. The private workforce is a one-time per-account Cognito setup outside this codebase. Empty = task UI is created but no flow definition (no review queue)."
  type        = string
  default     = ""
}

variable "enable_async_explainability" {
  description = "When true, the inference response includes a pointer to where the asynchronous Grad-CAM/SHAP explainability artifact is written (Part 4). The artifact itself is produced by an async job; the API Lambda cannot run Grad-CAM inline (no TF runtime / conv-layer access in the served ensemble)."
  type        = bool
  default     = false
}
