# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "project_name" {
  description = "Name of the project. Prefixes every resource name."
  type        = string

  # The scheduled drift and fairness jobs build a ProcessingJobName as
  # "<project_name>-fairness-<aws.scheduler.execution-id>". SageMaker caps that
  # name at 63 characters and the Scheduler substitutes a ~16-character id, so a
  # long project name would only fail when the schedule fires - the apply would
  # succeed and the job would then silently never run. Fail at plan time instead.
  validation {
    condition     = length(var.project_name) <= 38
    error_message = "project_name must be 38 characters or fewer: it is prefixed onto the scheduled fairness job's ProcessingJobName, which SageMaker caps at 63 characters after EventBridge Scheduler substitutes a ~16-character execution id."
  }
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "state_bucket_name" {
  description = "Name of the Terraform state bucket (stack-backend-setup output state_bucket_id). The inference stack reads the training stack's outputs from it."
  type        = string

  validation {
    condition     = var.state_bucket_name != ""
    error_message = "Set state_bucket_name to the stack-backend-setup output state_bucket_id (make passes it as TF_VAR_state_bucket_name)."
  }
}

variable "state_bucket_region" {
  description = "Region of the Terraform state bucket (stack-backend-setup output state_bucket_region). If empty, aws_region is used."
  type        = string
  default     = ""
}

variable "permissions_boundary_arn" {
  description = "ARN of the permissions boundary attached to every IAM role this stack creates (stack-backend-setup output workload_boundary_arn). Required when CI/CD CodeBuild applies the stack; null leaves the roles unbounded."
  type        = string
  default     = null
}

################################################################################
# API Gateway
################################################################################

variable "api_stage_name" {
  description = "API Gateway stage name"
  type        = string
  default     = "prod"
}

variable "api_authorization_type" {
  description = <<-EOT
    Authorization on POST /predict and GET /results/{id}. "NONE" (default)
    relies on the API key, usage plan and WAF; the key is visible to anyone who
    loads the frontend, so it limits and meters callers but does not
    authenticate them. To authenticate:
      - "AWS_IAM": callers sign with SigV4 and need execute-api:Invoke on the
        API (browsers get credentials from a Cognito identity pool).
      - "COGNITO_USER_POOLS": set api_cognito_user_pool_arns; callers send the
        user pool ID token in the Authorization header. The static frontend
        would need a sign-in flow added.
  EOT
  type        = string
  default     = "NONE"
}

variable "api_cognito_user_pool_arns" {
  description = "Cognito user pool ARNs for the API authorizer when api_authorization_type = \"COGNITO_USER_POOLS\"."
  type        = list(string)
  default     = []
}

variable "api_require_api_key" {
  description = "Require the x-api-key header on the API. The key is created with a usage plan and injected into the static frontend's config."
  type        = bool
  default     = true
}

variable "api_enable_waf" {
  description = "Associate a regional AWS WAF web ACL (AWS managed common rule set + per-IP rate-based rule) with the API stage."
  type        = bool
  default     = true
}

