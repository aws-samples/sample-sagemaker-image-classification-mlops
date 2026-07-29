# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

locals {
  # Synthetic baseline describing prediction_score ∈ [0, 1] - uploaded by
  # analysis-scripts/ops_fix_monitor_baseline.py. The baseline lets Model
  # Monitor compute drift against output probabilities only and avoids the
  # "Encoding BASE64 is not supported" error on base64 image inputs.
  monitoring_baseline_statistics_s3_uri  = "s3://${local.training_outputs.monitoring_bucket}/monitoring/baselines/output-only/statistics.json"
  monitoring_baseline_constraints_s3_uri = "s3://${local.training_outputs.monitoring_bucket}/monitoring/baselines/output-only/constraints.json"

  # Model Monitor + the drift->retrain loop deploy as one unit: the schedule,
  # drift alarm, and EventBridge retrain rule all depend on the data-quality
  # job, and drift detection is meaningless without the monitor. Gate the whole
  # chain on this single flag so they stay consistent. Always off for serverless
  # (no data capture). `1` when enabled so resources can use it as `count`.
  model_monitor_count = (var.enable_model_monitor && !var.use_serverless_inference) ? 1 : 0
}

# Data Quality Job Definition - monitors OUTPUT predictions only
# The built-in analyzer cannot process base64 image inputs, so we configure it
# to analyze the prediction outputs (benign/malignant probabilities) for drift.
#
# SERVERLESS LIMITATION: Model Monitor reads from the endpoint's data-capture
# S3 prefix, which is only populated by instance-based variants. Serverless
# variants do not support DataCaptureConfig, so we skip Monitor + Clarify
# entirely when use_serverless_inference = true. Callers who need drift
# detection in serverless mode should log predictions from the inference
# handler and run a scheduled custom monitor.
resource "aws_sagemaker_data_quality_job_definition" "medical_image_data_quality" {
  count = local.model_monitor_count

  name     = "${var.project_name}-data-quality-job"
  role_arn = data.terraform_remote_state.training.outputs.sagemaker_execution_role_arn

  depends_on = [module.sagemaker_endpoint]

  data_quality_app_specification {
    image_uri = data.aws_sagemaker_prebuilt_ecr_image.model_monitor.registry_path

    # Configure to analyze outputs only (predictions are numeric JSON, not base64 images)
    environment = {
      dataset_format = jsonencode({
        sagemakerCaptureJson = {
          captureIndexNames = ["endpointOutput"]
        }
      })
      publish_cloudwatch_metrics = "Enabled"
      dataset_source             = "/opt/ml/processing/input/endpoint"
      output_path                = "/opt/ml/processing/output"
      enable_cloudwatch_metrics  = "Enabled"
    }
  }

  # Baseline for drift comparison - covers prediction_score only so the
  # analyzer never attempts to parse the base64-encoded input payload.
  data_quality_baseline_config {
    statistics_resource {
      s3_uri = local.monitoring_baseline_statistics_s3_uri
    }

    constraints_resource {
      s3_uri = local.monitoring_baseline_constraints_s3_uri
    }
  }

  data_quality_job_input {
    endpoint_input {
      endpoint_name             = local.endpoint_name
      local_path                = "/opt/ml/processing/input/endpoint"
      s3_data_distribution_type = "FullyReplicated"
      s3_input_mode             = "File"
    }
  }

  data_quality_job_output_config {
    monitoring_outputs {
      s3_output {
        s3_uri         = "s3://${local.training_outputs.monitoring_bucket}/data-quality-output"
        local_path     = "/opt/ml/processing/output"
        s3_upload_mode = "EndOfJob"
      }
    }
    # Encrypt processing-job outputs with the project CMK.
    kms_key_id = local.training_outputs.kms_key_arn
  }

  job_resources {
    cluster_config {
      instance_count    = 1
      instance_type     = var.model_monitor_config.instance_type
      volume_size_in_gb = var.model_monitor_config.volume_size
      # Encrypt the attached EBS volume with the project CMK.
      volume_kms_key_id = local.training_outputs.kms_key_arn
    }
  }

  # Encrypt inter-container traffic during the monitoring job. Cheap
  # defense-in-depth on top of the VPC-internal network transit.
  network_config {
    enable_inter_container_traffic_encryption = true
    enable_network_isolation                  = false
  }

  stopping_condition {
    max_runtime_in_seconds = var.model_monitor_config.max_runtime
  }

  tags = merge(
    local.common_tags,
    {
      Name    = "${var.project_name}-data-quality-job"
      Purpose = "DataQualityMonitoring"
    }
  )
}

