# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# General
project_name = "image-classification"
environment  = "dev"
aws_region   = "us-east-1"

# Audit & Compliance. The trail records management events account-wide (multi-
# region) plus data events on the project buckets and Lambda functions. Set it
# to false when an organization trail already records this account.
enable_cloudtrail         = true
cloudtrail_retention_days = 400

# Cost Governance - project-scoped monthly budget (filtered by Project tag)
# Set monthly_budget_usd = 0 to disable. Emails are notified at 80% actual
# and 100% forecasted thresholds.
monthly_budget_usd  = 200
budget_alert_emails = [] # e.g., ["oncall@example.com"]

# Pipeline Steps
pipeline_steps = {
  validation = {
    instance_type  = "ml.m5.large"
    instance_count = 1
    volume_size    = 30
    script_name    = "data_validator.py"
    step_name      = "ValidateDataset"
    step_type      = "Processing"
    enable_cache   = false
    cache_expiry   = "P7D"
  }
  # Each instance preprocesses its share of the images (ShardedByS3Key); the
  # group split is the same on every instance.
  preprocessing = {
    instance_type  = "ml.m5.4xlarge"
    instance_count = 2
    volume_size    = 100
    script_name    = "data_preprocessor.py"
    step_name      = "PreprocessData"
    step_type      = "Processing"
    enable_cache   = false
    cache_expiry   = "P7D"
  }
  evaluation = {
    instance_type  = "ml.m5.4xlarge"
    instance_count = 1
    volume_size    = 100
    script_name    = "model_evaluator.py"
    step_name      = "EvaluateAllModels"
    step_type      = "Processing"
    enable_cache   = false
    cache_expiry   = "P7D"
  }
  ensemble = {
    instance_type  = "ml.m5.4xlarge"
    instance_count = 1
    volume_size    = 100
    script_name    = "ensemble_creator.py"
    step_name      = "CreateEnsembleModel"
    step_type      = "Processing"
    enable_cache   = false
    cache_expiry   = "P7D"
  }

  # Part 4 fairness gate. Runs Fairlearn on the ensemble predictions and writes
  # bias_metrics.json, which the quality gate reads alongside the accuracy
  # metrics.
  bias = {
    instance_type  = "ml.m5.large"
    instance_count = 1
    volume_size    = 30
    script_name    = "compute_bias.py"
    step_name      = "BiasCheck"
    step_type      = "Processing"
    enable_cache   = false
    cache_expiry   = "P7D"
  }

  registry = {
    # The RegisterModel step reads only step_name and step_type.
    instance_type  = ""
    instance_count = 1
    volume_size    = 30
    script_name    = ""
    step_name      = "RegisterEnsembleModel"
    step_type      = "RegisterModel"
    enable_cache   = false
    cache_expiry   = "P7D"
  }
}

# KMS
kms_deletion_window_days = 30
enable_kms_key_rotation  = true

# Training. Images live under <training_data_path><label>/<file>;
# scripts/data_uploader.sh writes the auto_trigger_marker_key object that
# starts the pipeline.
training_data_path      = "images/"
auto_trigger_marker_key = "images/.batch_complete"
positive_class          = ""
backbone_weights_s3_uri = ""
min_images_per_class    = 50
enable_auto_trigger     = true
training_input_mode     = "FastFile"

# Upload quarantine: images under training_data_path that fail the extension,
# Pillow-open or minimum-size check move to quarantine_prefix with a
# .reason.json next to each.
enable_upload_quarantine     = true
quarantine_prefix            = "quarantine/"
quarantine_min_image_size_px = 112

# Monitoring
enable_training_monitoring = true
log_retention_days         = 365
log_groups                 = {}
log_group_names = {
  processing = "/aws/sagemaker/ProcessingJobs"
  training   = "/aws/sagemaker/TrainingJobs"
}
metric_namespaces = {
  data       = "DataMetrics"
  model      = "ModelMetrics"
  evaluation = "EvaluationMetrics"
  ensemble   = "EnsembleMetrics"
  registry   = "RegistryMetrics"
}
dashboard_name   = "image-classification-training-monitoring"
dashboard_config = ""

# Models
models = {
  vgg16 = {
    script_name = "vgg16_trainer.py"
    tar_file    = "vgg16_trainer.tar.gz"
    step_name   = "TrainVgg16Model"
    hyperparameters = {
      TRAINING_EPOCHS        = "2"
      TRAINING_BATCH_SIZE    = "32"
      TRAINING_LEARNING_RATE = "0.0005"
      PHASE1_EPOCHS          = "1"
    }
    volume_size    = 100
    instance_count = 1
    max_runtime    = 14400
    instance_type  = "ml.c5.2xlarge"
    enable_cache   = false
    cache_expiry   = "P7D"
  }
  densenet121 = {
    script_name = "densenet121_trainer.py"
    tar_file    = "densenet121_trainer.tar.gz"
    step_name   = "TrainDenseNet121Model"
    hyperparameters = {
      TRAINING_EPOCHS        = "2"
      TRAINING_BATCH_SIZE    = "32"
      TRAINING_LEARNING_RATE = "0.0005"
      PHASE1_EPOCHS          = "1"
    }
    volume_size    = 100
    instance_count = 1
    max_runtime    = 14400
    instance_type  = "ml.c5.2xlarge"
    enable_cache   = false
    cache_expiry   = "P7D"
  }
  efficientnet = {
    script_name = "efficientnet_trainer.py"
    tar_file    = "efficientnet_trainer.tar.gz"
    step_name   = "TrainEfficientNetModel"
    hyperparameters = {
      TRAINING_EPOCHS        = "2"
      TRAINING_BATCH_SIZE    = "32"
      TRAINING_LEARNING_RATE = "0.0005"
      PHASE1_EPOCHS          = "1"
    }
    volume_size    = 100
    instance_count = 1
    max_runtime    = 14400
    instance_type  = "ml.c5.2xlarge"
    enable_cache   = false
    cache_expiry   = "P7D"
  }
}
enable_managed_spot_training = false
training_keep_alive_seconds  = 0
