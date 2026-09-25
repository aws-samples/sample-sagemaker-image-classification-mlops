# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

locals {
  # Scheduled monitoring Processing jobs. Both read endpoint data capture, which
  # serverless variants do not support, so they are skipped in serverless mode.
  drift_job_count    = (var.enable_drift_job && !var.use_serverless_inference) ? 1 : 0
  fairness_job_count = (var.enable_fairness_job && !var.use_serverless_inference) ? 1 : 0

  # Namespace/metrics the scheduled jobs publish to and their alarms read from.
  # Fairness shares the drift namespace so both signals graph side by side.
  drift_metric_namespace = "${var.project_name}/DriftDetection"
  drift_metric_name      = "prediction_score_psi"

  # Baseline score distribution the drift job compares against. The
  # auto-deploy Lambda rewrites it from each deployed package's test scores.
  drift_baseline_key   = "monitoring/baselines/output-only/statistics.json"
  fairness_metric_name = "fairness_max_disparity"

  # The retrain rule fires on any monitoring alarm that exists. A fairness
  # breach is as much a reason to retrain as a distribution shift.
  drift_alarm_names = concat(
    [for a in aws_cloudwatch_metric_alarm.prediction_drift_psi : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.fairness_disparity : a.alarm_name],
  )
  drift_retrain_count = length(local.drift_alarm_names) > 0 ? 1 : 0
}

################################################################################
# Scheduled drift Processing job
################################################################################

# Alarm on the PSI the scheduled Processing job publishes. Drives the same SNS
# actions and the same EventBridge retrain rule as any other drift signal.
resource "aws_cloudwatch_metric_alarm" "prediction_drift_psi" {
  count = local.drift_job_count

  alarm_name          = "${var.project_name}-prediction-drift-psi"
  alarm_description   = "Population Stability Index on the prediction-score distribution exceeded ${var.drift_threshold}, computed by the scheduled drift Processing job from endpoint data capture. Triggers automated retraining (human approval still required before redeploy)."
  namespace           = local.drift_metric_namespace
  metric_name         = local.drift_metric_name
  statistic           = "Maximum"
  period              = var.drift_alarm_period
  evaluation_periods  = 1
  threshold           = var.drift_threshold
  comparison_operator = "GreaterThanThreshold"

  # The detector publishes nothing when traffic is too thin to judge, so a gap
  # must not read as drift.
  treat_missing_data = "notBreaching"

  dimensions = {
    EndpointName = local.endpoint_name
  }

  alarm_actions = [module.sns_alerts.sns_topic_arn]
  ok_actions    = [module.sns_alerts.sns_topic_arn]

  tags = { Purpose = "DriftDetection" }
}

