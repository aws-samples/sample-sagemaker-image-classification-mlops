# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

resource "aws_sagemaker_monitoring_schedule" "bias" {
  count = var.enable_bias_monitoring ? 1 : 0

  name = var.bias_monitoring_name

  monitoring_schedule_config {
    schedule_config {
      schedule_expression = var.bias_schedule_expression
    }

    monitoring_job_definition_name = aws_sagemaker_data_quality_job_definition.bias[0].name
    monitoring_type                = "DataQuality"
  }

  tags = var.tags
}

################################################################################
# Data Quality Job Definition (used for Clarify bias baseline)
################################################################################

resource "aws_sagemaker_data_quality_job_definition" "bias" {
  count = var.enable_bias_monitoring ? 1 : 0

  name = "${var.bias_monitoring_name}-job-def"

  data_quality_app_specification {
    image_uri = var.clarify_image_uri

    environment = {
      "analysis_type" = "PRE_TRAINING_BIAS"
      "label"         = var.label_column
    }
  }

  # Baseline reference (output-only prediction_score) so Clarify has a
  # distribution to compare captured traffic against, and skips base64 inputs.
  dynamic "data_quality_baseline_config" {
    for_each = var.baseline_statistics_s3_uri != "" && var.baseline_constraints_s3_uri != "" ? [1] : []

    content {
      statistics_resource {
        s3_uri = var.baseline_statistics_s3_uri
      }

      constraints_resource {
        s3_uri = var.baseline_constraints_s3_uri
      }
    }
  }

  data_quality_job_input {
    endpoint_input {
      endpoint_name             = var.endpoint_name
      local_path                = "/opt/ml/processing/input/data"
      s3_input_mode             = "File"
      s3_data_distribution_type = "FullyReplicated"
    }
  }

  data_quality_job_output_config {
    monitoring_outputs {
      s3_output {
        s3_uri     = "s3://${var.results_bucket}/bias-reports/"
        local_path = "/opt/ml/processing/output"
      }
    }

    kms_key_id = var.kms_key_arn
  }

  job_resources {
    cluster_config {
      instance_count    = 1
      instance_type     = var.processing_instance_type
      volume_size_in_gb = 20
      # Encrypt the processing-job volume with the project CMK. Matches
      # the Data Quality job definition's encryption.
      volume_kms_key_id = var.kms_key_arn
    }
  }

  role_arn = var.execution_role_arn

  stopping_condition {
    max_runtime_in_seconds = var.job_max_runtime_seconds
  }

  network_config {
    enable_inter_container_traffic_encryption = true
    enable_network_isolation                  = false
  }

  tags = var.tags
}
