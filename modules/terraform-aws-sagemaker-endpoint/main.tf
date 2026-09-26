# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

locals {
  # Serve the approved package's artefact on var.serving_image_uri when one is
  # given (the patched image, pinned by digest). The auto-deploy Lambda builds
  # its models the same way, so the Terraform-created model and every
  # auto-deployed model run on one image.
  use_serving_image = var.serving_image_uri != ""
  package_container = try(data.awscc_sagemaker_model_package.approved[0].inference_specification.containers[0], null)

  # The model name changes whenever its inputs change so create_before_destroy
  # on the endpoint config can stand up the replacement before the old one goes.
  model_name = "${substr(var.project_name, 0, 45)}-model-${substr(sha1("${var.model_package_arn}|${var.serving_image_uri}"), 0, 8)}"
}

# Reads the approved package through the Cloud Control API (no shell-out, no
# ambient CLI credentials). Only used when the image is overridden; otherwise
# the model references the package directly. The count must not depend on
# serving_image_uri: the patched image digest is unknown until the first apply.
data "awscc_sagemaker_model_package" "approved" {
  count = var.model_package_arn != "" ? 1 : 0

  id = var.model_package_arn
}

resource "aws_sagemaker_model" "this" {
  name               = local.model_name
  execution_role_arn = var.execution_role_arn

  primary_container {
    model_package_name = local.use_serving_image ? null : var.model_package_arn
    image              = local.use_serving_image ? var.serving_image_uri : null
    model_data_url     = local.use_serving_image ? try(local.package_container.model_data_url, null) : null
    environment        = local.use_serving_image ? try(local.package_container.environment, null) : null
  }

  tags = merge(var.tags, {
    Name = local.model_name
  })

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = can(regex("^arn:aws[a-z-]*:sagemaker:[a-z0-9-]+:[0-9]{12}:model-package/[^/]+/[0-9]+$", var.model_package_arn))
      error_message = "model_package_arn must be the versioned ARN of an Approved package in ${var.model_package_group_name}. The baseline (CI/CD baseline-model stage or python stack-cicd/scripts/create_baseline_model.py) is registered as PendingManualApproval: approve it with aws sagemaker update-model-package --model-package-arn <arn> --model-approval-status Approved, then pass that ARN."
    }
  }
}

################################################################################
# SageMaker Endpoint Configuration
################################################################################

