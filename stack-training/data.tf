# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

data "aws_sagemaker_prebuilt_ecr_image" "sklearn" {
  repository_name = "sagemaker-scikit-learn"
  image_tag       = var.sagemaker_images.sklearn_tag
}

data "aws_sagemaker_prebuilt_ecr_image" "tensorflow_gpu" {
  repository_name = "tensorflow-training"
  image_tag       = var.sagemaker_images.tensorflow_gpu_tag
}

data "aws_sagemaker_prebuilt_ecr_image" "tensorflow_cpu" {
  repository_name = "tensorflow-training"
  image_tag       = var.sagemaker_images.tensorflow_cpu_tag
}

data "aws_sagemaker_prebuilt_ecr_image" "tensorflow_inference" {
  repository_name = "tensorflow-inference"
  image_tag       = var.sagemaker_images.tensorflow_inference_tag
}

# Local values
locals {
  # Tags for module calls (modules don't inherit provider default_tags)
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Purpose     = "training-pipeline"
  }

  # Container paths
  container_paths = {
    code   = "/opt/ml/processing/input/code"
    data   = "/opt/ml/processing/input/data"
    output = "/opt/ml/processing/output"
  }

  # Base bucket mappings
  base_buckets = {
    scripts         = module.s3_scripts.bucket_id
    raw_data        = module.s3_raw_data.bucket_id
    processed_data  = module.s3_processed_data.bucket_id
    model_artifacts = module.s3_model_artifacts.bucket_id
  }

  # Dynamic model order derived from variables (reverse sorted)
  model_order = reverse(sort(keys(var.models)))

  # Dynamic model names from model keys
  model_names = join(",", keys(var.models))

  # Script paths for pipeline steps
  script_paths = {
    validation_script          = "${local.container_paths.code}/${var.pipeline_steps.validation.script_name}"
    preprocessing_script       = "${local.container_paths.code}/${var.pipeline_steps.preprocessing.script_name}"
    preprocessing_requirements = "${local.container_paths.code}/requirements.txt"
    evaluation_script          = "${local.container_paths.code}/${var.pipeline_steps.evaluation.script_name}"
    ensemble_script            = "${local.container_paths.code}/${var.pipeline_steps.ensemble.script_name}"
    bias_runner                = "${local.container_paths.code}/run_bias_check.sh"
    registry_script            = "${local.container_paths.code}/${var.pipeline_steps.registry.script_name}"

  }

  # Common processing paths
  processing_paths = {
    input_data     = "/opt/ml/processing/input/data"
    input_models   = "/opt/ml/processing/input/models"
    input_test     = "/opt/ml/processing/input/data/test"
    input_eval     = "/opt/ml/processing/input/evaluation"
    input_ensemble = "/opt/ml/processing/input/ensemble"
    input_registry = "/opt/ml/processing/input/registry"
    output         = "/opt/ml/processing/output"
  }

}
