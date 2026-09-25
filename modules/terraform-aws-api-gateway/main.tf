# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

locals {
  use_cognito = var.authorization_type == "COGNITO_USER_POOLS"

  # An API key only works through a usage plan attached to the stage.
  create_usage_plan = var.create_usage_plan || var.require_api_key

  lambda_invoke_uri = "arn:${data.aws_partition.current.partition}:apigateway:${data.aws_region.current.region}:lambda:path/2015-03-31/functions/${var.lambda_function_arn}/invocations"

  cors_origin_header = "'${var.cors_allowed_origin}'"
}

resource "aws_api_gateway_rest_api" "this" {
  name = var.api_name

  binary_media_types = ["image/jpeg", "image/png", "application/octet-stream"]

  lifecycle {
    create_before_destroy = true
  }

  tags = var.tags
}

################################################################################
# API Resources
################################################################################

resource "aws_api_gateway_resource" "predict" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "predict"
}

resource "aws_api_gateway_resource" "results" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "results"
}

resource "aws_api_gateway_resource" "results_id" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.results.id
  path_part   = "{id}"
}

################################################################################
# POST /predict
################################################################################

# Request validator - rejects malformed bodies before they reach Lambda.
# Saves Lambda invocation cost and blocks obvious garbage payloads.
resource "aws_api_gateway_request_validator" "body" {
  name                        = "${var.api_name}-validate-body"
  rest_api_id                 = aws_api_gateway_rest_api.this.id
  validate_request_body       = true
  validate_request_parameters = true
}

# JSON schema for /predict POST bodies. Accepts either a bare base64
# string under `image` or an object with extra metadata fields.
resource "aws_api_gateway_model" "predict_request" {
  rest_api_id  = aws_api_gateway_rest_api.this.id
  name         = "PredictRequest"
  description  = "Schema for POST /predict request body"
  content_type = "application/json"

  schema = jsonencode({
    "$schema" = "http://json-schema.org/draft-04/schema#"
    title     = "PredictRequest"
    type      = "object"
    required  = ["image"]
    properties = {
      image = {
        type      = "string"
        minLength = 1
        # Arbitrary upper bound at the schema layer; the Lambda handler
        # enforces MAX_IMAGE_BYTES precisely (413 if exceeded).
        maxLength = 20000000
      }
    }
    additionalProperties = true
  })
}

resource "aws_api_gateway_authorizer" "cognito" {
  count = local.use_cognito ? 1 : 0

  name          = "${var.api_name}-cognito"
  rest_api_id   = aws_api_gateway_rest_api.this.id
  type          = "COGNITO_USER_POOLS"
  provider_arns = var.cognito_user_pool_arns
}

resource "aws_api_gateway_method" "predict_post" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.predict.id
  # KICS: API key, usage plan and WAF front /predict; authorization_type can be AWS_IAM or COGNITO_USER_POOLS (SECURITY.md)
  # kics-scan ignore-line
  http_method      = "POST"
  authorization    = var.authorization_type
  authorizer_id    = local.use_cognito ? aws_api_gateway_authorizer.cognito[0].id : null
  api_key_required = var.require_api_key

  request_validator_id = aws_api_gateway_request_validator.body.id
  request_models = {
    "application/json" = aws_api_gateway_model.predict_request.name
  }
}

resource "aws_api_gateway_integration" "predict_integration" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.predict.id
  http_method = aws_api_gateway_method.predict_post.http_method

  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}

resource "aws_api_gateway_method_response" "predict_post_response" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.predict.id
  http_method = aws_api_gateway_method.predict_post.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = true
  }
}

resource "aws_api_gateway_integration_response" "predict_post_integration_response" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.predict.id
  http_method = aws_api_gateway_method.predict_post.http_method
  status_code = aws_api_gateway_method_response.predict_post_response.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = local.cors_origin_header
  }

  depends_on = [aws_api_gateway_integration.predict_integration]
}

################################################################################
# GET /results/{id}
################################################################################

resource "aws_api_gateway_method" "results_get" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.results_id.id
  # KICS: API key, usage plan and WAF front /results; authorization_type can be AWS_IAM or COGNITO_USER_POOLS (SECURITY.md)
  # kics-scan ignore-line
  http_method      = "GET"
  authorization    = var.authorization_type
  authorizer_id    = local.use_cognito ? aws_api_gateway_authorizer.cognito[0].id : null
  api_key_required = var.require_api_key

  # Validate the `id` path parameter is present (API GW rejects the
  # request before invoking Lambda if missing).
  request_validator_id = aws_api_gateway_request_validator.body.id
  request_parameters = {
    "method.request.path.id" = true
  }
}

