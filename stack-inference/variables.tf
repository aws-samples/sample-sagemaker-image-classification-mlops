# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "project_name" {
  description = "Name of the project. Prefixes every resource name."
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
  description = "ARN of the permissions boundary attached to every IAM role this stack creates (stack-backend-setup output workload_boundary_arn). Required: make and the CI/CD stages pass it as TF_VAR_permissions_boundary_arn."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:policy/", var.permissions_boundary_arn))
    error_message = "permissions_boundary_arn must be the IAM policy ARN of the workload boundary (stack-backend-setup output workload_boundary_arn)."
  }
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
    Authorization on POST /predict and GET /results/{id}. The API key, usage
    plan and WAF apply in every mode.
      - "NONE" (default, API key mode): the key is visible to anyone who
        loads the frontend, so it limits and meters callers but does not
        authenticate them. The static frontend works in this mode only.
      - "COGNITO_USER_POOLS": Amazon Cognito authenticates application
        users. The stack creates a user pool and app client
        (unless api_cognito_user_pool_arns names existing pools); callers send
        the user's ID token in the Authorization header. The static frontend
        has no sign-in flow yet.
      - "AWS_IAM": callers sign with SigV4 and need execute-api:Invoke on the
        API (browsers get credentials from a Cognito identity pool).
  EOT
  type        = string
  default     = "NONE"

  validation {
    condition     = contains(["NONE", "AWS_IAM", "COGNITO_USER_POOLS"], var.api_authorization_type)
    error_message = "api_authorization_type must be NONE, AWS_IAM or COGNITO_USER_POOLS."
  }
}

variable "api_cognito_user_pool_arns" {
  description = "Existing Cognito user pool ARNs for the API authorizer when api_authorization_type = \"COGNITO_USER_POOLS\". Empty (default) creates a user pool in this stack."
  type        = list(string)
  default     = []
}

variable "cognito_mfa_configuration" {
  description = "MFA for the stack's Cognito user pool: OPTIONAL (default; users can add an authenticator app) or ON (every user sets up an authenticator app at first sign-in)."
  type        = string
  default     = "OPTIONAL"

  validation {
    condition     = contains(["OPTIONAL", "ON"], var.cognito_mfa_configuration)
    error_message = "cognito_mfa_configuration must be OPTIONAL or ON."
  }
}

variable "cognito_threat_protection_mode" {
  description = "Cognito threat protection (compromised credentials, adaptive authentication) for the stack's user pool: OFF (default, Essentials feature plan), AUDIT or ENFORCED. AUDIT and ENFORCED switch the pool to the Plus feature plan, which is billed per monthly active user."
  type        = string
  default     = "OFF"

  validation {
    condition     = contains(["OFF", "AUDIT", "ENFORCED"], var.cognito_threat_protection_mode)
    error_message = "cognito_threat_protection_mode must be OFF, AUDIT or ENFORCED."
  }
}

