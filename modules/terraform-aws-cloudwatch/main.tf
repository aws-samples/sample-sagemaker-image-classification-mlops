# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

locals {
  # Training mode: ML-specific metrics (hardcoded)
  processed_data_types      = ["TrainingImageCount", "TrainingBenignCount", "TrainingMalignantCount", "ValidationImageCount", "ValidationBenignCount", "ValidationMalignantCount", "TestImageCount", "TestBenignCount", "TestMalignantCount"]
  training_metric_types     = ["TrainingAccuracy", "ValidationAccuracy", "TrainingLoss", "ValidationLoss", "TrainingPrecision", "TrainingRecall", "ValidationPrecision", "ValidationRecall", "EpochsCompleted", "OverfittingGap"]
  evaluation_summary_values = ["BestModelAccuracy", "TotalModelCount", "EvaluationAccuracy", "EvaluationPrecision", "EvaluationRecall", "EvaluationF1Score", "SuccessfulModelCount"]
  ensemble_values           = ["EnsembleAccuracy", "EnsemblePrecision", "EnsembleRecall", "EnsembleF1Score"]
  registry_values           = ["ModelRegistrySuccess", "ModelRegistered", "ModelApprovalStatus"]

  # Dynamic model performance history widgets
  model_performance_widgets = var.enable_training_monitoring ? [
    for i, model in var.training_models : {
      type   = "log"
      x      = (i % 2) * 12
      y      = 6 + floor(i / 2) * 6
      width  = 12
      height = 6
      properties = {
        query  = "SOURCE '${var.log_group_names.processing}'\n| fields @timestamp, @message\n| filter @message like /PerformanceHistoryRecord/ and @message like /${model}/\n| sort @timestamp desc\n| limit 10"
        region = var.aws_region
        title  = "${model == "vgg16" ? "🔵" : model == "densenet121" ? "🟢" : "🟡"} ${title(model)} Performance History"
        view   = "table"
      }
    }
  ] : []

  # Dynamic training metrics for comparison charts
  training_accuracy_metrics    = var.enable_training_monitoring ? [for model in var.training_models : ["${var.project_name}/ModelMetrics", "ModelTrainingAccuracy${replace(replace(title(model), "-", ""), "_", "")}"]] : []
  validation_accuracy_metrics  = var.enable_training_monitoring ? [for model in var.training_models : ["${var.project_name}/ModelMetrics", "ModelValidationAccuracy${replace(replace(title(model), "-", ""), "_", "")}"]] : []
  training_loss_metrics        = var.enable_training_monitoring ? [for model in var.training_models : ["${var.project_name}/ModelMetrics", "ModelTrainingLoss${replace(replace(title(model), "-", ""), "_", "")}"]] : []
  validation_loss_metrics      = var.enable_training_monitoring ? [for model in var.training_models : ["${var.project_name}/ModelMetrics", "ModelValidationLoss${replace(replace(title(model), "-", ""), "_", "")}"]] : []
  training_precision_metrics   = var.enable_training_monitoring ? [for model in var.training_models : ["${var.project_name}/ModelMetrics", "ModelTrainingPrecision${replace(replace(title(model), "-", ""), "_", "")}"]] : []
  training_recall_metrics      = var.enable_training_monitoring ? [for model in var.training_models : ["${var.project_name}/ModelMetrics", "ModelTrainingRecall${replace(replace(title(model), "-", ""), "_", "")}"]] : []
  validation_precision_metrics = var.enable_training_monitoring ? [for model in var.training_models : ["${var.project_name}/ModelMetrics", "ModelValidationPrecision${replace(replace(title(model), "-", ""), "_", "")}"]] : []
  validation_recall_metrics    = var.enable_training_monitoring ? [for model in var.training_models : ["${var.project_name}/ModelMetrics", "ModelValidationRecall${replace(replace(title(model), "-", ""), "_", "")}"]] : []
  overfitting_gap_metrics      = var.enable_training_monitoring ? [for model in var.training_models : ["${var.project_name}/ModelMetrics", "ModelOverfittingGap${replace(replace(title(model), "-", ""), "_", "")}"]] : []

  ensemble_metrics = var.enable_training_monitoring ? [{
    type   = "metric"
    x      = 18
    y      = 0
    width  = 6
    height = 6
    properties = {
      metrics = [
        ["${var.project_name}/${var.metric_namespaces.ensemble}", "EnsembleAccuracy"],
        ["${var.project_name}/${var.metric_namespaces.ensemble}", "EnsemblePrecision"],
        ["${var.project_name}/${var.metric_namespaces.ensemble}", "EnsembleRecall"],
        ["${var.project_name}/${var.metric_namespaces.ensemble}", "EnsembleF1Score"]
      ]
      view   = "singleValue"
      region = var.aws_region
      title  = "🎯 Ensemble Performance"
      period = 300
      stat   = "Maximum"
    }
  }] : []

  common_tags = var.tags
}

################################################################################
# Log Groups
################################################################################