resource "aws_api_gateway_integration" "results_integration" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.results_id.id
  http_method = aws_api_gateway_method.results_get.http_method

  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.lambda_invoke_uri
}

################################################################################
# CORS
################################################################################

# Preflight stays unauthenticated: browsers never send credentials or API keys
# on OPTIONS.
resource "aws_api_gateway_method" "predict_options" {
  rest_api_id          = aws_api_gateway_rest_api.this.id
  resource_id          = aws_api_gateway_resource.predict.id
  http_method          = "OPTIONS"
  authorization        = "NONE"
  request_validator_id = aws_api_gateway_request_validator.body.id
}

resource "aws_api_gateway_integration" "predict_options_integration" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.predict.id
  http_method = aws_api_gateway_method.predict_options.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "predict_options_response" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.predict.id
  http_method = aws_api_gateway_method.predict_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "predict_options_integration_response" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.predict.id
  http_method = aws_api_gateway_method.predict_options.http_method
  status_code = aws_api_gateway_method_response.predict_options_response.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,HEAD,OPTIONS,POST'"
    "method.response.header.Access-Control-Allow-Origin"  = local.cors_origin_header
  }
}

# API Gateway answers a missing key (403) or a throttle (429) itself, without
# the Lambda. Add the CORS header so the browser surfaces the real status.
resource "aws_api_gateway_gateway_response" "cors" {
  for_each = toset(["DEFAULT_4XX", "DEFAULT_5XX"])

  rest_api_id   = aws_api_gateway_rest_api.this.id
  response_type = each.value

  response_parameters = {
    "gatewayresponse.header.Access-Control-Allow-Origin" = local.cors_origin_header
  }
}

################################################################################
# CloudWatch Logs IAM - API Gateway account settings
################################################################################

# API Gateway needs an account-level CloudWatch role before access logging
# works. This is idempotent and account-scoped - AWS only uses the last one
# set on `aws_api_gateway_account`.
data "aws_iam_policy_document" "apigw_cloudwatch_assume" {
  count = var.enable_access_logging ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apigw_cloudwatch" {
  count                = var.enable_access_logging ? 1 : 0
  name                 = "${var.api_name}-cloudwatch-logs"
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy   = data.aws_iam_policy_document.apigw_cloudwatch_assume[0].json
  tags                 = var.tags
}

resource "aws_iam_role_policy_attachment" "apigw_cloudwatch" {
  count      = var.enable_access_logging ? 1 : 0
  role       = aws_iam_role.apigw_cloudwatch[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_api_gateway_account" "this" {
  count               = var.enable_access_logging ? 1 : 0
  cloudwatch_role_arn = aws_iam_role.apigw_cloudwatch[0].arn
}

# Access log destination - one log group per stage. Retention mirrors the
# project log_retention_days knob.
resource "aws_cloudwatch_log_group" "access_logs" {
  count             = var.enable_access_logging ? 1 : 0
  name              = "/aws/apigateway/${var.api_name}/${var.stage_name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.log_kms_key_arn
  tags              = var.tags
}

################################################################################
# Deployment
################################################################################

# KICS: access logs are configured on aws_api_gateway_stage.this, not on the deployment
# kics-scan ignore-line
resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  # A deployment is a snapshot: without this, changing auth or key settings on
  # a method never reaches the live stage.
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_method.predict_post,
      aws_api_gateway_method.results_get,
      aws_api_gateway_method.predict_options,
      aws_api_gateway_integration.predict_integration,
      aws_api_gateway_integration.results_integration,
      aws_api_gateway_integration.predict_options_integration,
      aws_api_gateway_integration_response.predict_options_integration_response,
      aws_api_gateway_gateway_response.cors,
    ]))
  }

  depends_on = [
    aws_api_gateway_integration.predict_integration,
    aws_api_gateway_integration.results_integration,
    aws_api_gateway_integration.predict_options_integration,
    aws_api_gateway_integration_response.predict_post_integration_response
  ]

  lifecycle {
    create_before_destroy = true
  }
}

################################################################################
# Stage - with execution logging, access logging, throttling, X-Ray
################################################################################

