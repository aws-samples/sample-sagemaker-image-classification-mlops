# © 2026 Amazon Web Services, Inc. or its affiliates. All Rights Reserved.
#
# This AWS Content is provided subject to the terms of the AWS Customer Agreement
# available at http://aws.amazon.com/agreement or other written agreement between
# Customer and either Amazon Web Services, Inc. or Amazon Web Services EMEA SARL or both.

# General
project_name = "medical-image-classification"
environment  = "dev"
aws_region   = "us-east-1"

# API
api_stage_name = "prod"

# Lambda
lambda_timeout     = 300
lambda_memory_size = 1024

# Monitoring
log_retention_days = 14
alert_email        = "" # Add your email for alerts
drift_threshold    = 0.1

# Auto-scaling (real-time mode only — ignored when use_serverless_inference = true)
endpoint_min_capacity                = 1
endpoint_max_capacity                = 3
target_concurrent_requests_per_model = 5 # concurrent in-flight requests per model copy; sub-minute scale-out

# Serverless Inference (opt-in)
#
# Set use_serverless_inference = true to swap the always-on ml.m5.xlarge
# endpoint for a scale-to-zero serverless variant. For a low-traffic blog
# demo this drops the endpoint bill from ~$170/month to ~$5-10/month.
# Tradeoffs:
#   - 1-5 second cold start after idle periods
#   - Model Monitor (data capture) is disabled automatically
#   - Clarify bias monitoring is disabled automatically
#   - Weekly endpoint refresh (OS patching) is skipped
# See modules/sagemaker-endpoint/README.md for the full tradeoff list.
use_serverless_inference   = false
serverless_memory_size_mb  = 3072 # 1024 / 2048 / 3072 / 4096 / 5120 / 6144
serverless_max_concurrency = 10   # max concurrent requests (1-200)

# Model Monitor
enable_model_monitor = true
model_monitor_config = {
  setup_on_deploy        = true
  data_quality_schedule  = "cron(0 * * * ? *)"   # Hourly
  model_quality_schedule = "cron(0 */6 * * ? *)" # Every 6 hours
  instance_type          = "ml.m5.xlarge"
  volume_size            = 30
  max_runtime            = 3600
}

# End-to-end exercise of opt-in responsible-AI features (Part 3/4).
enable_bedrock_hybrid_inference = true
bedrock_confidence_threshold    = 0.99 # high so the demo prediction routes to Bedrock
enable_async_explainability     = true
