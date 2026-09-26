# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

data "terraform_remote_state" "training" {
  backend = "s3"
  config = {
    bucket = var.state_bucket_name
    key    = "training/terraform.tfstate"
    region = var.state_bucket_region != "" ? var.state_bucket_region : var.aws_region
  }
}

# Current account for IAM resource scoping
data "aws_caller_identity" "current" {}

# Image for the scheduled monitoring Processing jobs (drift, fairness). Neither
# script needs TensorFlow - drift is boto3 plus the standard library, and
# fairness adds only Fairlearn on top of the scikit-learn stack - so the small
# scikit-learn DLC is enough.
data "aws_sagemaker_prebuilt_ecr_image" "monitoring_jobs" {
  repository_name = "sagemaker-scikit-learn"
  image_tag       = var.monitoring_job_image_tag
}

# Pillow + numpy layer for the inference Lambda. The zip is not committed: it
# is built at apply time by ops-scripts/build_lambda_layer.sh (pinned versions,
# manylinux wheels for the Lambda runtime) unless it is already present, for
# example from the CI/CD pre_build step. Delete the zip to force a rebuild.
# The runner needs bash, zip and uv or pip.
locals {
  pillow_layer_zip    = "${path.module}/lambda-layers/pillow-numpy-layer.zip"
  pillow_layer_script = "${path.module}/../ops-scripts/build_lambda_layer.sh"
}

resource "terraform_data" "pillow_layer_build" {
  # A change to the build script (pinned versions) replaces the layer.
  triggers_replace = [filesha256(local.pillow_layer_script)]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "[ -f '${local.pillow_layer_zip}' ] || bash '${local.pillow_layer_script}'"
  }
}

resource "aws_lambda_layer_version" "pillow" {
  filename   = local.pillow_layer_zip
  layer_name = "${var.project_name}-pillow-numpy"

  compatible_runtimes = ["python3.13"]
  description         = "Pillow and numpy for Lambda image preprocessing"

  depends_on = [terraform_data.pillow_layer_build]

  lifecycle {
    replace_triggered_by = [terraform_data.pillow_layer_build]
  }
}