variable "api_waf_rate_limit" {
  description = "Requests per client IP in any 5-minute window before the WAF rate-based rule blocks that IP."
  type        = number
  default     = 300
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

variable "model_package_arn" {
  description = "Versioned ARN of the Approved model package the endpoint starts with (arn:aws:sagemaker:<region>:<account>:model-package/<group>/<version>). Seed and approve a baseline first (CI/CD baseline-model stage or stack-cicd/scripts/create_baseline_model.py). Later approvals are rolled out by the auto-deploy Lambda."
  type        = string
  default     = ""
}

variable "data_capture_sampling_percentage" {
  description = "Percentage of endpoint invocations written to data capture (0-100). Applies to the Terraform-managed and auto-deployed endpoint configs."
  type        = number
  default     = 100
}

variable "data_capture_input" {
  description = "Also capture request payloads. Off by default: drift and fairness monitoring read model output only, and Input capture stores every uploaded image."
  type        = bool
  default     = false
}

################################################################################
# Serverless Inference (opt-in)
################################################################################

variable "use_serverless_inference" {
  description = <<-EOT
    Opt-in flag to deploy the endpoint as a SageMaker Serverless Inference
    variant instead of an always-on instance. Recommended for low-traffic
    demo/blog endpoints: scales to zero when idle and can cut the monthly
    bill from ~$170 to ~$5-10. Not recommended when drift-detection data
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
# Scheduled drift Processing job
################################################################################

variable "enable_drift_job" {
  description = "Enable the scheduled drift Processing job (Part 3). EventBridge Scheduler starts a SageMaker Processing job that reads endpoint data-capture output from S3, computes a Population Stability Index against the training baseline, and publishes it to CloudWatch, where the drift alarm and the EventBridge retrain rule consume it. Requires data capture, so it is skipped for serverless endpoints."
  type        = bool
  default     = true
}

variable "drift_detector_schedule_expression" {
  description = "Schedule on which the drift Processing job runs. Should be no more frequent than the lookback window is long."
  type        = string
  default     = "rate(1 hour)"
}

variable "drift_detector_lookback_hours" {
  description = "How many hours of captured predictions the drift detector compares against the baseline on each run."
  type        = number
  default     = 24
}

variable "drift_detector_min_samples" {
  description = "Minimum captured predictions required before the detector publishes a PSI. Below this it publishes nothing, so quiet periods cannot raise a false drift alarm."
  type        = number
  default     = 30
}

variable "drift_job_instance_type" {
  description = "Instance type for the scheduled drift Processing job. The job is IO-bound over a few thousand small JSON records, so the smallest general-purpose type is sufficient."
  type        = string
  default     = "ml.t3.medium"
}

variable "drift_job_max_runtime" {
  description = "MaxRuntimeInSeconds for the drift Processing job. Caps cost if a capture prefix grows unexpectedly large."
  type        = number
  default     = 900
}

variable "monitoring_job_image_tag" {
  description = "Tag of the AWS-managed scikit-learn Processing image used to run the scheduled drift and fairness scripts. Must carry a numpy/pandas/scikit-learn stack that already satisfies Fairlearn, otherwise pip upgrades numpy at job start and the container's pre-compiled scikit-learn fails with a binary-incompatibility ValueError. The 1.2-1 image is too old on both counts (pandas 1.1.3)."
  type        = string
  default     = "1.4-2-cpu-py3"
}

################################################################################
# Ongoing fairness monitoring (Part 4)
################################################################################

variable "enable_fairness_job" {
  description = "Enable the scheduled fairness Processing job (Part 4). EventBridge Scheduler starts a SageMaker Processing job that joins endpoint data capture with the confirmed diagnostic outcomes clinicians upload, computes demographic parity and equalized odds per subgroup with Fairlearn, and publishes the largest disparity to CloudWatch beside the drift metric. The alarm feeds the same retrain rule. Requires data capture, so it is skipped for serverless endpoints."
  type        = bool
  default     = true
}

variable "fairness_job_schedule_expression" {
  description = "Schedule on which the fairness Processing job runs. Daily by default: confirmed outcomes arrive on a clinical cadence, so a tighter schedule would mostly re-score the same records."
  type        = string
  default     = "rate(1 day)"
}

variable "fairness_ground_truth_prefix" {
  description = "Prefix in the monitoring bucket where confirmed diagnostic outcomes are uploaded as JSON Lines: {\"request_id\": ..., \"label\": 0|1, \"group\": \"<subgroup>\"}. Predictions with no matching label are skipped, never guessed."
  type        = string
  default     = "ground-truth"
}

variable "fairness_job_lookback_hours" {
  description = "How many hours of captured predictions and confirmed outcomes the fairness job scores on each run. Wider than the drift window (a week by default) because ground truth lags the prediction it confirms."
  type        = number
  default     = 168
}

variable "fairness_job_min_samples" {
  description = "Minimum prediction/outcome pairs required before the fairness job publishes a disparity. Below this it publishes nothing, so a thin join cannot raise a false fairness alarm."
  type        = number
  default     = 50
}

variable "fairness_disparity_threshold" {
  description = "Disparity above which the fairness alarm fires and retraining is triggered. Bounds the larger of demographic-parity difference and equalized-odds difference on live traffic. Mirrors var.fairness_gate.max_disparity in stack-training so the deployed model is held to the same bar it was registered under."
  type        = number
  default     = 0.10
}

variable "fairness_alarm_period" {
  description = "Evaluation period (seconds) for the fairness alarm. Should be >= the fairness schedule interval (daily = 86400) so each scheduled run produces one data point."
  type        = number
  default     = 86400
}

variable "fairness_job_instance_type" {
  description = "Instance type for the scheduled fairness Processing job. The job is IO-bound over a few thousand small JSON records, so the smallest general-purpose type is sufficient."
  type        = string
  default     = "ml.t3.medium"
}

variable "fairness_job_max_runtime" {
  description = "MaxRuntimeInSeconds for the fairness Processing job. Caps cost if the capture or ground-truth prefix grows unexpectedly large."
  type        = number
  default     = 900
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
  default     = "" # Empty = built from aws_region (see locals in data.tf)
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
  description = "Population Stability Index on the prediction-score distribution above which the drift alarm fires and retraining is triggered."
  type        = number
  default     = 0.2
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
  description = "Opt in to Amazon A2I human review: create the review flow and let the inference Lambda route low-confidence predictions to a reviewer queue. Amazon A2I is in maintenance mode (no longer open to new customers), so this is off by default and only works in accounts that already use A2I. Requires review_workteam_arn for the flow definition."
  type        = bool
  default     = false
}

variable "review_workteam_arn" {
  description = "ARN of the SageMaker private workteam that reviews flagged cases. The private workforce is a one-time per-account Cognito setup outside this codebase. Empty = task UI is created but no flow definition (no review queue)."
  type        = string
  default     = ""
}

variable "enable_async_explainability" {
  description = "When true, the inference response includes a pointer to where an asynchronous Grad-CAM explainability artifact would be written. No job in this sample writes it: turn this on only after you add your own job that does. The API Lambda cannot run Grad-CAM inline (no TF runtime or conv-layer access in the served ensemble)."
  type        = bool
  default     = false
}
