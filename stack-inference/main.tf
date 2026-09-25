# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

module "sagemaker_endpoint" {
  source = "../modules/terraform-aws-sagemaker-endpoint"

  project_name                         = var.project_name
  endpoint_name                        = local.endpoint_name
  execution_role_arn                   = data.terraform_remote_state.training.outputs.sagemaker_execution_role_arn
  model_package_group_name             = data.terraform_remote_state.training.outputs.model_package_group_name
  model_package_arn                    = var.model_package_arn
  serving_image_uri                    = module.patched_inference_image.image_uri
  initial_instance_count               = var.endpoint_initial_instance_count
  instance_type                        = var.endpoint_instance_type
  data_capture_sampling_percentage     = var.data_capture_sampling_percentage
  data_capture_input                   = var.data_capture_input
  monitoring_bucket                    = local.training_outputs.monitoring_bucket
  volume_kms_key_arn                   = local.training_outputs.kms_key_arn
  min_capacity                         = var.endpoint_min_capacity
  max_capacity                         = var.endpoint_max_capacity
  target_concurrent_requests_per_model = var.target_concurrent_requests_per_model

  # Serverless inference opt-in. When true, the module swaps the production
  # variant to serverless (scales to zero) and skips DataCaptureConfig and
  # Application Auto Scaling. See the module README for tradeoffs.
  use_serverless_inference   = var.use_serverless_inference
  serverless_memory_size_mb  = var.serverless_memory_size_mb
  serverless_max_concurrency = var.serverless_max_concurrency

  traffic_shift_wait_interval = 60
  termination_wait_seconds    = var.termination_wait_seconds
  deployment_max_timeout      = var.deployment_max_timeout
}

# Terraform owns the endpoint; the auto-deploy Lambda repoints its endpoint
# config when a new model version is approved.

################################################################################
# Lambda
################################################################################

module "inference_lambda" {
  source = "../modules/terraform-aws-lambda"

  for_each = local.lambda_configs

  source_dir            = "${path.module}/lambda"
  function_name         = "${var.project_name}-${each.key}"
  execution_role_arn    = module.inference_lambda_role.role_arn
  handler               = each.value.handler
  timeout               = var.lambda_timeout
  memory_size           = var.lambda_memory_size
  environment_variables = each.value.environment
  layers                = each.key == "inference_api" ? [local.pillow_layer_arn] : []

  log_retention_days = var.log_retention_days
  log_kms_key_arn    = local.training_outputs.kms_key_arn

  # Encrypt env vars with the same CMK (defense-in-depth - env vars are
  # already encrypted at rest with AWS-managed key by default).
  env_kms_key_arn = local.training_outputs.kms_key_arn

  # Reserved concurrency on the public inference_api - caps cost exposure
  # and prevents a traffic spike on /predict from starving other functions.
  # endpoint_refresher is EventBridge-triggered weekly, so no cap needed.
  reserved_concurrent_executions = each.key == "inference_api" ? var.inference_lambda_reserved_concurrency : -1

  # Traces the API Gateway, Lambda and SageMaker hops.
  enable_xray_tracing = true
}

################################################################################
# Dashboard
################################################################################

resource "aws_cloudwatch_dashboard" "inference_dashboard" {
  dashboard_name = "${var.project_name}-inference-dashboard"
  dashboard_body = local.dashboard_config
}

################################################################################
# SNS Alerts
################################################################################

module "sns_alerts" {
  source = "../modules/terraform-aws-sns"

  topic_name     = "${var.project_name}-inference-alerts"
  email_endpoint = var.alert_email
  alarms         = local.alarms_config

  composite_alarm = {
    alarm_name        = "${var.project_name}-inference-health"
    alarm_description = "Overall inference pipeline health"
    alarm_rule = join(" OR ", [
      "ALARM(${var.project_name}-api-5xx-errors)",
      "ALARM(${var.project_name}-sagemaker-endpoint-errors)"
    ])
  }
}

################################################################################
# API Gateway
################################################################################

