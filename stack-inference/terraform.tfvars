# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

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

# Endpoint size. Canary and linear traffic shifting need at least 2 instances.
endpoint_initial_instance_count = 2

# Auto-scaling (real-time mode only - ignored when use_serverless_inference = true)
endpoint_min_capacity                = 2
endpoint_max_capacity                = 3
target_concurrent_requests_per_model = 5 # concurrent in-flight requests per model copy; sub-minute scale-out

# Blue/green deployment policy for every endpoint update (first deploy,
# approval-driven auto-deploy, weekly refresh). CANARY sends
# canary_size_percent of the new fleet's capacity traffic first, bakes for
# traffic_shift_wait_interval seconds, then shifts the rest. The error and
# latency alarms roll back at any point. LINEAR uses linear_step_percent per
# step; ALL_AT_ONCE allows a single instance.
traffic_routing_type        = "CANARY" # CANARY / LINEAR / ALL_AT_ONCE
canary_size_percent         = 10
linear_step_percent         = 20
traffic_shift_wait_interval = 300
termination_wait_seconds    = 120
deployment_max_timeout      = 3600

# Serverless Inference (opt-in)
#
# Set use_serverless_inference = true to swap the always-on ml.m5.xlarge
# endpoint for a scale-to-zero serverless variant. For a low-traffic blog
# demo this drops the endpoint bill from ~$340/month (two instances) to
# ~$5-10/month.
# Tradeoffs:
#   - 1-5 second cold start after idle periods
#   - Weekly endpoint refresh (OS patching) is skipped
#   - Updates shift all traffic at once (no canary)
# See modules/sagemaker-endpoint/README.md for the full tradeoff list.
use_serverless_inference   = false
serverless_memory_size_mb  = 3072 # 1024 / 2048 / 3072 / 4096 / 5120 / 6144
serverless_max_concurrency = 10   # max concurrent requests (1-200)

# End-to-end exercise of opt-in responsible-AI features (Part 3/4).
enable_bedrock_hybrid_inference = true
bedrock_confidence_threshold    = 0.99 # high so the demo prediction routes to Bedrock
enable_request_explanations     = true