# Schedule the drift Processing job. EventBridge Scheduler calls
# sagemaker:CreateProcessingJob directly as a universal target, so no Lambda sits
# in the path. Cadence should not outpace the lookback window.
resource "aws_scheduler_schedule" "drift_job" {
  count = local.drift_job_count

  name                         = "${var.project_name}-drift-job-schedule"
  description                  = "Periodically compute prediction-score PSI from endpoint data capture"
  schedule_expression          = var.drift_detector_schedule_expression
  schedule_expression_timezone = "UTC"
  state                        = "ENABLED"

  # Encrypt the schedule's target payload with the project CMK (the input carries
  # bucket names and the execution role ARN).
  kms_key_arn = local.training_outputs.kms_key_arn

  flexible_time_window {
    mode = "OFF"
  }

  target {
    # Universal target: the Scheduler invokes the SageMaker API directly.
    arn      = "arn:aws:scheduler:::aws-sdk:sagemaker:createProcessingJob"
    role_arn = aws_iam_role.drift_job_scheduler[0].arn

    input = jsonencode({
      # Job names must be unique per run; <aws.scheduler.scheduled-time> is
      # substituted by the Scheduler at invocation.
      ProcessingJobName = "${var.project_name}-drift-<aws.scheduler.execution-id>"
      RoleArn           = data.terraform_remote_state.training.outputs.sagemaker_execution_role_arn

      AppSpecification = {
        ImageUri = data.aws_sagemaker_prebuilt_ecr_image.monitoring_jobs.registry_path
        ContainerEntrypoint = [
          "python3", "/opt/ml/processing/input/code/compute_drift.py",
          "--monitoring-bucket", local.training_outputs.monitoring_bucket,
          "--capture-prefix", "data-capture",
          "--baseline-key", local.drift_baseline_key,
          "--metric-namespace", local.drift_metric_namespace,
          "--metric-name", local.drift_metric_name,
          "--endpoint-name", local.endpoint_name,
          "--lookback-hours", tostring(var.drift_detector_lookback_hours),
          "--min-samples", tostring(var.drift_detector_min_samples),
        ]
      }

      ProcessingInputs = [{
        InputName = "code"
        S3Input = {
          S3Uri       = "s3://${data.terraform_remote_state.training.outputs.scripts_bucket}/drift/"
          LocalPath   = "/opt/ml/processing/input/code"
          S3DataType  = "S3Prefix"
          S3InputMode = "File"
        }
      }]

      ProcessingResources = {
        ClusterConfig = {
          InstanceCount  = 1
          InstanceType   = var.drift_job_instance_type
          VolumeSizeInGB = 30
          # Encrypt the attached volume with the project CMK.
          VolumeKmsKeyId = local.training_outputs.kms_key_arn
        }
      }

      StoppingCondition = {
        MaxRuntimeInSeconds = var.drift_job_max_runtime
      }

      # A Processing container inherits no region, so boto3 raises NoRegionError
      # before the script does any work. SageMaker does not inject this for you.
      Environment = {
        AWS_DEFAULT_REGION = var.aws_region
      }

      NetworkConfig = {
        EnableInterContainerTrafficEncryption = true
        EnableNetworkIsolation                = false
      }
    })
  }
}

# Role the Scheduler assumes to create the Processing job and pass the execution
# role to SageMaker.
resource "aws_iam_role" "drift_job_scheduler" {
  count = local.drift_job_count

  name                 = "${var.project_name}-drift-job-scheduler"
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "scheduler.amazonaws.com" }
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "drift_job_scheduler" {
  count = local.drift_job_count

  name = "${var.project_name}-drift-job-scheduler"
  role = aws_iam_role.drift_job_scheduler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Scoped to this project's drift jobs by name prefix.
        Effect   = "Allow"
        Action   = ["sagemaker:CreateProcessingJob"]
        Resource = "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:processing-job/${var.project_name}-drift-*"
      },
      {
        # Hand the SageMaker execution role to SageMaker only.
        Effect = "Allow"
        # nosemgrep: terraform.lang.security.iam.no-iam-resource-exposure.no-iam-resource-exposure - PassRole on the one SageMaker execution role, to sagemaker.amazonaws.com only
        Action   = ["iam:PassRole"]
        Resource = data.terraform_remote_state.training.outputs.sagemaker_execution_role_arn
        Condition = {
          StringEquals = { "iam:PassedToService" = "sagemaker.amazonaws.com" }
        }
      }
    ]
  })
}

################################################################################
# Scheduled fairness Processing job
################################################################################
#
# The BiasCheck step in stack-training proves a model was fair on the test split
# before it registered. It cannot see a population shift after deployment: a
# hospital network adding a site with a different demographic mix can raise the
# false-negative rate for that group while aggregate accuracy looks unchanged.
# This job re-measures the same Fairlearn metrics on live traffic, using the
# confirmed diagnostic outcomes clinicians upload as ground truth.

