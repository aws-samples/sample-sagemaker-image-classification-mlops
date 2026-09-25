# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "raw_data_bucket" {
  description = "Name of the raw data S3 bucket"
  value       = module.s3_raw_data.bucket_id
}

output "processed_data_bucket" {
  description = "Name of the processed data S3 bucket"
  value       = module.s3_processed_data.bucket_id
}

output "scripts_bucket" {
  description = "Name of the scripts S3 bucket"
  value       = module.s3_scripts.bucket_id
}

output "model_artifacts_bucket" {
  description = "Name of the model artifacts S3 bucket"
  value       = module.s3_model_artifacts.bucket_id
}

output "inference_results_bucket" {
  description = "Name of the inference results S3 bucket"
  value       = module.s3_inference_results.bucket_id
}

output "monitoring_bucket" {
  description = "Name of the monitoring S3 bucket"
  value       = module.s3_monitoring.bucket_id
}

################################################################################
# SageMaker Pipeline
################################################################################

output "sagemaker_pipeline_name" {
  description = "Name of the SageMaker pipeline"
  value       = aws_sagemaker_pipeline.medical_image_pipeline.pipeline_name
}

output "sagemaker_pipeline_arn" {
  description = "ARN of the SageMaker pipeline"
  value       = aws_sagemaker_pipeline.medical_image_pipeline.arn
}

################################################################################
# CloudWatch
################################################################################

output "training_dashboard_url" {
  description = "Training monitoring dashboard URL"
  value       = module.cloudwatch_monitoring.training_dashboard_url
}

output "training_log_groups" {
  description = "Training metrics log group names"
  value       = module.cloudwatch_monitoring.training_log_groups
}

output "pipeline_log_groups" {
  description = "Pipeline step log group names"
  value       = module.cloudwatch_monitoring.pipeline_log_groups
}

################################################################################
# MLflow
################################################################################

output "mlflow_tracking_server_arn" {
  description = "ARN of the MLflow tracking server. Null when enable_mlflow = false."
  value       = try(aws_sagemaker_mlflow_tracking_server.mlflow[0].arn, null)
}

output "mlflow_tracking_server_url" {
  description = "URL of the MLflow tracking server. Null when enable_mlflow = false."
  value       = try(aws_sagemaker_mlflow_tracking_server.mlflow[0].tracking_server_url, null)
}

################################################################################
# Model Registry
################################################################################

output "model_package_group_name" {
  description = "Name of the model package group"
  value       = aws_sagemaker_model_package_group.medical_image_models.model_package_group_name
}

output "network_isolation_enabled" {
  description = "Whether the training jobs run with network isolation. When true, the ImageNet weights must be in s3://<scripts-bucket>/pretrained-weights/ (make weights)."
  value       = var.enable_network_isolation
}

################################################################################
# IAM
################################################################################

output "sagemaker_execution_role_arn" {
  description = "ARN of the SageMaker execution role"
  value       = module.sagemaker_execution_role.role_arn
}

################################################################################
# KMS
################################################################################

output "kms_key_id" {
  description = "ID of the KMS key"
  value       = module.kms.key_id
}

output "kms_key_arn" {
  description = "ARN of the KMS key"
  value       = module.kms.key_arn
}

################################################################################
# SageMaker Images
################################################################################

output "sagemaker_image_uris" {
  description = "SageMaker Docker image URIs fetched dynamically from AWS"
  value = {
    tensorflow_gpu_image_uri = data.aws_sagemaker_prebuilt_ecr_image.tensorflow_gpu.registry_path
    tensorflow_cpu_image_uri = data.aws_sagemaker_prebuilt_ecr_image.tensorflow_cpu.registry_path
  }
}

################################################################################
# EventBridge
################################################################################

output "auto_trigger_eventbridge_rule" {
  description = "Name of the EventBridge rule for auto-triggering pipeline"
  value       = var.enable_auto_trigger ? aws_cloudwatch_event_rule.new_data_uploaded[0].name : null
}

################################################################################
# Endpoint
################################################################################

output "endpoint_name" {
  description = "Name of the SageMaker endpoint"
  value       = "${var.project_name}-endpoint"
}

################################################################################
# SBOM
################################################################################

output "sbom_bucket" {
  description = "Name of the SBOM S3 bucket. Null when enable_sbom_bucket = false."
  value       = try(module.s3_sbom[0].bucket_id, null)
}

output "sbom_bucket_arn" {
  description = "ARN of the SBOM S3 bucket. Null when enable_sbom_bucket = false."
  value       = try(module.s3_sbom[0].bucket_arn, null)
}
