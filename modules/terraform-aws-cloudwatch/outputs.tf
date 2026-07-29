# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "dashboard_name" {
  description = "Dashboard name"
  value       = var.enable_training_monitoring ? (length(aws_cloudwatch_dashboard.training_dashboard) > 0 ? aws_cloudwatch_dashboard.training_dashboard[0].dashboard_name : null) : (length(aws_cloudwatch_dashboard.generic) > 0 ? aws_cloudwatch_dashboard.generic[0].dashboard_name : null)
}

output "training_dashboard_url" {
  description = "Training monitoring dashboard URL"
  value       = var.enable_training_monitoring && length(aws_cloudwatch_dashboard.training_dashboard) > 0 ? "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.training_dashboard[0].dashboard_name}" : null
}

################################################################################
# Log Groups
################################################################################

output "training_log_groups" {
  description = "SageMaker default log groups used"
  value = var.enable_training_monitoring ? {
    training_jobs   = "/aws/sagemaker/TrainingJobs"
    processing_jobs = "/aws/sagemaker/ProcessingJobs"
  } : {}
}

output "pipeline_log_groups" {
  description = "SageMaker default log groups used"
  value = var.enable_training_monitoring ? {
    processing = "/aws/sagemaker/ProcessingJobs"
  } : {}
}

output "generic_log_groups" {
  description = "Generic log groups created"
  value       = !var.enable_training_monitoring ? { for k, v in aws_cloudwatch_log_group.generic : k => v.name } : {}
}

################################################################################
# Metric Filters
################################################################################

output "metric_filters" {
  description = "Metric filters created"
  value = !var.enable_training_monitoring ? {
    for k, v in aws_cloudwatch_log_metric_filter.generic : k => {
      name      = v.name
      namespace = v.metric_transformation[0].namespace
    }
  } : {}
}