# Training mode: Create SageMaker log groups
resource "aws_cloudwatch_log_group" "processing_jobs" {
  count = var.enable_training_monitoring ? 1 : 0

  name              = var.log_group_names.processing
  retention_in_days = 14
  kms_key_id        = var.kms_key_arn

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "training_jobs" {
  count = var.enable_training_monitoring ? 1 : 0

  name              = var.log_group_names.training
  retention_in_days = 14
  kms_key_id        = var.kms_key_arn

  tags = local.common_tags
}

# Generic mode: Create custom log groups
resource "aws_cloudwatch_log_group" "generic" {
  for_each = var.enable_training_monitoring ? {} : var.log_groups

  name              = each.value.name
  retention_in_days = try(each.value.retention_in_days, var.log_retention_days)
  kms_key_id        = var.kms_key_arn

  tags = local.common_tags
}

################################################################################
# Dashboard
################################################################################

# Training mode: ML training dashboard
resource "aws_cloudwatch_dashboard" "training_dashboard" {
  count = var.enable_training_monitoring ? 1 : 0

  dashboard_name = "${var.project_name}-training-monitoring"
  dashboard_body = jsonencode({
    widgets = concat(
      [{
        type   = "log"
        x      = 0
        y      = 0
        width  = 18
        height = 6
        properties = {
          query  = "SOURCE '${var.log_group_names.processing}'\n| fields @timestamp, @message\n| filter @message like /dataset_version/\n| sort @timestamp desc\n| limit 10"
          region = var.aws_region
          title  = "📊 Dataset History Table"
          view   = "table"
        }
      }],
      local.ensemble_metrics,
      local.model_performance_widgets,
      [{
        type   = "log"
        x      = 0
        y      = 6 + ceil(length(var.training_models) / 2) * 6
        width  = 24
        height = 6
        properties = {
          query  = "SOURCE '${var.log_group_names.processing}'\n| fields @timestamp, @message\n| filter @message like /PerformanceHistoryRecord/ and @message like /ensemble/\n| sort @timestamp desc\n| limit 10"
          region = var.aws_region
          title  = "🎯 Ensemble Performance History"
          view   = "table"
        }
      }],
      [
        {
          type   = "metric"
          x      = 0
          y      = 12 + ceil(length(var.training_models) / 2) * 6
          width  = 12
          height = 6
          properties = {
            metrics = local.training_accuracy_metrics
            view    = "timeSeries"
            region  = var.aws_region
            title   = "📈 Training Accuracy Comparison"
            period  = 300
            stat    = "Maximum"
            yAxis   = { left = { min = 0, max = 100 } }
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 12 + ceil(length(var.training_models) / 2) * 6
          width  = 12
          height = 6
          properties = {
            metrics = local.validation_accuracy_metrics
            view    = "timeSeries"
            region  = var.aws_region
            title   = "📊 Validation Accuracy Comparison"
            period  = 300
            stat    = "Maximum"
            yAxis   = { left = { min = 0, max = 100 } }
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 18 + ceil(length(var.training_models) / 2) * 6
          width  = 12
          height = 6
          properties = {
            metrics = local.training_loss_metrics
            view    = "timeSeries"
            region  = var.aws_region
            title   = "📉 Training Loss Comparison"
            period  = 300
            stat    = "Maximum"
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 18 + ceil(length(var.training_models) / 2) * 6
          width  = 12
          height = 6
          properties = {
            metrics = local.validation_loss_metrics
            view    = "timeSeries"
            region  = var.aws_region
            title   = "📉 Validation Loss Comparison"
            period  = 300
            stat    = "Maximum"
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 24 + ceil(length(var.training_models) / 2) * 6
          width  = 12
          height = 6
          properties = {
            metrics = local.training_precision_metrics
            view    = "timeSeries"
            region  = var.aws_region
            title   = "🎯 Training Precision Comparison"
            period  = 300
            stat    = "Maximum"
            yAxis   = { left = { min = 0, max = 100 } }
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 24 + ceil(length(var.training_models) / 2) * 6
          width  = 12
          height = 6
          properties = {
            metrics = local.training_recall_metrics
            view    = "timeSeries"
            region  = var.aws_region
            title   = "🔍 Training Recall Comparison"
            period  = 300
            stat    = "Maximum"
            yAxis   = { left = { min = 0, max = 100 } }
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 30 + ceil(length(var.training_models) / 2) * 6
          width  = 12
          height = 6
          properties = {
            metrics = local.validation_precision_metrics
            view    = "timeSeries"
            region  = var.aws_region
            title   = "🎯 Validation Precision Comparison"
            period  = 300
            stat    = "Maximum"
            yAxis   = { left = { min = 0, max = 100 } }
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 30 + ceil(length(var.training_models) / 2) * 6
          width  = 12
          height = 6
          properties = {
            metrics = local.validation_recall_metrics
            view    = "timeSeries"
            region  = var.aws_region
            title   = "🔍 Validation Recall Comparison"
            period  = 300
            stat    = "Maximum"
            yAxis   = { left = { min = 0, max = 100 } }
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 36 + ceil(length(var.training_models) / 2) * 6
          width  = 24
          height = 6
          properties = {
            metrics     = local.overfitting_gap_metrics
            view        = "timeSeries"
            region      = var.aws_region
            title       = "⚠️ Overfitting Gap Analysis (Lower is Better)"
            period      = 300
            stat        = "Maximum"
            annotations = { horizontal = [{ value = 0.2, label = "Warning Threshold" }] }
          }
        }
      ]
    )
  })
}

# Generic mode: Custom dashboard
resource "aws_cloudwatch_dashboard" "generic" {
  count = !var.enable_training_monitoring && var.dashboard_name != null && var.dashboard_config != "" ? 1 : 0

  dashboard_name = var.dashboard_name
  dashboard_body = var.dashboard_config
}

################################################################################
# Metric Filters
################################################################################

# Training mode: Data processing metrics
resource "aws_cloudwatch_log_metric_filter" "data_metrics" {
  for_each = var.enable_training_monitoring ? toset(local.processed_data_types) : toset([])

  name           = "${var.project_name}-${lower(each.value)}"
  log_group_name = var.log_group_names.processing
  pattern        = "{ $.metric_name = \"${each.value}\" }"

  depends_on = [aws_cloudwatch_log_group.processing_jobs]

  metric_transformation {
    name      = each.value
    namespace = "${var.project_name}/${var.metric_namespaces.data}"
    value     = "$.metric_value"
    unit      = "Count"
  }
}

# Training mode: Training metrics per model
resource "aws_cloudwatch_log_metric_filter" "training_metrics" {
  for_each = var.enable_training_monitoring ? {
    for pair in setproduct(var.training_models, local.training_metric_types) :
    "${pair[0]}-${lower(pair[1])}" => {
      model  = pair[0]
      metric = pair[1]
    }
  } : {}

  name           = "${var.project_name}-${each.value.model}-${lower(each.value.metric)}"
  log_group_name = var.log_group_names.training
  pattern        = "{ $.metric_name = \"Model${each.value.metric}${replace(replace(title(each.value.model), "-", ""), "_", "")}\" }"

  depends_on = [aws_cloudwatch_log_group.training_jobs]

  metric_transformation {
    name      = "Model${each.value.metric}${replace(replace(title(each.value.model), "-", ""), "_", "")}"
    namespace = "${var.project_name}/${var.metric_namespaces.model}"
    value     = "$.metric_value"
    unit      = each.value.metric == "EpochsCompleted" ? "Count" : "None"
  }
}

# Training mode: Evaluation summary metrics
resource "aws_cloudwatch_log_metric_filter" "evaluation_summary_metrics" {
  for_each = var.enable_training_monitoring ? toset(local.evaluation_summary_values) : toset([])

  name           = "${var.project_name}-${lower(each.value)}"
  log_group_name = var.log_group_names.processing
  pattern        = "{ $.metric_name = \"${each.value}\" }"

  depends_on = [aws_cloudwatch_log_group.processing_jobs]

  metric_transformation {
    name      = each.value
    namespace = "${var.project_name}/${var.metric_namespaces.evaluation}"
    value     = "$.metric_value"
    unit      = contains(["TotalModelCount", "SuccessfulModelCount"], each.value) ? "Count" : "None"
  }
}

# Training mode: Ensemble metrics
resource "aws_cloudwatch_log_metric_filter" "ensemble_metrics" {
  for_each = var.enable_training_monitoring ? toset(local.ensemble_values) : toset([])

  name           = "${var.project_name}-${lower(each.value)}"
  log_group_name = var.log_group_names.processing
  pattern        = "{ $.metric_name = \"${each.value}\" }"

  depends_on = [aws_cloudwatch_log_group.processing_jobs]

  metric_transformation {
    name      = each.value
    namespace = "${var.project_name}/${var.metric_namespaces.ensemble}"
    value     = "$.metric_value"
    unit      = each.value == "EnsembleModelCount" ? "Count" : "None"
  }
}

# Training mode: Registry metrics
resource "aws_cloudwatch_log_metric_filter" "registry_metrics" {
  for_each = var.enable_training_monitoring ? toset(local.registry_values) : toset([])

  name           = "${var.project_name}-${lower(each.value)}"
  log_group_name = var.log_group_names.processing
  pattern        = "{ $.metric_name = \"${each.value}\" }"

  depends_on = [aws_cloudwatch_log_group.processing_jobs]

  metric_transformation {
    name      = each.value
    namespace = "${var.project_name}/${var.metric_namespaces.registry}"
    value     = "$.metric_value"
    unit      = "None"
  }
}

# Generic mode: Custom metric filters
resource "aws_cloudwatch_log_metric_filter" "generic" {
  for_each = var.enable_training_monitoring ? {} : var.metric_filters

  name           = each.key
  log_group_name = each.value.log_group_name
  pattern        = each.value.pattern

  depends_on = [aws_cloudwatch_log_group.generic]

  metric_transformation {
    name      = each.value.metric_transformation.name
    namespace = each.value.metric_transformation.namespace
    value     = each.value.metric_transformation.value
    unit      = try(each.value.metric_transformation.unit, "None")
  }
}
