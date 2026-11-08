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
  enable_network_isolation             = var.endpoint_network_isolation

  # Serverless inference opt-in. When true, the module swaps the production
  # variant to serverless (scales to zero) and skips DataCaptureConfig and
  # Application Auto Scaling. See the module README for tradeoffs.
  use_serverless_inference   = var.use_serverless_inference
  serverless_memory_size_mb  = var.serverless_memory_size_mb
  serverless_max_concurrency = var.serverless_max_concurrency

  # Blue/green traffic shifting: CANARY by default (canary_size_percent of
  # the new fleet first, then the rest), with auto-rollback on the error and
  # latency alarms. The Lambdas below send the same policy on every update.
  traffic_routing_type        = var.traffic_routing_type
  canary_size_percent         = var.canary_size_percent
  linear_step_percent         = var.linear_step_percent
  traffic_shift_wait_interval = var.traffic_shift_wait_interval
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
  execution_role_arn    = each.key == "endpoint_refresher" ? module.endpoint_refresher_role.role_arn : module.inference_lambda_role.role_arn
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
  # The training stack's key policy lets CloudWatch alarms use this CMK.
  kms_master_key_id = local.training_outputs.kms_key_arn

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
# callers but is visible in the frontend; set api_authorization_type to
# COGNITO_USER_POOLS (user pool in cognito.tf) or AWS_IAM to authenticate users.
module "api_gateway" {
  source = "../modules/terraform-aws-api-gateway"

  api_name            = "${var.project_name}-inference-api"
  stage_name          = var.api_stage_name
  lambda_function_arn = module.inference_lambda["inference_api"].function_arn
  cors_allowed_origin = local.frontend_origin

  authorization_type     = var.api_authorization_type
  cognito_user_pool_arns = local.api_cognito_user_pool_arns
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

locals {
  # A system-defined inference profile id is a model id with a geography prefix
  # (us.amazon.nova-pro-v1:0 routes amazon.nova-pro-v1:0).
  bedrock_id_parts              = split(".", var.bedrock_model_id)
  bedrock_uses_profile          = length(local.bedrock_id_parts) > 2
  bedrock_foundation_model      = local.bedrock_uses_profile ? join(".", slice(local.bedrock_id_parts, 1, length(local.bedrock_id_parts))) : var.bedrock_model_id
  bedrock_inference_profile_arn = "arn:aws:bedrock:${var.aws_region}:${data.aws_caller_identity.current.account_id}:inference-profile/${var.bedrock_model_id}"

  # InvokeModel on the configured model only. Through a cross-Region profile
  # Bedrock authorizes the profile in this Region and the foundation model in
  # every Region the profile routes to; the condition admits the foundation
  # model only when the call comes through that profile.
  bedrock_invoke_statements = concat(
    [for statement in [
      {
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = local.bedrock_inference_profile_arn
      },
      {
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = "arn:aws:bedrock:*::foundation-model/${local.bedrock_foundation_model}"
        Condition = {
          StringEquals = { "bedrock:InferenceProfileArn" = local.bedrock_inference_profile_arn }
        }
      },
    ] : statement if local.bedrock_uses_profile],
    [for statement in [
      {
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = "arn:aws:bedrock:${var.aws_region}::foundation-model/${var.bedrock_model_id}"
      },
    ] : statement if !local.bedrock_uses_profile],
  )

  # Every endpoint config and model the endpoint can run (Terraform,
  # auto-deploy and refresh ones) is named from the project name; the
  # Terraform config keeps its first 32 characters.
  refresh_read_prefix = substr(var.project_name, 0, 32)
  refresh_name_prefix = substr(local.endpoint_name, 0, 40)
}

# The public inference API function. It reads and writes request records,
# calls the endpoint and, when enabled, Amazon Bedrock and Amazon A2I. It cannot
# change models, endpoint configs or endpoints, and cannot pass a role.
module "inference_lambda_role" {
  source = "../modules/terraform-aws-iam"

  role_name                = "${var.project_name}-lambda-execution-role"
  description              = "Execution role for the ${var.project_name} inference API Lambda function"
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