# SageMaker Endpoint Configuration - supports both real-time (instance-based)
# and serverless production variants. Serverless is gated behind
# var.use_serverless_inference because it has several architectural
# constraints not present in real-time mode (see module README):
#   - no DataCaptureConfig support, so drift detection must be fed from the
#     inference handler itself
#   - no auto-scaling (scales via max_concurrency on the variant)
#   - 1-5 second cold start after idle periods
# Real-time remains the default so the project's compliance / monitoring
# story stays intact; callers opting into serverless should understand the
# tradeoffs.
# kics false positive "Endpoint Configuration Encryption Disabled": kms_key_arn
# is set to the project CMK in real-time mode (the default); serverless variants
# attach no ML storage volume and reject the argument, so it must be null there.
# kics-scan ignore-block
resource "aws_sagemaker_endpoint_configuration" "this" {
  # name_prefix + create_before_destroy: a model or capture change creates the
  # new config before the old one is deleted, instead of failing on a name clash.
  name_prefix = "${substr(var.project_name, 0, 32)}-epc-"

  # Encrypt the ML storage volume on real-time variants with the project CMK.
  # Serverless variants attach no volume and reject this argument, so only set
  # it in real-time mode.
  kms_key_arn = var.use_serverless_inference ? null : var.volume_kms_key_arn

  production_variants {
    variant_name = "AllTraffic"
    model_name   = aws_sagemaker_model.this.name

    # Initial traffic weight for this variant. With a single variant it always
    # gets 100% of traffic; the arg makes the config weight-aware so a canary
    # variant can be added and traffic split via
    # update_endpoint_weights_and_capacities (Part 3 weighted routing).
    initial_variant_weight = var.initial_variant_weight

    # Real-time mode - default. Provisioned instance(s) + data capture.
    initial_instance_count = var.use_serverless_inference ? null : var.initial_instance_count
    instance_type          = var.use_serverless_inference ? null : var.instance_type

    # Serverless mode - provisioned per request, scales to zero when idle.
    dynamic "serverless_config" {
      for_each = var.use_serverless_inference ? [1] : []
      content {
        memory_size_in_mb = var.serverless_memory_size_mb
        max_concurrency   = var.serverless_max_concurrency
      }
    }
  }

  # Shadow testing (Part 3): replicate production traffic to a candidate model
  # without returning its predictions to callers, logging them for comparison.
  # Opt-in and real-time only (shadow needs an instance-based variant). Provide
  # var.shadow_model_name to enable. Docs:
  # https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sagemaker_endpoint_configuration#shadow_production_variants
  dynamic "shadow_production_variants" {
    for_each = (!var.use_serverless_inference && var.shadow_model_name != null) ? [1] : []
    content {
      variant_name           = "Shadow"
      model_name             = var.shadow_model_name
      initial_instance_count = var.initial_instance_count
      instance_type          = var.instance_type
      initial_variant_weight = 1
    }
  }

  # Data Capture is only supported on real-time endpoints. Drift detection
  # jobs read the S3 data-capture prefix; if we enabled DataCaptureConfig
  # on a serverless variant SageMaker would reject the CreateEndpointConfig
  # call. For serverless deployments, capture predictions from inside the
  # inference Lambda instead (see modules/terraform-aws-auto-deployment).
  dynamic "data_capture_config" {
    for_each = var.use_serverless_inference ? [] : [1]
    content {
      enable_capture              = true
      initial_sampling_percentage = var.data_capture_sampling_percentage
      destination_s3_uri          = "s3://${var.monitoring_bucket}/data-capture"

      # Output only by default: the drift and fairness jobs read prediction
      # scores, and capturing Input would store every uploaded image.
      dynamic "capture_options" {
        for_each = var.data_capture_input ? ["Input", "Output"] : ["Output"]
        content {
          capture_mode = capture_options.value
        }
      }
    }
  }

  tags = merge(var.tags, {
    Name          = "${var.project_name}-endpoint-config"
    InferenceMode = var.use_serverless_inference ? "Serverless" : "RealTime"
  })

  lifecycle {
    create_before_destroy = true
  }
}

################################################################################
# SageMaker Endpoint
################################################################################

# Blue/green deployment with auto-rollback on the two alarms below.
resource "aws_sagemaker_endpoint" "this" {
  name                 = var.endpoint_name
  endpoint_config_name = aws_sagemaker_endpoint_configuration.this.name

  deployment_config {
    blue_green_update_policy {
      traffic_routing_configuration {
        type                     = "ALL_AT_ONCE"
        wait_interval_in_seconds = var.traffic_shift_wait_interval
      }
      termination_wait_in_seconds          = var.termination_wait_seconds
      maximum_execution_timeout_in_seconds = var.deployment_max_timeout
    }

    auto_rollback_configuration {
      alarms {
        alarm_name = aws_cloudwatch_metric_alarm.endpoint_error_rate.alarm_name
      }
      alarms {
        alarm_name = aws_cloudwatch_metric_alarm.endpoint_latency.alarm_name
      }
    }
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-endpoint"
  })

  lifecycle {
    # endpoint_config_name is updated by the auto-deploy Lambda when a new
    # model is approved - ignore that drift so Terraform doesn't fight it.
    #
    # deployment_config is also ignored: SageMaker applies the blue/green +
    # auto_rollback policy at create/update time but does not return it on
    # Describe, so Terraform reads it back as absent and tries to re-add it on
    # every apply - which forces a full endpoint REPLACEMENT (and then fails
    # because monitoring schedules are still attached). Ignoring it keeps
    # re-applies in-place and non-destructive.
    ignore_changes = [endpoint_config_name, deployment_config]
  }
}