# Alarm on the live disparity. Held to the same threshold the model registered
# under, and wired into the same retrain rule as drift.
resource "aws_cloudwatch_metric_alarm" "fairness_disparity" {
  count = local.fairness_job_count

  alarm_name          = "${var.project_name}-fairness-disparity"
  alarm_description   = "Demographic-parity or equalized-odds difference across subgroups exceeded ${var.fairness_disparity_threshold} on live traffic, computed by the scheduled fairness Processing job from endpoint data capture joined with clinician-confirmed outcomes. Triggers automated retraining (human approval still required before redeploy)."
  namespace           = local.drift_metric_namespace
  metric_name         = local.fairness_metric_name
  statistic           = "Maximum"
  period              = var.fairness_alarm_period
  evaluation_periods  = 1
  threshold           = var.fairness_disparity_threshold
  comparison_operator = "GreaterThanThreshold"

  # The job publishes nothing when too few predictions have a confirmed outcome
  # to judge, so a gap must not read as a fairness breach.
  treat_missing_data = "notBreaching"

  dimensions = {
    EndpointName = local.endpoint_name
  }

  alarm_actions = [module.sns_alerts.sns_topic_arn]
  ok_actions    = [module.sns_alerts.sns_topic_arn]

  tags = { Purpose = "FairnessMonitoring" }
}

# Schedule the fairness Processing job. Same universal-target pattern as the
# drift job: EventBridge Scheduler calls sagemaker:CreateProcessingJob directly,
# so no Lambda sits in the path.
resource "aws_scheduler_schedule" "fairness_job" {
  count = local.fairness_job_count

  name                         = "${var.project_name}-fairness-monitor"
  description                  = "Periodically compute subgroup fairness metrics from endpoint data capture and confirmed outcomes"
  schedule_expression          = var.fairness_job_schedule_expression
  schedule_expression_timezone = "UTC"
  state                        = "ENABLED"

  # Encrypt the schedule's target payload with the project CMK (the input carries
  # bucket names and the execution role ARN).
  kms_key_arn = local.training_outputs.kms_key_arn

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:sagemaker:createProcessingJob"
    role_arn = aws_iam_role.fairness_job_scheduler[0].arn

    input = jsonencode({
      # Job names must be unique per run; <aws.scheduler.execution-id> is
      # substituted by the Scheduler at invocation.
      ProcessingJobName = "${var.project_name}-fairness-<aws.scheduler.execution-id>"
      RoleArn           = data.terraform_remote_state.training.outputs.sagemaker_execution_role_arn

      AppSpecification = {
        ImageUri = data.aws_sagemaker_prebuilt_ecr_image.monitoring_jobs.registry_path
        # Fairlearn is not in the scikit-learn DLC and a raw ProcessingJob does
        # not auto-install requirements.txt, so a wrapper installs it first.
        ContainerEntrypoint = ["/bin/sh", "/opt/ml/processing/input/code/run_fairness.sh"]
        ContainerArguments = [
          "--monitoring-bucket", local.training_outputs.monitoring_bucket,
          "--capture-prefix", "data-capture",
          "--ground-truth-prefix", var.fairness_ground_truth_prefix,
          "--metric-namespace", local.drift_metric_namespace,
          "--metric-name", local.fairness_metric_name,
          "--endpoint-name", local.endpoint_name,
          "--lookback-hours", tostring(var.fairness_job_lookback_hours),
          "--min-samples", tostring(var.fairness_job_min_samples),
          "--threshold", tostring(var.fairness_disparity_threshold),
        ]
      }

      ProcessingInputs = [{
        InputName = "code"
        S3Input = {
          S3Uri       = "s3://${data.terraform_remote_state.training.outputs.scripts_bucket}/fairness/"
          LocalPath   = "/opt/ml/processing/input/code"
          S3DataType  = "S3Prefix"
          S3InputMode = "File"
        }
      }]

      # Keeps the per-run fairness_metrics.json for the audit trail: the
      # CloudWatch metric is one number, this is the full per-subgroup report.
      ProcessingOutputConfig = {
        Outputs = [{
          OutputName = "fairness-metrics"
          S3Output = {
            S3Uri        = "s3://${local.training_outputs.monitoring_bucket}/fairness-reports/"
            LocalPath    = "/opt/ml/processing/output"
            S3UploadMode = "EndOfJob"
          }
        }]
      }

      ProcessingResources = {
        ClusterConfig = {
          InstanceCount  = 1
          InstanceType   = var.fairness_job_instance_type
          VolumeSizeInGB = 30
          # Encrypt the attached volume with the project CMK.
          VolumeKmsKeyId = local.training_outputs.kms_key_arn
        }
      }

      StoppingCondition = {
        MaxRuntimeInSeconds = var.fairness_job_max_runtime
      }

      # A Processing container inherits no region, so boto3 raises NoRegionError
      # before the script does any work. SageMaker does not inject this for you.
      Environment = {
        AWS_DEFAULT_REGION = var.aws_region
      }

      NetworkConfig = {
        EnableInterContainerTrafficEncryption = true
        # Fairlearn is pip-installed at job start, so the container needs egress.
        EnableNetworkIsolation = false
      }
    })
  }
}

