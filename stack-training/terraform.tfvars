# © 2026 Amazon Web Services, Inc. or its affiliates. All Rights Reserved.
#
# This AWS Content is provided subject to the terms of the AWS Customer Agreement
# available at http://aws.amazon.com/agreement or other written agreement between
# Customer and either Amazon Web Services, Inc. or Amazon Web Services EMEA SARL or both.

# General
project_name = "medical-image-classification"
environment  = "dev"
aws_region   = "us-east-1"

# Audit & Compliance
enable_cloudtrail         = true
cloudtrail_retention_days = 400

# Cost Governance — project-scoped monthly budget (filtered by Project tag)
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
  preprocessing = {
    instance_type  = "ml.m5.4xlarge"
    instance_count = 1
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

  registry = {
    instance_type  = "" # Not Required for Registry
    instance_count = 1  # Not Required for Registry
    volume_size    = 30 # Not Required for Registry
    script_name    = "" # Not Required for Registry
    step_name      = "RegisterEnsembleModel"
    step_type      = "RegisterModel"
    enable_cache   = false # Not Required for Registry
    cache_expiry   = "P7D" # Not Required for Registry
  }
}

# KMS
kms_deletion_window_days = 7
enable_kms_key_rotation  = true

# Training
training_data_path   = "dummy5050/"
min_images_per_class = 50
enable_auto_trigger  = true
training_input_mode  = "FastFile"

# Monitoring
enable_training_monitoring = true
log_retention_days         = 30
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
dashboard_name   = "medical-image-classification-training-monitoring"
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
