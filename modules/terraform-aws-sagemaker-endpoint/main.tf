# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

data "external" "latest_approved_model" {
  program = ["bash", "-c", <<-EOT
    MODEL_ARN=$(aws sagemaker list-model-packages \
      --model-package-group-name ${var.model_package_group_name} \
      --model-approval-status Approved \
      --sort-by CreationTime \
      --sort-order Descending \
      --max-results 1 \
      --region ${var.aws_region} \
      --query 'ModelPackageSummaryList[0].ModelPackageArn' \
      --output text)

    if [ "$MODEL_ARN" = "None" ] || [ -z "$MODEL_ARN" ]; then
      echo '{"model_package_arn": "", "model_data_url": "", "image_uri": ""}' | jq -c
      exit 0
    fi

    MODEL_DATA=$(aws sagemaker describe-model-package \
      --model-package-name "$MODEL_ARN" \
      --region ${var.aws_region} \
      --query 'InferenceSpecification.Containers[0]' \
      --output json)

    IMAGE_URI=$(echo "$MODEL_DATA" | jq -r '.Image')
    MODEL_URL=$(echo "$MODEL_DATA" | jq -r '.ModelDataUrl')

    jq -n --arg arn "$MODEL_ARN" --arg url "$MODEL_URL" --arg image "$IMAGE_URI" \
      '{model_package_arn: $arn, model_data_url: $url, image_uri: $image}'
  EOT
  ]
}

# SageMaker Model resource
resource "aws_sagemaker_model" "this" {
  name               = "${var.project_name}-model"
  execution_role_arn = var.execution_role_arn

  primary_container {
    # Use image and model data URL from the latest approved model package.
    # coalesce to a syntactically-valid placeholder when no approved model
    # exists yet (cold start) or after the registry is emptied (teardown):
    # the empty string the data source returns is rejected by the provider at
    # plan time, which would otherwise block both the first apply AND destroy.
    # The lifecycle precondition below still fails the APPLY with an actionable
    # message, so a placeholder model is never actually created.
    image          = coalesce(data.external.latest_approved_model.result.image_uri, "placeholder")
    model_data_url = coalesce(data.external.latest_approved_model.result.model_data_url, "s3://placeholder/model.tar.gz")
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-model"
  })

  lifecycle {
    # Fail fast with an actionable message on a cold first deploy instead of
    # the cryptic "PrimaryContainer.Image cannot be empty" CreateModel error
    # you get when no model has been Approved yet. The CI/CD baseline-model
    # stage (or stack-cicd/scripts/create_baseline_model.py) registers an
    # approved model first; run it before applying stack-inference.
    precondition {
      condition     = data.external.latest_approved_model.result.image_uri != ""
      error_message = "No Approved model in package group ${var.model_package_group_name}. Seed one first (CI/CD baseline-model stage or python stack-cicd/scripts/create_baseline_model.py), then re-apply."
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
  name = "${var.project_name}-endpoint-config"

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

      capture_options {
        capture_mode = "Input"
      }
      capture_options {
        capture_mode = "Output"
      }
    }
  }

  tags = merge(var.tags, {
    Name          = "${var.project_name}-endpoint-config"
    InferenceMode = var.use_serverless_inference ? "Serverless" : "RealTime"
  })
}

################################################################################
# SageMaker Endpoint
################################################################################

# SageMaker Endpoint with blue/green deployment and auto-rollback
# Managed by Terraform with deployment_config for safe model updates
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

# Alarm for endpoint error rate (4XX errors)
resource "aws_cloudwatch_metric_alarm" "endpoint_error_rate" {
  alarm_name          = "${var.project_name}-endpoint-error-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ModelInvocation4XXErrors"
  namespace           = "AWS/SageMaker"
  period              = 60
  statistic           = "Average"
  threshold           = var.error_rate_threshold
  alarm_description   = "Triggers rollback if endpoint error rate exceeds ${var.error_rate_threshold}%"
  treat_missing_data  = "notBreaching"

  dimensions = {
    EndpointName = var.endpoint_name
    VariantName  = "AllTraffic"
  }

  tags = merge(var.tags, {
    Name        = "${var.project_name}-endpoint-error-rate"
    Purpose     = "AutoRollback"
    Description = "Monitors endpoint 4XX error rate for automatic rollback"
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
  threshold           = var.latency_threshold
  alarm_description   = "Triggers rollback if endpoint latency exceeds ${var.latency_threshold}ms"
  treat_missing_data  = "notBreaching"

  dimensions = {
    EndpointName = var.endpoint_name
    VariantName  = "AllTraffic"
  }

  tags = merge(var.tags, {
    Name        = "${var.project_name}-endpoint-latency"
    Purpose     = "AutoRollback"
    Description = "Monitors endpoint latency for automatic rollback"
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
    Name        = "${var.project_name}-autoscaling-target"
    Description = "Auto-scaling target for SageMaker endpoint"
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
    target_value = var.target_concurrent_requests_per_model

    # Scale-in cooldown: wait 300 seconds before scaling down again
    scale_in_cooldown = 300

    # Scale-out cooldown: wait 60 seconds before scaling up again
    scale_out_cooldown = 60
  }
}