# Role the Scheduler assumes to create the Processing job and pass the execution
# role to SageMaker.
resource "aws_iam_role" "fairness_job_scheduler" {
  count = local.fairness_job_count

  name                 = "${var.project_name}-fairness-job-scheduler"
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "scheduler.amazonaws.com" }
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "fairness_job_scheduler" {
  count = local.fairness_job_count

  name = "${var.project_name}-fairness-job-scheduler"
  role = aws_iam_role.fairness_job_scheduler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Scoped to this project's fairness jobs by name prefix.
        Effect   = "Allow"
        Action   = ["sagemaker:CreateProcessingJob"]
        Resource = "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:processing-job/${var.project_name}-fairness-*"
      },
      {
        # Hand the SageMaker execution role to SageMaker only.
        Effect = "Allow"
        # nosemgrep: terraform.lang.security.iam.no-iam-resource-exposure.no-iam-resource-exposure - PassRole on the one SageMaker execution role, to sagemaker.amazonaws.com only
        Action   = ["iam:PassRole"]
        Resource = data.terraform_remote_state.training.outputs.sagemaker_execution_role_arn
        Condition = {
          StringEquals = { "iam:PassedToService" = "sagemaker.amazonaws.com" }
        }
      }
    ]
  })
}

################################################################################
# Drift / fairness -> retraining (closed loop)
################################################################################

# EventBridge rule: when any monitoring alarm transitions to ALARM, retrain.
resource "aws_cloudwatch_event_rule" "drift_retrain" {
  count = local.drift_retrain_count

  name        = "${var.project_name}-drift-triggers-retraining"
  description = "Start the SageMaker training pipeline when prediction drift breaches threshold"

  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = local.drift_alarm_names
      state = {
        value = ["ALARM"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "drift_retrain_pipeline" {
  count = local.drift_retrain_count

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
  count = local.drift_retrain_count

  name                 = "${var.project_name}-drift-retrain-events-role"
  permissions_boundary = var.permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "drift_retrain" {
  count = local.drift_retrain_count

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
# Optional human-in-the-loop review (Amazon A2I, off by default)
################################################################################
#
# Amazon A2I is in maintenance mode (no longer open to new customers), so this
# is opt-in through enable_human_review. When on, the inference Lambda calls
# start_human_loop for low-confidence predictions and the reviewer decision
# lands in the monitoring bucket for the next retrain. Needs a workteam ARN
# (a one-time per-account private workforce set up outside Terraform).
module "a2i_review" {
  count  = var.enable_human_review ? 1 : 0
  source = "../modules/terraform-aws-a2i-review"

  name_prefix        = var.project_name
  workteam_arn       = var.review_workteam_arn
  output_s3_uri      = "s3://${local.training_outputs.monitoring_bucket}/human-review"
  execution_role_arn = data.terraform_remote_state.training.outputs.sagemaker_execution_role_arn
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
}