# KICS: access and execution logging come from the dynamic access_log_settings block and method_settings (enable_access_logging, default true); the Lambda proxy backend does not use a client certificate
# kics-scan ignore-line
resource "aws_api_gateway_stage" "this" {
  # The web ACL below includes AWSManagedRulesKnownBadInputsRuleSet (Log4j);
  # Checkov does not follow the count-gated aws_wafv2_web_acl_association.
  #checkov:skip=CKV2_AWS_77:Web ACL has the KnownBadInputs AMR; association is count-gated on enable_waf
  deployment_id = aws_api_gateway_deployment.this.id
  rest_api_id   = aws_api_gateway_rest_api.this.id
  stage_name    = var.stage_name

  # X-Ray tracing - shows which hop is slow (API Gateway, Lambda, SageMaker).
  xray_tracing_enabled = var.enable_xray_tracing

  # Access logs - structured JSON that's queryable via CloudWatch Logs Insights.
  dynamic "access_log_settings" {
    for_each = var.enable_access_logging ? [1] : []
    content {
      destination_arn = aws_cloudwatch_log_group.access_logs[0].arn
      # One JSON line per request with the fields auditors typically want.
      format = jsonencode({
        requestId         = "$context.requestId"
        extendedRequestId = "$context.extendedRequestId"
        sourceIp          = "$context.identity.sourceIp"
        userAgent         = "$context.identity.userAgent"
        requestTime       = "$context.requestTime"
        httpMethod        = "$context.httpMethod"
        resourcePath      = "$context.resourcePath"
        status            = "$context.status"
        responseLatency   = "$context.responseLatency"
        errorMessage      = "$context.error.message"
        integrationStatus = "$context.integration.status"
        integrationError  = "$context.integration.error"
      })
    }
  }

  depends_on = [aws_api_gateway_account.this]

  tags = var.tags
}

################################################################################
# Method settings - execution logs + throttling (stage-wide defaults)
################################################################################

# These are stage-wide defaults applied to every method. Per-method overrides
# can be added by callers that need stricter limits on specific endpoints.
resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled        = true
    logging_level          = var.enable_access_logging ? "INFO" : "OFF"
    data_trace_enabled     = false # never log full payloads - base64 images are potential PHI
    throttling_burst_limit = var.throttling_burst_limit
    throttling_rate_limit  = var.throttling_rate_limit
  }
}

################################################################################
# Usage plan and API key
################################################################################

# The key identifies and meters the caller; it is not authentication. It ships
# inside the static frontend, so anyone who loads the page can read it. Use
# authorization_type = "AWS_IAM" or "COGNITO_USER_POOLS" to authenticate users.
resource "aws_api_gateway_usage_plan" "this" {
  count = local.create_usage_plan ? 1 : 0

  name        = "${var.api_name}-usage-plan"
  description = "Per-key throttle and quota for ${var.api_name}"

  api_stages {
    api_id = aws_api_gateway_rest_api.this.id
    stage  = aws_api_gateway_stage.this.stage_name
  }

  throttle_settings {
    burst_limit = var.usage_plan_burst_limit
    rate_limit  = var.usage_plan_rate_limit
  }

  quota_settings {
    limit  = var.usage_plan_quota_limit
    period = var.usage_plan_quota_period
  }

  tags = var.tags
}

resource "aws_api_gateway_api_key" "frontend" {
  count = var.require_api_key ? 1 : 0

  name        = "${var.api_name}-frontend"
  description = "Key the static frontend sends in the x-api-key header"
  enabled     = true

  tags = var.tags
}

resource "aws_api_gateway_usage_plan_key" "frontend" {
  count = var.require_api_key ? 1 : 0

  key_id        = aws_api_gateway_api_key.frontend[0].id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.this[0].id
}

################################################################################
# AWS WAF (regional web ACL on the stage)
################################################################################

resource "aws_wafv2_web_acl" "this" {
  count = var.enable_waf ? 1 : 0

  name        = "${var.api_name}-waf"
  description = "Managed common rules and a per-IP rate limit for ${var.api_name}"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"

        # POST /predict carries a base64 image, far above the rule's 8 KB body
        # limit. Count instead of block; the request model and the Lambda
        # enforce the real size cap.
        rule_action_override {
          name = "SizeRestrictions_BODY"
          action_to_use {
            count {}
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.api_name}-common-rules"
      sampled_requests_enabled   = true
    }
  }

  # Known bad inputs, including the Log4j JNDI lookup patterns.
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.api_name}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "RateLimitPerIP"
    priority = 3

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.api_name}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.api_name}-waf"
    sampled_requests_enabled   = true
  }

  tags = var.tags
}

resource "aws_wafv2_web_acl_association" "this" {
  count = var.enable_waf ? 1 : 0

  resource_arn = aws_api_gateway_stage.this.arn
  web_acl_arn  = aws_wafv2_web_acl.this[0].arn
}

# WAF requires the log group name to start with aws-waf-logs-.
resource "aws_cloudwatch_log_group" "waf" {
  count = var.enable_waf ? 1 : 0

  name              = "aws-waf-logs-${var.api_name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.log_kms_key_arn
  tags              = var.tags
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  count = var.enable_waf ? 1 : 0

  resource_arn            = aws_wafv2_web_acl.this[0].arn
  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]

  # Keep the API key out of the WAF logs.
  redacted_fields {
    single_header {
      name = "x-api-key"
    }
  }
}