# Access control on the public API (defaults): an API key through a usage
# plan, a regional WAF web ACL (AWS managed common rules + per-IP rate limit),
# stage throttling, and CORS locked to the CloudFront origin. The key meters
# callers but is visible in the frontend; switch api_authorization_type to
# AWS_IAM or COGNITO_USER_POOLS to authenticate users.
module "api_gateway" {
  source = "../modules/terraform-aws-api-gateway"

  api_name            = "${var.project_name}-inference-api"
  stage_name          = var.api_stage_name
  lambda_function_arn = module.inference_lambda["inference_api"].function_arn
  cors_allowed_origin = local.frontend_origin

  authorization_type     = var.api_authorization_type
  cognito_user_pool_arns = var.api_cognito_user_pool_arns
  require_api_key        = var.api_require_api_key
  enable_waf             = var.api_enable_waf
  waf_rate_limit         = var.api_waf_rate_limit

  throttling_rate_limit  = var.api_throttling_rate_limit
  throttling_burst_limit = var.api_throttling_burst_limit
  enable_access_logging  = true
  enable_xray_tracing    = true
  log_retention_days     = var.log_retention_days
  log_kms_key_arn        = local.training_outputs.kms_key_arn

  permissions_boundary_arn = var.permissions_boundary_arn
}