# Monitoring Schedule - runs hourly (skipped in serverless mode, see above)
resource "aws_sagemaker_monitoring_schedule" "medical_image_monitoring" {
  count = local.model_monitor_count

  name = "${var.project_name}-monitoring-schedule"

  monitoring_schedule_config {
    monitoring_job_definition_name = aws_sagemaker_data_quality_job_definition.medical_image_data_quality[0].name
    monitoring_type                = "DataQuality"

    schedule_config {
      schedule_expression = var.model_monitor_config.data_quality_schedule
    }
  }

  depends_on = [aws_sagemaker_data_quality_job_definition.medical_image_data_quality]

  tags = merge(
    local.common_tags,
    {
      Name    = "${var.project_name}-monitoring-schedule"
      Purpose = "DataQualityMonitoring"
    }
  )
}


################################################################################
# SageMaker Clarify - Bias Monitoring
################################################################################

module "sagemaker_clarify" {
  source = "../modules/terraform-aws-sagemaker-clarify"

  # Clarify bias monitoring also reads from endpoint data-capture, which is
  # only available in real-time mode. Disable automatically in serverless.
  enable_bias_monitoring   = var.enable_bias_monitoring && !var.use_serverless_inference
  bias_monitoring_name     = "${var.project_name}-bias-monitor"
  endpoint_name            = local.endpoint_name
  clarify_image_uri        = data.aws_sagemaker_prebuilt_ecr_image.clarify.registry_path
  label_column             = "prediction"
  bias_schedule_expression = var.bias_schedule_expression

  execution_role_arn       = data.terraform_remote_state.training.outputs.sagemaker_execution_role_arn
  results_bucket           = local.training_outputs.monitoring_bucket
  kms_key_arn              = data.terraform_remote_state.training.outputs.kms_key_arn
  processing_instance_type = var.model_monitor_config.instance_type
  job_max_runtime_seconds  = var.model_monitor_config.max_runtime

  baseline_statistics_s3_uri  = local.monitoring_baseline_statistics_s3_uri
  baseline_constraints_s3_uri = local.monitoring_baseline_constraints_s3_uri

  tags = local.common_tags
}

################################################################################
# Closed-loop drift detection -> automated retraining
################################################################################
#
# Model Monitor publishes per-feature drift metrics to CloudWatch when
# emit_metrics is Enabled in the baseline constraints. Per the docs the metric
# is `feature_baseline_drift_<feature>` in the
# `aws/sagemaker/Endpoints/data-metric` namespace with EndpointName +
# ScheduleName dimensions. For an image model only the OUTPUT is monitored, so
# the feature we alarm on is the prediction score.
# Docs: https://docs.aws.amazon.com/sagemaker/latest/dg/model-monitor-interpreting-cloudwatch.html
#
# When drift exceeds the threshold the alarm fires -> EventBridge catches the
# ALARM state change -> starts the training pipeline (Part 3 closed loop). The
# pipeline still registers as PendingManualApproval, so a human approves before
# anything redeploys.

resource "aws_cloudwatch_metric_alarm" "prediction_drift" {
  count = local.model_monitor_count

  alarm_name          = "${var.project_name}-prediction-drift"
  alarm_description   = "Model Monitor baseline drift on the prediction-score distribution exceeded ${var.drift_threshold}. Triggers automated retraining (human approval still required before redeploy)."
  namespace           = "aws/sagemaker/Endpoints/data-metric"
  metric_name         = "feature_baseline_drift_${var.drift_feature_name}"
  statistic           = "Sum"
  period              = var.drift_alarm_period
  evaluation_periods  = 1
  threshold           = var.drift_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    EndpointName = local.endpoint_name
    ScheduleName = aws_sagemaker_monitoring_schedule.medical_image_monitoring[0].name
  }

  alarm_actions = [module.sns_alerts.sns_topic_arn]
  ok_actions    = [module.sns_alerts.sns_topic_arn]

  tags = merge(local.common_tags, { Purpose = "DriftDetection" })
}