################################################################################
# CloudWatch Alarms
################################################################################

# Rollback alarm on server-side failures. 4XX errors are caller mistakes and
# say nothing about the new model; Invocation5XXErrors and
# InvocationModelErrors do. InvocationModelErrors already counts model 5XX
# responses, so the alarm takes the larger of the two sums rather than adding
# them.
resource "aws_cloudwatch_metric_alarm" "endpoint_error_rate" {
  alarm_name          = "${var.project_name}-endpoint-error-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = var.error_count_threshold
  alarm_description   = "Triggers rollback if Invocation5XXErrors or InvocationModelErrors exceed ${var.error_count_threshold} per minute"
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "errors"
    expression  = "MAX([FILL(m5xx, 0), FILL(model_errors, 0)])"
    label       = "Server and model errors"
    return_data = true
  }

  metric_query {
    id = "m5xx"
    metric {
      metric_name = "Invocation5XXErrors"
      namespace   = "AWS/SageMaker"
      period      = 60
      stat        = "Sum"
      dimensions = {
        EndpointName = var.endpoint_name
        VariantName  = "AllTraffic"
      }
    }
  }

  metric_query {
    id = "model_errors"
    metric {
      metric_name = "InvocationModelErrors"
      namespace   = "AWS/SageMaker"
      period      = 60
      stat        = "Sum"
      dimensions = {
        EndpointName = var.endpoint_name
        VariantName  = "AllTraffic"
      }
    }
  }

  tags = merge(var.tags, {
    Name    = "${var.project_name}-endpoint-error-rate"
    Purpose = "AutoRollback"
  })
}

# Alarm for endpoint latency
resource "aws_cloudwatch_metric_alarm" "endpoint_latency" {
  alarm_name          = "${var.project_name}-endpoint-latency"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ModelLatency"
  namespace           = "AWS/SageMaker"
  period              = 60
  statistic           = "Average"
  threshold           = var.latency_threshold * 1000 # ModelLatency is in microseconds
  alarm_description   = "Triggers rollback if endpoint latency exceeds ${var.latency_threshold}ms"
  treat_missing_data  = "notBreaching"

  dimensions = {
    EndpointName = var.endpoint_name
    VariantName  = "AllTraffic"
  }

  tags = merge(var.tags, {
    Name    = "${var.project_name}-endpoint-latency"
    Purpose = "AutoRollback"
  })
}

################################################################################
# Auto-Scaling
################################################################################

# Auto-scaling only applies to real-time (instance-based) endpoints.
# Serverless endpoints scale via `max_concurrency` on the production variant
# and do not participate in Application Auto Scaling. Guarding with `count`
# prevents Terraform from trying to register a scalable target that
# SageMaker would reject for a serverless variant.

# Auto-Scaling Target for SageMaker Endpoint
resource "aws_appautoscaling_target" "this" {
  count = var.use_serverless_inference ? 0 : 1

  max_capacity       = var.max_capacity
  min_capacity       = var.min_capacity
  resource_id        = "endpoint/${var.endpoint_name}/variant/AllTraffic"
  scalable_dimension = "sagemaker:variant:DesiredInstanceCount"
  service_namespace  = "sagemaker"

  depends_on = [aws_sagemaker_endpoint.this]

  tags = merge(var.tags, {
    Name = "${var.project_name}-autoscaling-target"
  })
}

# Auto-Scaling Policy with Target Tracking
# Uses the high-resolution ConcurrentRequestsPerModel metric (10-second
# granularity) for sub-minute scale-out detection instead of the classic
# 1-minute InvocationsPerInstance metric. See:
# https://docs.aws.amazon.com/sagemaker/latest/dg/endpoint-auto-scaling-add-code-define.html
resource "aws_appautoscaling_policy" "this" {
  count = var.use_serverless_inference ? 0 : 1

  name               = "${var.project_name}-scaling-policy"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "SageMakerVariantConcurrentRequestsPerModelHighResolution"
    }
    target_value       = var.target_concurrent_requests_per_model
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}