  inline_policies = {
    lambda_permissions = jsonencode({
      Version = "2012-10-17"
      Statement = concat([
        {
          # Writes only to this function's own log group, which the Lambda
          # module creates.
          Effect   = "Allow"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.project_name}-inference_api:*"
        },
        {
          # ListBucket turns a missing result into a 404 instead of a 403 for
          # GET /results/{id}.
          Effect   = "Allow"
          Action   = ["s3:ListBucket"]
          Resource = "arn:aws:s3:::${local.training_outputs.inference_bucket}"
        },
        {
          # Uploaded images and prediction records (lambda/inference_handler.py).
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:PutObject"]
          Resource = "arn:aws:s3:::${local.training_outputs.inference_bucket}/predictions/*"
        },
        {
          # SSE-KMS on the inference bucket, and the CMK that encrypts the
          # Bedrock guardrail.
          Effect   = "Allow"
          Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
          Resource = [data.terraform_remote_state.training.outputs.kms_key_arn]
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
          # PutMetricData requires no resource; the namespace condition scopes it.
          Effect   = "Allow"
          Action   = ["cloudwatch:PutMetricData"]
          Resource = "*"
          Condition = {
            StringLike = { "cloudwatch:namespace" = "${var.project_name}/*" }
          }
        },
        # X-Ray tracing - required when the Lambda module sets
        # tracing_config.mode = "Active". Without this the function starts
        # up but fails to publish trace segments.
        {
          # X-Ray trace writes support only "*".
          Effect = "Allow"
          Action = [
            "xray:PutTraceSegments",
            "xray:PutTelemetryRecords",
          ]
          Resource = "*"
        },
        ], [for statement in concat(local.bedrock_invoke_statements, [
          {
            # InvokeModel with a guardrail needs ApplyGuardrail on it.
            Effect   = "Allow"
            Action   = ["bedrock:ApplyGuardrail"]
            Resource = aws_bedrock_guardrail.hybrid[*].guardrail_arn
          },
        ]) : statement if var.enable_bedrock_hybrid_inference], var.enable_human_review ? [
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

# The weekly endpoint refresher (lambda/endpoint_refresher.py): clones the
# running endpoint config, copies its models onto the newest patched image,
# rolls the endpoint and deletes what earlier runs left. EventBridge invokes
# it; nothing public does.
module "endpoint_refresher_role" {
  source = "../modules/terraform-aws-iam"

  role_name                = "${var.project_name}-endpoint-refresher-role"
  description              = "Execution role for the ${var.project_name} weekly endpoint refresher Lambda function"
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

  inline_policies = {
    endpoint_refresh = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          # Writes only to this function's own log group, which the Lambda
          # module creates.
          Effect   = "Allow"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.project_name}-endpoint_refresher:*"
        },
        {
          Effect   = "Allow"
          Action   = ["sagemaker:DescribeEndpoint"]
          Resource = "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:endpoint/${local.endpoint_name}"
        },
        {
          # UpdateEndpoint authorizes against the endpoint and the config it
          # moves to, which is always a refresh config.
          Effect = "Allow"
          Action = ["sagemaker:UpdateEndpoint"]
          Resource = [
            "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:endpoint/${local.endpoint_name}",
            "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:endpoint-config/${local.refresh_name_prefix}-refresh-*",
          ]
        },
        {
          # The config the endpoint runs, whichever created it.
          Effect   = "Allow"
          Action   = ["sagemaker:DescribeEndpointConfig"]
          Resource = "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:endpoint-config/${local.refresh_read_prefix}*"
        },
        {
          # Only the refresh configs it creates (refresh_prefix in the handler).
          Effect   = "Allow"
          Action   = ["sagemaker:CreateEndpointConfig", "sagemaker:DeleteEndpointConfig"]
          Resource = "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:endpoint-config/${local.refresh_name_prefix}-refresh-*"
        },
        {
          # The models the running config names, whichever created them.
          Effect   = "Allow"
          Action   = ["sagemaker:DescribeModel"]
          Resource = "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:model/${local.refresh_read_prefix}*"
        },
        {
          # Only the image copies it creates (model_prefix in the handler).
          Effect   = "Allow"
          Action   = ["sagemaker:CreateModel", "sagemaker:DeleteModel"]
          Resource = "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:model/${local.refresh_name_prefix}-image-*"
        },
        {
          # ListEndpointConfigs and ListModels support only "*".
          Effect   = "Allow"
          Action   = ["sagemaker:ListEndpointConfigs", "sagemaker:ListModels"]
          Resource = "*"
        },
        {
          # A model copy keeps the execution role of the model it copies, the
          # one SageMaker role every model in this sample uses.
          Effect   = "Allow"
          Action   = ["iam:PassRole"]
          Resource = data.terraform_remote_state.training.outputs.sagemaker_execution_role_arn
          Condition = {
            StringEquals = {
              "iam:PassedToService" = "sagemaker.amazonaws.com"
            }
          }
        },
        {
          Effect   = "Allow"
          Action   = ["ecr:DescribeImages"]
          Resource = [module.patched_inference_image.repository_arn]
        },
        {
          # DescribeKey: CreateEndpointConfig checks the caller's access to the
          # KmsKeyId the cloned config keeps; it is a direct call, so it cannot
          # carry the GrantIsForAWSResource condition that scopes CreateGrant.
          Effect   = "Allow"
          Action   = ["kms:DescribeKey"]
          Resource = [data.terraform_remote_state.training.outputs.kms_key_arn]
        },
        {
          # SageMaker needs a grant from the caller of UpdateEndpoint to attach
          # the CMK-encrypted ML storage volume.
          Effect   = "Allow"
          Action   = ["kms:CreateGrant"]
          Resource = [data.terraform_remote_state.training.outputs.kms_key_arn]
          Condition = {
            Bool = { "kms:GrantIsForAWSResource" = "true" }
          }
        },
        {
          # The SageMaker deployment guardrails guide asks for
          # cloudwatch:DescribeAlarms on the auto-rollback alarms that the
          # refresher's DeploymentConfig names.
          Effect   = "Allow"
          Action   = ["cloudwatch:DescribeAlarms"]
          Resource = module.sagemaker_endpoint.rollback_alarm_arns
        },
        {
          # X-Ray trace writes support only "*".
          Effect = "Allow"
          Action = [
            "xray:PutTraceSegments",
            "xray:PutTelemetryRecords",
          ]
          Resource = "*"
        },
      ]
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

# The public AWS DLC (`tensorflow-inference:2.20-cpu-py312-amzn2023-sagemaker`)
# accumulates OS-level CVEs between AWS-published patch releases. This module
# stands up a private, immutable ECR repo, a CodeBuild project that layers the
# OS package upgrade (dnf or apt) + `pip --upgrade` on top of the DLC, and a
# weekly rebuild. The Terraform-managed model and the auto-deploy Lambda run
# the newest build pinned by digest, and the weekly endpoint refresher repins
# the live endpoint to the newest build, so no apply is needed for patches.

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

  # Each build deletes an image with a scan finding at or above this severity
  # before the endpoint can be repinned to it.
  scan_block_severity = var.patched_image_scan_block_severity
  log_retention_days  = var.log_retention_days
  alarm_actions       = [module.sns_alerts.sns_topic_arn]

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
  endpoint_initial_instance_count  = var.endpoint_initial_instance_count
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

  # Approval-driven rollouts use the endpoint's canary policy and rollback
  # alarms, not only the first deployment.
  deployment_config_json = module.sagemaker_endpoint.deployment_config_json
  rollback_alarm_arns    = module.sagemaker_endpoint.rollback_alarm_arns

  enable_network_isolation = var.endpoint_network_isolation

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
  force_destroy      = var.force_destroy_buckets
  kms_key_arn        = local.training_outputs.kms_key_arn
  access_log_bucket  = try(data.terraform_remote_state.training.outputs.access_log_bucket, null)
  html_template_path = "${path.module}/static-frontend/index.html.tpl"
  asset_templates = {
    "app.js"  = "${path.module}/static-frontend/app.js.tpl"
    "app.css" = "${path.module}/static-frontend/app.css"
  }
  # The Content-Security-Policy lets the page call the predict URL only. It is
  # built from the API id, not the stage's invoke_url: the API's CORS origin
  # is this distribution, so the stage cannot feed back into it.
  connect_src = ["https://${module.api_gateway.api_id}.execute-api.${var.aws_region}.amazonaws.com/${var.api_stage_name}/predict"]
  template_vars = {
    api_url = module.api_gateway.invoke_url
    # The key is visible to anyone who loads the page, so it is only rendered
    # in API key mode; with Cognito the page gets no key.
    api_key = var.api_authorization_type == "COGNITO_USER_POOLS" ? "" : module.api_gateway.api_key_value
  }
}
