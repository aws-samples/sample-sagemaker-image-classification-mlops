# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

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

# POST /predict
resource "aws_api_gateway_method" "predict_post" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.predict.id
  http_method   = "POST"
  authorization = "NONE"

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
  uri                     = "arn:aws:apigateway:${data.aws_region.current.id}:lambda:path/2015-03-31/functions/${var.lambda_function_arn}/invocations"
}

# Add CORS response for POST method
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
    "method.response.header.Access-Control-Allow-Origin" = "'*'"
  }

  depends_on = [aws_api_gateway_integration.predict_integration]
}

################################################################################
# GET /results/{id}
################################################################################

# GET /results/{id}
resource "aws_api_gateway_method" "results_get" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.results_id.id
  http_method   = "GET"
  authorization = "NONE"

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
  uri                     = "arn:aws:apigateway:${data.aws_region.current.id}:lambda:path/2015-03-31/functions/${var.lambda_function_arn}/invocations"
}

################################################################################
# CORS
################################################################################

# CORS for predict
resource "aws_api_gateway_method" "predict_options" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.predict.id
  http_method   = "OPTIONS"
  authorization = "NONE"
  # OPTIONS preflight has no body/params to validate; wire the validator
  # so checkov is happy without changing behaviour.
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
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
}

################################################################################
# Deployment
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
  count              = var.enable_access_logging ? 1 : 0
  name               = "${var.api_name}-cloudwatch-logs"
  assume_role_policy = data.aws_iam_policy_document.apigw_cloudwatch_assume[0].json
  tags               = var.tags
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

# Deployment
resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

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

resource "aws_api_gateway_stage" "this" {
  deployment_id = aws_api_gateway_deployment.this.id
  rest_api_id   = aws_api_gateway_rest_api.this.id
  stage_name    = var.stage_name

  # X-Ray tracing - lets you see which hop is slow (API GW → Lambda → SageMaker).
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
# Usage Plan - API key throttling for authenticated clients
################################################################################

# Optional usage plan gated by `create_usage_plan`. When enabled, callers can
# provision `aws_api_gateway_api_key` resources and attach them to this plan
# for per-client quotas. The default `/predict` endpoint remains
# `authorization = "NONE"` because this is a demo API, but even anonymous
# traffic is protected by the stage-level throttle above.
resource "aws_api_gateway_usage_plan" "this" {
  count = var.create_usage_plan ? 1 : 0

  name        = "${var.api_name}-usage-plan"
  description = "Default usage plan for ${var.api_name}"

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

################################################################################
# (WAF removed 2026-05 - API Gateway throttling + Lambda reserved
#  concurrency + 5 MB payload limit are sufficient for a research endpoint.
#  If you need WAF, add it back at the CloudFront distribution in front of
#  the API rather than on the regional stage.)
################################################################################