locals {
  pillow_layer_arn = aws_lambda_layer_version.pillow.arn

  # DLC registry - auto-constructed from aws_region for commercial regions.
  # The 763104351884 account ID is canonical for AWS commercial regions; for
  # GovCloud (us-gov-*) or China (cn-*) the caller must override
  # var.dlc_ecr_registry with the correct account.
  # See https://github.com/aws/deep-learning-containers/blob/master/available_images.md
  dlc_ecr_registry = var.dlc_ecr_registry != "" ? var.dlc_ecr_registry : "763104351884.dkr.ecr.${var.aws_region}.amazonaws.com"

  # Store remote state outputs for reuse
  training_outputs = {
    pipeline_name         = data.terraform_remote_state.training.outputs.sagemaker_pipeline_name
    inference_bucket      = data.terraform_remote_state.training.outputs.inference_results_bucket
    processed_data_bucket = data.terraform_remote_state.training.outputs.processed_data_bucket
    monitoring_bucket     = data.terraform_remote_state.training.outputs.monitoring_bucket
    model_artifacts       = data.terraform_remote_state.training.outputs.model_artifacts_bucket
    kms_key_arn           = data.terraform_remote_state.training.outputs.kms_key_arn
  }

  endpoint_name = "${var.project_name}-endpoint"

  # Browser origin allowed to call the API: the CloudFront frontend.
  frontend_origin = module.frontend_hosting.cloudfront_url

  # Lambda configurations
  lambda_configs = {
    inference_api = {
      filename    = "lambda/inference_api.zip"
      handler     = "inference_handler.lambda_handler"
      description = "Handle inference API requests and predictions"
      environment = {
        ENDPOINT_NAME    = local.endpoint_name
        INFERENCE_BUCKET = local.training_outputs.inference_bucket
        PROJECT_NAME     = var.project_name
        ALLOWED_ORIGIN   = local.frontend_origin
        # Hard cap on the base64-encoded image size the handler accepts.
        # Guards against bill-inflation attacks (see variables.tf).
        MAX_IMAGE_BYTES = tostring(var.max_image_bytes)
        # Hybrid inference: route low-confidence predictions to Bedrock for
        # reasoning (off by default; see variables.tf).
        ENABLE_BEDROCK_HYBRID        = tostring(var.enable_bedrock_hybrid_inference)
        BEDROCK_MODEL_ID             = var.bedrock_model_id
        BEDROCK_CONFIDENCE_THRESHOLD = tostring(var.bedrock_confidence_threshold)
        # Optional A2I human review of low-confidence cases (empty = disabled).
        FLOW_DEFINITION_ARN = var.enable_human_review ? module.a2i_review[0].flow_definition_arn : ""
        # Bedrock guardrail applied to the hybrid FM reasoning output (empty = none).
        BEDROCK_GUARDRAIL_ID      = var.enable_bedrock_hybrid_inference ? aws_bedrock_guardrail.hybrid[0].guardrail_id : ""
        BEDROCK_GUARDRAIL_VERSION = var.enable_bedrock_hybrid_inference ? aws_bedrock_guardrail.hybrid[0].version : ""
        # Bucket where async Grad-CAM/SHAP explainability artifacts are written
        # (empty = explainability pointer omitted from the response).
        EXPLAIN_BUCKET = var.enable_async_explainability ? local.training_outputs.monitoring_bucket : ""
      }
    }
    endpoint_refresher = {
      filename    = "lambda/endpoint_refresher.zip"
      handler     = "endpoint_refresher.handler"
      description = "Weekly refresher that rolls the endpoint so instances re-pull patched container + host OS"
      environment = {
        ENDPOINT_NAME = local.endpoint_name
        PROJECT_NAME  = var.project_name
      }
    }
  }

  log_groups = {
    api_gateway = {
      name = module.api_gateway.access_log_group_name
    }
  }

  # Native AWS metrics plus the inference handler's custom metrics.
  dashboard_config = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiName", module.api_gateway.api_name],
            [".", "Latency", ".", "."],
            [".", "4XXError", ".", "."],
            [".", "5XXError", ".", "."]
          ]
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          title   = "API Gateway Metrics"
          period  = 300
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", "${var.project_name}-inference_api"],
            [".", "Errors", ".", "."],
            [".", "Invocations", ".", "."]
          ]
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          title   = "Lambda Inference Metrics"
          period  = 300
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/SageMaker", "ModelLatency", "EndpointName", local.endpoint_name, "VariantName", "AllTraffic"],
            [".", "Invocations", ".", ".", ".", "."],
            [".", "InvocationModelErrors", ".", ".", ".", "."],
            [".", "Invocation5XXErrors", ".", ".", ".", "."],
            [".", "Invocation4XXErrors", ".", ".", ".", "."]
          ]
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          title   = "SageMaker Endpoint Metrics"
          period  = 300
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["${var.project_name}/ModelPerformance", "TotalPredictions"],
            [".", "BenignPredictions"],
            [".", "MalignantPredictions"],
            [".", "PredictionConfidence"],
            [".", "PredictionError"]
          ]
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          title   = "Model Predictions Overview"
          period  = 300
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 24
        height = 6
        properties = {
          metrics = [
            ["${var.project_name}/ModelPerformance", "HighConfidencePredictions"],
            [".", "LowConfidencePredictions"],
            [".", "PredictionSuccess"]
          ]
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          title   = "Prediction Confidence Distribution"
          period  = 300
        }
      },
    ]
  })

  alarms_config = {
    api_4xx_errors = {
      alarm_name          = "${var.project_name}-api-4xx-errors"
      comparison_operator = "GreaterThanThreshold"
      evaluation_periods  = "2"
      metric_name         = "4XXError"
      namespace           = "AWS/ApiGateway"
      period              = "300"
      statistic           = "Sum"
      threshold           = "10"
      alarm_description   = "API Gateway 4XX errors"
      dimensions          = { ApiName = module.api_gateway.api_name }
    }

    api_5xx_errors = {
      alarm_name          = "${var.project_name}-api-5xx-errors"
      comparison_operator = "GreaterThanThreshold"
      evaluation_periods  = "1"
      metric_name         = "5XXError"
      namespace           = "AWS/ApiGateway"
      period              = "300"
      statistic           = "Sum"
      threshold           = "5"
      alarm_description   = "API Gateway 5XX errors"
      dimensions          = { ApiName = module.api_gateway.api_name }
    }

    sagemaker_endpoint_errors = {
      alarm_name          = "${var.project_name}-sagemaker-endpoint-errors"
      comparison_operator = "GreaterThanThreshold"
      evaluation_periods  = "2"
      metric_name         = "InvocationModelErrors"
      namespace           = "AWS/SageMaker"
      period              = "300"
      statistic           = "Sum"
      threshold           = "5"
      alarm_description   = "SageMaker endpoint errors"
      dimensions          = { EndpointName = local.endpoint_name }
      treat_missing_data  = "notBreaching"
    }

    sagemaker_endpoint_latency = {
      alarm_name          = "${var.project_name}-sagemaker-endpoint-latency"
      comparison_operator = "GreaterThanThreshold"
      evaluation_periods  = "3"
      metric_name         = "ModelLatency"
      namespace           = "AWS/SageMaker"
      period              = "300"
      statistic           = "Average"
      threshold           = "5000000" # ModelLatency is in microseconds: 5 s
      alarm_description   = "SageMaker endpoint average model latency above 5 s"
      dimensions          = { EndpointName = local.endpoint_name }
      treat_missing_data  = "notBreaching"
    }
  }
}