variable "cognito_deletion_protection" {
  description = "Turn on deletion protection for the stack's Cognito user pool. Off by default so terraform destroy removes the pool with the stack; turn it on when the pool holds real users."
  type        = bool
  default     = false
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
  description = "Max size of a base64-encoded image accepted by the /predict endpoint. Images above this size return HTTP 413 without invoking SageMaker. Default 5 MB is generous for 224x224 images."
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
  default     = 365
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
  description = "Minimum number of instances for auto-scaling. 2 by default because canary and linear traffic shifting cannot split a single instance."
  type        = number
  default     = 2
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

variable "traffic_routing_type" {
  description = "Blue/green traffic shifting for endpoint updates, including approval-driven and weekly-refresh rollouts: CANARY (canary_size_percent of the new fleet first, then the rest), LINEAR (linear_step_percent per step) or ALL_AT_ONCE. CANARY and LINEAR need endpoint_initial_instance_count and endpoint_min_capacity of at least 2. Serverless endpoints always use ALL_AT_ONCE."
  type        = string
  default     = "CANARY"
}

variable "canary_size_percent" {
  description = "Percentage of the new fleet that takes traffic during the canary step (1-50). Capacity comes in whole instances, so with 2 instances the canary is 1 instance, half the fleet."
  type        = number
  default     = 10
}

variable "linear_step_percent" {
  description = "Percentage of the new fleet turned on per LINEAR step (10-50)."
  type        = number
  default     = 20
}

variable "traffic_shift_wait_interval" {
  description = "Baking period in seconds after each traffic shift step while the rollback alarms watch the new fleet (0-3600). The alarms need about 3 minutes to fire (2 one-minute periods plus CloudWatch delay), so keep it above that."
  type        = number
  default     = 300
}

variable "termination_wait_seconds" {
  description = "Seconds to wait after the new fleet takes all traffic before the old fleet is terminated (0-3600)"
  type        = number
  default     = 120
}

variable "deployment_max_timeout" {
  description = "Maximum deployment time in seconds (600-28800). Must exceed the traffic shift waits plus termination_wait_seconds."
  type        = number
  default     = 3600
}

################################################################################
# SageMaker Endpoint
################################################################################

variable "endpoint_network_isolation" {
  description = "Run the endpoint's inference container with network isolation (no outbound network). The auto-deploy Lambda creates its models the same way."
  type        = bool
  default     = true
}

variable "endpoint_instance_type" {
  description = "Instance type for SageMaker endpoint"
  type        = string
  default     = "ml.m5.xlarge"
}

variable "endpoint_initial_instance_count" {
  description = "Instances in the endpoint's production variant, for the Terraform-created and auto-deployed endpoint configs. 2 by default because canary and linear traffic shifting cannot split a single instance; use 1 only with traffic_routing_type = ALL_AT_ONCE."
  type        = number
  default     = 2
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
    bill from ~$340 (two instances) to ~$5-10. Updates then shift all
    traffic at once (no canary). Not recommended when drift-detection data
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
  description = "Enable the scheduled fairness Processing job. EventBridge Scheduler starts a SageMaker Processing job that joins endpoint data capture with the confirmed labels you upload, computes demographic parity and equalized odds per subgroup with Fairlearn, and publishes the largest disparity to CloudWatch beside the drift metric. The alarm feeds the same retrain rule. Requires data capture, so it is skipped for serverless endpoints."
  type        = bool
  default     = true
}

variable "fairness_job_schedule_expression" {
  description = "Schedule on which the fairness Processing job runs. Daily by default: confirmed labels usually arrive slowly, so a tighter schedule would mostly re-score the same records."
  type        = string
  default     = "rate(1 day)"
}

variable "fairness_ground_truth_prefix" {
  description = "Prefix in the monitoring bucket where confirmed labels are uploaded as JSON Lines: {\"request_id\": ..., \"label\": 0|1, \"group\": \"<subgroup>\"}. Predictions with no matching label are skipped, never guessed."
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
  description = "DLC source tag to base the patched inference image on. Use the floating major.minor tag (no -v1.X suffix) to auto-pick up the latest AWS patch version, and move to a newer major.minor when AWS stops publishing patches for this one (the 2.19 Ubuntu tag stopped on 2026-03-10)."
  type        = string
  default     = "2.20-cpu-py312-amzn2023-sagemaker"
}

variable "dlc_ecr_registry" {
  description = "ECR registry hostname for the AWS Deep Learning Containers. Defaults to commercial-region canonical DLC registry. Override for GovCloud/CN: see https://github.com/aws/deep-learning-containers/blob/master/available_images.md"
  type        = string
  default     = "" # Empty = built from aws_region (see locals in data.tf)
}

variable "patched_image_scan_block_severity" {
  description = "Scan gate of the weekly patched image build: an image with an Amazon ECR scan finding at or above this severity is deleted and the build fails, so the endpoint keeps the last image that passed (an alarm notifies alert_email). CRITICAL (default), HIGH, MEDIUM, LOW, or NONE to turn the gate off."
  type        = string
  default     = "CRITICAL"
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

variable "bedrock_guardrail_image_filters" {
  description = "Also run the guardrail's HATE, INSULTS, SEXUAL and VIOLENCE filters on the image sent to the foundation model. The Bedrock image content filter is generally available in us-east-1, us-west-2, eu-central-1 and ap-northeast-1 and in preview in some other Regions; set false in a Region without it."
  type        = bool
  default     = true
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

variable "enable_request_explanations" {
  description = "Allow POST /predict callers to ask for explanations (Part 4) with \"explain\": true (Grad-CAM heatmap and region Shapley values, computed on the endpoint). Requests without the field are unaffected either way. When false, a request that asks gets \"explanations\": {\"status\": \"disabled\"}."
  type        = bool
  default     = true
}

variable "explanation_max_evaluations" {
  description = "Cap on masked-image ensemble evaluations for the region Shapley estimate in one explained request. 17 is one permutation of the 4x4 regions, 32 an antithetic pair, 64 two pairs."
  type        = number
  default     = 32

  validation {
    condition     = var.explanation_max_evaluations >= 17 && var.explanation_max_evaluations <= 64
    error_message = "explanation_max_evaluations must be between 17 and 64."
  }
}

variable "gradcam_border_band" {
  description = "Width of the image border band, as a fraction of each side, for the Grad-CAM border check. An explained prediction whose heatmap puts more than gradcam_border_threshold of its mass in this band is returned with \"attention_on_border\": true."
  type        = number
  default     = 0.1

  validation {
    condition     = var.gradcam_border_band > 0 && var.gradcam_border_band < 0.5
    error_message = "gradcam_border_band must be greater than 0 and less than 0.5."
  }
}

variable "gradcam_border_threshold" {
  description = "Share of the Grad-CAM mass in the border band (gradcam_border_band) above which an explained prediction is flagged with \"attention_on_border\": true."
  type        = number
  default     = 0.5

  validation {
    condition     = var.gradcam_border_threshold > 0 && var.gradcam_border_threshold < 1
    error_message = "gradcam_border_threshold must be between 0 and 1."
  }
}

variable "explanation_time_budget_ms" {
  description = "Time budget for the explain path on the endpoint, in milliseconds. Region Shapley skips permutations that would overrun it (the first always runs). Keep it well under API Gateway's 29 s integration timeout."
  type        = number
  default     = 5000

  validation {
    condition     = var.explanation_time_budget_ms >= 1000 && var.explanation_time_budget_ms <= 25000
    error_message = "explanation_time_budget_ms must be between 1000 and 25000."
  }
}

################################################################################
# Teardown
################################################################################

variable "force_destroy_buckets" {
  description = "Let terraform destroy delete this stack's frontend bucket with its objects and versions. True by default so the stack tears down in one step; set false to keep the bucket when it is not empty."
  type        = bool
  default     = true
}

variable "test_traffic_enabled" {
  description = "Send synthetic test traffic (test_traffic.tf): once an hour at a random minute, 1 to test_traffic_max_requests images from the raw-data bucket go to the inference function, so the drift and fairness jobs have predictions to measure. Test deployments only."
  type        = bool
  default     = false
}

variable "test_traffic_end_date" {
  description = "UTC time (RFC 3339, e.g. 2026-11-28T00:00:00Z) after which the test traffic schedule stops. Required when test_traffic_enabled = true."
  type        = string
  default     = null

  validation {
    condition     = !var.test_traffic_enabled || can(formatdate("YYYY", var.test_traffic_end_date))
    error_message = "Set test_traffic_end_date to an RFC 3339 UTC time when test_traffic_enabled = true."
  }
}

variable "test_traffic_max_requests" {
  description = "Most predictions one test traffic run sends; each run picks 1 to this many at random."
  type        = number
  default     = 5

  validation {
    condition     = var.test_traffic_max_requests >= 1 && var.test_traffic_max_requests <= 20
    error_message = "test_traffic_max_requests must be between 1 and 20."
  }
}

variable "test_traffic_explain_rate" {
  description = "Share of test traffic requests that ask for explanations (Grad-CAM and region Shapley); explanations are CPU heavy on the endpoint."
  type        = number
  default     = 0.1

  validation {
    condition     = var.test_traffic_explain_rate >= 0 && var.test_traffic_explain_rate <= 1
    error_message = "test_traffic_explain_rate must be between 0 and 1."
  }
}