# EventBridge rule: when the drift alarm transitions to ALARM, start retraining.
resource "aws_cloudwatch_event_rule" "drift_retrain" {
  count = local.model_monitor_count

  name        = "${var.project_name}-drift-triggers-retraining"
  description = "Start the SageMaker training pipeline when prediction drift breaches threshold"

  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [aws_cloudwatch_metric_alarm.prediction_drift[0].alarm_name]
      state = {
        value = ["ALARM"]
      }
    }
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "drift_retrain_pipeline" {
  count = local.model_monitor_count

  rule      = aws_cloudwatch_event_rule.drift_retrain[0].name
  target_id = "RetrainPipeline"
  arn       = data.terraform_remote_state.training.outputs.sagemaker_pipeline_arn
  role_arn  = aws_iam_role.drift_retrain[0].arn

  sagemaker_pipeline_target {
    pipeline_parameter_list {
      name  = "RetrainingReason"
      value = "drift_detected"
    }
  }
}

resource "aws_iam_role" "drift_retrain" {
  count = local.model_monitor_count

  name = "${var.project_name}-drift-retrain-events-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "drift_retrain" {
  count = local.model_monitor_count

  name = "${var.project_name}-drift-retrain-policy"
  role = aws_iam_role.drift_retrain[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sagemaker:StartPipelineExecution"
      Resource = data.terraform_remote_state.training.outputs.sagemaker_pipeline_arn
    }]
  })
}

################################################################################
# Human-in-the-loop review (Amazon A2I)
################################################################################
#
# Routes low-confidence predictions to a private workforce of radiologists. The
# inference Lambda calls start_human_loop against the flow definition ARN; the
# reviewer decision lands in the monitoring bucket and feeds the next retrain.
# Gated on enable_human_review + a workteam ARN (the private workforce is a
# one-time per-account Cognito setup outside Terraform).
module "a2i_review" {
  count  = var.enable_human_review ? 1 : 0
  source = "../modules/terraform-aws-a2i-review"

  name_prefix        = var.project_name
  workteam_arn       = var.review_workteam_arn
  output_s3_uri      = "s3://${local.training_outputs.monitoring_bucket}/human-review"
  execution_role_arn = data.terraform_remote_state.training.outputs.sagemaker_execution_role_arn

  tags = local.common_tags
}

################################################################################
# Bedrock Guardrail (responsible-AI safeguard on the hybrid FM output)
################################################################################
#
# Constrains the foundation-model responses used for low-confidence hybrid
# inference (Part 4): blocks PII leakage and out-of-scope/unsafe content in the
# generated reasoning. Created only when hybrid inference is enabled. Native
# resource: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrock_guardrail
resource "aws_bedrock_guardrail" "hybrid" {
  count = var.enable_bedrock_hybrid_inference ? 1 : 0

  name                      = "${var.project_name}-hybrid-guardrail"
  description               = "Safeguards FM reasoning on low-confidence medical predictions"
  blocked_input_messaging   = "This request cannot be processed by the assistant."
  blocked_outputs_messaging = "The generated response was withheld by the content guardrail."

  content_policy_config {
    filters_config {
      type            = "HATE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "VIOLENCE"
      input_strength  = "MEDIUM"
      output_strength = "MEDIUM"
    }
    filters_config {
      type            = "MISCONDUCT"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
  }

  # Anonymize any patient-identifying text the FM might surface in its reasoning.
  sensitive_information_policy_config {
    pii_entities_config {
      type           = "NAME"
      action         = "ANONYMIZE"
      input_action   = "ANONYMIZE"
      output_action  = "ANONYMIZE"
      input_enabled  = true
      output_enabled = true
    }
  }

  tags = local.common_tags
}