# Lambda permission for API Gateway
resource "aws_lambda_permission" "api_gateway_invoke" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = module.inference_lambda["inference_api"].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${module.api_gateway.execution_arn}/*/*"
}

################################################################################
# IAM
################################################################################

module "inference_lambda_role" {
  source = "../modules/terraform-aws-iam"

  role_name                = "${var.project_name}-lambda-execution-role"
  permissions_boundary_arn = var.permissions_boundary_arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  ]

  inline_policies = {
    lambda_permissions = jsonencode({
      Version = "2012-10-17"
      Statement = concat([
        {
          Effect = "Allow"
          Action = [
            "s3:GetObject",
            "s3:PutObject",
            "s3:ListBucket"
          ]
          Resource = [
            "arn:aws:s3:::${local.training_outputs.inference_bucket}",
            "arn:aws:s3:::${local.training_outputs.inference_bucket}/*"
          ]
        },
        {
          # Read-only on the monitoring bucket for the drift detector: it lists
          # the data-capture prefix and reads the baseline statistics. No write
          # access - the detector only publishes to CloudWatch.
          Effect = "Allow"
          Action = [
            "s3:GetObject",
            "s3:ListBucket"
          ]
          Resource = [
            "arn:aws:s3:::${local.training_outputs.monitoring_bucket}",
            "arn:aws:s3:::${local.training_outputs.monitoring_bucket}/*"
          ]
        },
        {
          Effect = "Allow"
          Action = [
            "kms:Decrypt",
            "kms:GenerateDataKey",
            "kms:DescribeKey"
          ]
          Resource = [
            data.terraform_remote_state.training.outputs.kms_key_arn
          ]
        },
        {
          # InvokeEndpoint scoped to THIS project's endpoint so a compromised
          # inference Lambda can't call other endpoints in the account.
          Effect = "Allow"
          Action = [
            "sagemaker:InvokeEndpoint"
          ]
          Resource = [
            "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:endpoint/${local.endpoint_name}"
          ]
        },
        {
          # PutMetricData has no resource-level scoping in AWS.
          Effect   = "Allow"
          Action   = ["cloudwatch:PutMetricData"]
          Resource = "*"
        },
        {
          Effect = "Allow"
          Action = [
            "sagemaker:DescribeEndpoint",
            "sagemaker:DescribeEndpointConfig",
            "sagemaker:CreateEndpointConfig",
            "sagemaker:UpdateEndpoint",
          ]
          Resource = [
            "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:endpoint/${local.endpoint_name}",
            "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:endpoint-config/*",
          ]
        },
        {
          # Endpoint refresher cleanup: list the refresh configs of earlier
          # runs, then delete only those (refresh_prefix in
          # lambda/endpoint_refresher.py). ListEndpointConfigs has no
          # resource-level scoping.
          Effect   = "Allow"
          Action   = ["sagemaker:ListEndpointConfigs"]
          Resource = "*"
        },
        {
          Effect = "Allow"
          Action = ["sagemaker:DeleteEndpointConfig"]
          Resource = [
            "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:endpoint-config/${substr(local.endpoint_name, 0, 40)}-refresh-*",
          ]
        },
        {
          # The cloned config keeps the project CMK (KmsKeyId) for the ML
          # storage volume; SageMaker needs a grant from the caller of
          # UpdateEndpoint to attach it.
          Effect   = "Allow"
          Action   = ["kms:CreateGrant"]
          Resource = [data.terraform_remote_state.training.outputs.kms_key_arn]
          Condition = {
            Bool = { "kms:GrantIsForAWSResource" = "true" }
          }
        },
        {
          # PassRole for the execution role (ExecutionRoleArn) the cloned
          # endpoint config may carry. The refresher attaches no new role.
          Effect = "Allow"
          Action = ["iam:PassRole"]
          Resource = [
            "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-*",
          ]
          Condition = {
            StringEquals = {
              "iam:PassedToService" = "sagemaker.amazonaws.com"
            }
          }
        },
        # X-Ray tracing - required when the Lambda module sets
        # tracing_config.mode = "Active". Without this the function starts
        # up but fails to publish trace segments.
        {
          Effect = "Allow"
          Action = [
            "xray:PutTraceSegments",
            "xray:PutTelemetryRecords",
          ]
          Resource = "*"
        },
        ], var.enable_bedrock_hybrid_inference ? [
        # Hybrid inference: invoke the Bedrock FM for low-confidence reasoning.
        # Covers both the foundation model and the cross-region inference
        # profile (the `us.` model id resolves through an inference profile,
        # which in turn invokes the regional foundation models), and applies
        # this stack's guardrail only.
        {
          Effect = "Allow"
          Action = ["bedrock:InvokeModel"]
          Resource = [
            "arn:aws:bedrock:*::foundation-model/*",
            "arn:aws:bedrock:*:${data.aws_caller_identity.current.account_id}:inference-profile/*",
          ]
        },
        {
          Effect   = "Allow"
          Action   = ["bedrock:ApplyGuardrail"]
          Resource = [aws_bedrock_guardrail.hybrid[0].guardrail_arn]
        },
        ] : [], var.enable_human_review ? [
        {
          # Optional A2I review: start a human loop on this project's flow.
          Effect = "Allow"
          Action = [
            "sagemaker:StartHumanLoop"
          ]
          Resource = [
            "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:flow-definition/${var.project_name}-*"
          ]
        }
      ] : [])
    })
  }
}

################################################################################
# Weekly Endpoint Refresh - keeps instance OS patches up to date
################################################################################

# Fires the endpoint_refresher Lambda weekly so the endpoint rolls onto
# freshly provisioned hosts. Long-lived endpoint instances accumulate host OS
# patch findings even when the container image itself is current.
#
# NOT applicable to serverless endpoints - they provision fresh workers per
# request and don't accumulate host OS staleness. Skip the whole refresh
# mechanism when use_serverless_inference = true.

resource "aws_cloudwatch_event_rule" "weekly_endpoint_refresh" {
  count = var.use_serverless_inference ? 0 : 1

  name                = "${var.project_name}-endpoint-refresh-weekly"
  description         = "Weekly trigger that rolls the SageMaker endpoint for OS patching"
  schedule_expression = "cron(0 6 ? * SUN *)" # Sundays at 06:00 UTC
}

resource "aws_cloudwatch_event_target" "weekly_endpoint_refresh" {
  count = var.use_serverless_inference ? 0 : 1

  rule      = aws_cloudwatch_event_rule.weekly_endpoint_refresh[0].name
  target_id = "endpoint-refresher"
  arn       = module.inference_lambda["endpoint_refresher"].function_arn
}

resource "aws_lambda_permission" "eventbridge_invoke_refresher" {
  count = var.use_serverless_inference ? 0 : 1

  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = module.inference_lambda["endpoint_refresher"].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.weekly_endpoint_refresh[0].arn
}

################################################################################
# Patched inference image - the one serving image
################################################################################

# The public AWS DLC (`tensorflow-inference:2.19.0-cpu-py312-...`) accumulates
# OS-level CVEs between AWS-published patch releases. This module stands up a
# private, immutable ECR repo, a CodeBuild project that layers
# `apt-get dist-upgrade` + `pip --upgrade` on top of the DLC, and a monthly
# rebuild. Both the Terraform-managed model and the auto-deploy Lambda run the
# newest build pinned by digest. Re-apply after a rebuild so the next
# deployment uses the new digest.

module "patched_inference_image" {
  source = "../modules/terraform-aws-patched-inference-image"

  project_name      = var.project_name
  repository_name   = "${var.project_name}-inference-patched"
  aws_region        = var.aws_region
  aws_account_id    = data.aws_caller_identity.current.account_id
  source_registry   = local.dlc_ecr_registry
  source_repository = var.dlc_source_repository
  source_tag        = var.patched_image_source_tag
  kms_key_arn       = data.terraform_remote_state.training.outputs.kms_key_arn

  # SBOM upload - only populated when the training root created the bucket.
  # The module handles the empty-string case internally (no SBOM step, no
  # s3:PutObject statement in the CodeBuild IAM policy).
  sbom_bucket     = coalesce(data.terraform_remote_state.training.outputs.sbom_bucket, "")
  sbom_bucket_arn = coalesce(data.terraform_remote_state.training.outputs.sbom_bucket_arn, "")

  permissions_boundary_arn = var.permissions_boundary_arn
}

################################################################################
# Auto-Deployment
################################################################################

module "auto_deployment" {
  source = "../modules/terraform-aws-auto-deployment"

  project_name                     = var.project_name
  model_package_group_name         = data.terraform_remote_state.training.outputs.model_package_group_name
  endpoint_name                    = local.endpoint_name
  endpoint_instance_type           = var.endpoint_instance_type
  data_capture_sampling_percentage = var.data_capture_sampling_percentage
  data_capture_input               = var.data_capture_input
  sagemaker_role_arn               = data.terraform_remote_state.training.outputs.sagemaker_execution_role_arn
  monitoring_bucket                = local.training_outputs.monitoring_bucket
  model_artifacts_bucket           = local.training_outputs.model_artifacts
  drift_baseline_key               = local.drift_baseline_key
  artifacts_kms_key_arn            = local.training_outputs.kms_key_arn
  sns_topic_arn                    = module.sns_alerts.sns_topic_arn
  serving_image_uri                = module.patched_inference_image.image_uri
  log_retention_days               = var.log_retention_days
  log_kms_key_arn                  = local.training_outputs.kms_key_arn
  env_kms_key_arn                  = local.training_outputs.kms_key_arn
  volume_kms_key_arn               = local.training_outputs.kms_key_arn

  # Mirror the serverless flags into the Lambda env so the auto-deployer
  # creates endpoint configs matching the initial Terraform deploy.
  use_serverless_inference   = var.use_serverless_inference
  serverless_memory_size_mb  = var.serverless_memory_size_mb
  serverless_max_concurrency = var.serverless_max_concurrency

  permissions_boundary_arn = var.permissions_boundary_arn
}

################################################################################
# Frontend
################################################################################

resource "random_id" "frontend_suffix" {
  byte_length = 4
}

module "frontend_hosting" {
  source = "../modules/terraform-aws-frontend-hosting"

  bucket_name        = "${var.project_name}-frontend-${random_id.frontend_suffix.hex}"
  html_template_path = "${path.module}/static-frontend/index.html.tpl"
  template_vars = {
    api_url = module.api_gateway.invoke_url
    api_key = module.api_gateway.api_key_value
  }
}
