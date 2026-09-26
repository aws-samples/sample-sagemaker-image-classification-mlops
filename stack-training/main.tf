# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

module "kms" {
  source = "../modules/terraform-aws-kms"

  description          = "KMS key for S3 bucket encryption"
  deletion_window_days = var.kms_deletion_window_days
  enable_key_rotation  = var.enable_kms_key_rotation
  alias_name           = "alias/${var.project_name}-s3-key"

  # This CMK also encrypts the CloudTrail trail + its CloudWatch log group, so
  # grant the CloudTrail service principal encrypt rights on the key.
  enable_cloudtrail_grant = var.enable_cloudtrail

  # The optional CloudTrail SNS topic is encrypted with this CMK too.
  enable_cloudtrail_sns_grant = var.enable_cloudtrail && var.enable_cloudtrail_sns
}

################################################################################
# S3 Buckets
################################################################################

# Random suffix for bucket names
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# S3 buckets using the reusable module
module "s3_raw_data" {
  source = "../modules/terraform-aws-s3"

  bucket_name         = "${var.project_name}-${var.environment}-raw-data-${random_id.bucket_suffix.hex}"
  force_destroy       = var.bucket_defaults.force_destroy
  kms_key_arn         = module.kms.key_arn
  enable_versioning   = var.bucket_defaults.enable_versioning
  block_public_access = var.bucket_defaults.block_public_access
  enable_eventbridge  = var.enable_auto_trigger
}

module "s3_processed_data" {
  source = "../modules/terraform-aws-s3"

  bucket_name         = "${var.project_name}-${var.environment}-processed-data-${random_id.bucket_suffix.hex}"
  force_destroy       = var.bucket_defaults.force_destroy
  kms_key_arn         = module.kms.key_arn
  enable_versioning   = var.bucket_defaults.enable_versioning
  block_public_access = var.bucket_defaults.block_public_access
}

module "s3_scripts" {
  source = "../modules/terraform-aws-s3"

  bucket_name         = "${var.project_name}-${var.environment}-scripts-${random_id.bucket_suffix.hex}"
  force_destroy       = var.bucket_defaults.force_destroy
  kms_key_arn         = module.kms.key_arn
  enable_versioning   = var.bucket_defaults.enable_versioning
  block_public_access = var.bucket_defaults.block_public_access
}

module "s3_model_artifacts" {
  source = "../modules/terraform-aws-s3"

  bucket_name         = "${var.project_name}-${var.environment}-model-artifacts-${random_id.bucket_suffix.hex}"
  force_destroy       = var.bucket_defaults.force_destroy
  kms_key_arn         = module.kms.key_arn
  enable_versioning   = var.bucket_defaults.enable_versioning
  block_public_access = var.bucket_defaults.block_public_access
}

module "s3_inference_results" {
  source = "../modules/terraform-aws-s3"

  bucket_name         = "${var.project_name}-${var.environment}-inference-results-${random_id.bucket_suffix.hex}"
  force_destroy       = var.bucket_defaults.force_destroy
  kms_key_arn         = module.kms.key_arn
  enable_versioning   = var.bucket_defaults.enable_versioning
  block_public_access = var.bucket_defaults.block_public_access
}

module "s3_monitoring" {
  source = "../modules/terraform-aws-s3"

  bucket_name         = "${var.project_name}-${var.environment}-monitoring-${random_id.bucket_suffix.hex}"
  force_destroy       = var.bucket_defaults.force_destroy
  kms_key_arn         = module.kms.key_arn
  enable_versioning   = var.bucket_defaults.enable_versioning
  block_public_access = var.bucket_defaults.block_public_access
}

################################################################################
# IAM
################################################################################

# SageMaker execution role
module "sagemaker_execution_role" {
  source = "../modules/terraform-aws-iam"

  role_name                = "${var.project_name}-sagemaker-execution-role"
  permissions_boundary_arn = var.permissions_boundary_arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "sagemaker.amazonaws.com"
        }
      }
    ]
  })

  # No AWS-managed AmazonSageMakerFullAccess - it grants account-wide sagemaker:*
  # on Resource "*". Replaced with the scoped inline statements below covering
  # exactly what the pipeline + jobs need (least privilege).
  managed_policy_arns = []

  inline_policies = {
    s3_access = jsonencode({
      Version = "2012-10-17"
      Statement = concat([
        {
          Effect = "Allow"
          Action = [
            "s3:GetObject",
            "s3:PutObject",
            "s3:DeleteObject",
            "s3:ListBucket",
            "s3:DeleteObjectVersion",
            "s3:ListBucketVersions"
          ]
          Resource = concat(
            [
              module.s3_raw_data.bucket_arn,
              module.s3_processed_data.bucket_arn,
              module.s3_scripts.bucket_arn,
              module.s3_model_artifacts.bucket_arn,
              module.s3_inference_results.bucket_arn,
              module.s3_monitoring.bucket_arn
            ],
            [
              "${module.s3_raw_data.bucket_arn}/*",
              "${module.s3_processed_data.bucket_arn}/*",
              "${module.s3_scripts.bucket_arn}/*",
              "${module.s3_model_artifacts.bucket_arn}/*",
              "${module.s3_inference_results.bucket_arn}/*",
              "${module.s3_monitoring.bucket_arn}/*"
            ]
          )
        },
        {
          Effect = "Allow"
          Action = [
            "kms:Decrypt",
            "kms:GenerateDataKey",
            "kms:DescribeKey"
          ]
          Resource = [module.kms.key_arn]
        },
        {
          # Jobs encrypt their ML storage volumes with the project CMK
          # (VolumeKmsKeyId), which needs a grant for the EBS attachment.
          Effect   = "Allow"
          Action   = ["kms:CreateGrant"]
          Resource = [module.kms.key_arn]
          Condition = {
            Bool = { "kms:GrantIsForAWSResource" = "true" }
          }
        },
        {
          Effect = "Allow"
          Action = [
            "logs:CreateLogGroup",
            "logs:CreateLogStream",
            "logs:PutLogEvents"
          ]
          Resource = "arn:aws:logs:*:*:*"
        },
        {
          Effect = "Allow"
          Action = [
            "cloudwatch:PutMetricData"
          ]
          Resource = "*"
        },
        {
          Effect = "Allow"
          Action = [
            "ecr:GetAuthorizationToken",
            "ecr:BatchCheckLayerAvailability",
            "ecr:GetDownloadUrlForLayer",
            "ecr:BatchGetImage"
          ]
          Resource = "*"
        },
        {
          Effect = "Allow"
          Action = [
            "ecr:BatchGetImage",
            "ecr:GetDownloadUrlForLayer",
            "ecr:BatchCheckLayerAvailability"
          ]
          Resource = [
            "arn:aws:ecr:*:*:repository/sagemaker-*"
          ]
        },
        {
          # ARN-scoped SageMaker resource operations: models, endpoints,
          # endpoint-configs, pipelines, model packages/groups, monitoring,
          # processing/training/transform jobs - all constrained to this
          # project's name prefix so the role can't touch other teams'
          # SageMaker resources in the account.
          Effect = "Allow"
          Action = [
            "sagemaker:CreateModel",
            "sagemaker:CreateEndpointConfig",
            "sagemaker:CreateEndpoint",
            "sagemaker:UpdateEndpoint",
            "sagemaker:DeleteModel",
            "sagemaker:DeleteEndpointConfig",
            "sagemaker:DeleteEndpoint",
            "sagemaker:DescribeModel",
            "sagemaker:DescribeEndpointConfig",
            "sagemaker:DescribeEndpoint",
            "sagemaker:CreateModelPackage",
            "sagemaker:DescribeModelPackage",
            "sagemaker:UpdateModelPackage",
            "sagemaker:CreateModelPackageGroup",
            "sagemaker:DescribeModelPackageGroup",
            "sagemaker:DescribeProcessingJob",
            "sagemaker:StopProcessingJob",
            "sagemaker:DescribeTrainingJob",
            "sagemaker:StopTrainingJob",
            "sagemaker:DescribeTransformJob",
            "sagemaker:StopTransformJob",
            "sagemaker:DescribePipeline",
            "sagemaker:DescribePipelineExecution",
            "sagemaker:CreateProcessingJob",
            "sagemaker:CreateTrainingJob",
            "sagemaker:CreateTransformJob",
            "sagemaker:AddTags",
            "sagemaker:DeleteTags",
            "sagemaker:ListTags",
          ]
          Resource = [
            "arn:aws:sagemaker:*:*:model/${var.project_name}-*",
            "arn:aws:sagemaker:*:*:endpoint/${var.project_name}-*",
            "arn:aws:sagemaker:*:*:endpoint-config/${var.project_name}-*",
            "arn:aws:sagemaker:*:*:model-package/${var.project_name}-*",
            "arn:aws:sagemaker:*:*:model-package-group/${var.project_name}-*",
            "arn:aws:sagemaker:*:*:pipeline/${var.project_name}-*",
            "arn:aws:sagemaker:*:*:processing-job/*",
            "arn:aws:sagemaker:*:*:training-job/*",
            "arn:aws:sagemaker:*:*:transform-job/*",
            "arn:aws:sagemaker:*:*:experiment/*",
            "arn:aws:sagemaker:*:*:experiment-trial/*",
            "arn:aws:sagemaker:*:*:experiment-trial-component/*",
          ]
        },
        {
          # List/Search and job-creation context actions that AWS does not
          # support resource-level scoping for. Read-only or pre-resource.
          Effect = "Allow"
          Action = [
            "sagemaker:ListModels",
            "sagemaker:ListEndpointConfigs",
            "sagemaker:ListEndpoints",
            "sagemaker:ListModelPackages",
            "sagemaker:ListModelPackageGroups",
            "sagemaker:ListProcessingJobs",
            "sagemaker:ListTrainingJobs",
            "sagemaker:ListPipelineExecutionSteps",
            "sagemaker:Search",
          ]
          Resource = "*"
        },
        {
          Effect = "Allow"
          Action = [
            "iam:PassRole"
          ]
          Resource = "arn:aws:iam::*:role/${var.project_name}-*"
          # Constrain PassRole to SageMaker only - without this condition any
          # principal that can act as this role could pass a project role to
          # any service (confused-deputy / privilege escalation).
          Condition = {
            StringEquals = {
              "iam:PassedToService" = "sagemaker.amazonaws.com"
            }
          }
        },
        {
          Effect = "Allow"
          Action = [
            "application-autoscaling:RegisterScalableTarget",
            "application-autoscaling:DeregisterScalableTarget",
            "application-autoscaling:PutScalingPolicy",
            "application-autoscaling:DeleteScalingPolicy",
            "application-autoscaling:DescribeScalableTargets",
            "application-autoscaling:DescribeScalingPolicies"
          ]
          Resource = "*"
        },
        {
          Effect = "Allow"
          Action = [
            "cloudwatch:PutMetricAlarm",
            "cloudwatch:DeleteAlarms",
            "cloudwatch:DescribeAlarms",
            "cloudwatch:GetMetricStatistics",
            "cloudwatch:ListMetrics"
          ]
          Resource = "*"
        },
        ],
        var.enable_mlflow ? [
          {
            Effect = "Allow"
            Action = [
              "sagemaker-mlflow:AccessUI",
              "sagemaker-mlflow:CreateExperiment",
              "sagemaker-mlflow:CreateRun",
              "sagemaker-mlflow:UpdateRun",
              "sagemaker-mlflow:DeleteRun",
              "sagemaker-mlflow:LogMetric",
              "sagemaker-mlflow:LogParameter"
            ]
            Resource = "arn:aws:sagemaker:*:*:mlflow-tracking-server/${var.project_name}-mlflow"
          }
        ] : [],
        # ENI management for training and processing jobs that run in your
        # VPC (var.vpc_config): the set the SageMaker execution-role
        # documentation lists for VPC jobs.
        var.vpc_config != null ? [
          {
            Effect = "Allow"
            Action = [
              "ec2:CreateNetworkInterface",
              "ec2:CreateNetworkInterfacePermission",
              "ec2:DeleteNetworkInterface",
              "ec2:DeleteNetworkInterfacePermission",
              "ec2:DescribeNetworkInterfaces",
              "ec2:DescribeVpcs",
              "ec2:DescribeDhcpOptions",
              "ec2:DescribeSubnets",
              "ec2:DescribeSecurityGroups"
            ]
            Resource = "*"
          }
        ] : []
      )
    })
  }
}

################################################################################
# SageMaker Model Registry
################################################################################

resource "aws_sagemaker_model_package_group" "medical_image_models" {
  model_package_group_name        = "${var.project_name}-model-package-group"
  model_package_group_description = "Model package group for medical image classification models"
}

# Model Card - documents intended use, risk rating, and clinical context so a
# review board sees the full picture alongside the metrics (Part 2/4). Native
# resource: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sagemaker_model_card
resource "aws_sagemaker_model_card" "medical_image" {
  count = var.enable_model_card ? 1 : 0

  model_card_name   = "${var.project_name}-model-card"
  model_card_status = "Draft"

  content = jsonencode({
    model_overview = {
      model_name        = "${var.project_name}-ensemble"
      model_description = "Weighted-average ensemble (VGG16 + DenseNet121 + EfficientNetV2M) for medical image benign/malignant classification."
      problem_type      = "Binary image classification"
    }
    intended_uses = {
      purpose_of_model                   = "Assist radiologists/pathologists in flagging suspicious medical image findings."
      intended_uses                      = "Primary screening decision support; flags cases for human review. Not for autonomous diagnosis."
      factors_affecting_model_efficiency = "Performance varies by scanner, stain and magnification and may not generalize to images from other sites or datasets. Validate on your own data before use."
      risk_rating                        = var.model_card_risk_rating
      explanations_for_risk_rating       = "Predictions influence clinical decisions; a missed malignant case (false negative) is high-consequence, hence the recall-weighted clinical quality gate."
    }
    additional_information = {
      ethical_considerations      = "Fairness monitored via Fairlearn subgroup bias reports; low-confidence cases route to human review."
      caveats_and_recommendations = "Validate thresholds with your clinical team. Do not deploy without review-board approval (models register as PendingManualApproval)."
    }
  })
}

################################################################################
# MLflow
################################################################################

# Managed MLflow tracking server. Off by default: it is billed for every hour
# it runs, whether or not a pipeline is training.
resource "aws_sagemaker_mlflow_tracking_server" "mlflow" {
  count = var.enable_mlflow ? 1 : 0

  tracking_server_name = "${var.project_name}-mlflow"
  artifact_store_uri   = "s3://${module.s3_model_artifacts.bucket_id}/mlflow-artifacts"
  role_arn             = module.sagemaker_execution_role.role_arn
  tracking_server_size = "Small"

  tags = {
    Name    = "${var.project_name}-mlflow-tracking"
    Purpose = "experiment-tracking"
  }
}

# Keeps an existing server in state when upgrading with enable_mlflow = true.
moved {
  from = aws_sagemaker_mlflow_tracking_server.mlflow
  to   = aws_sagemaker_mlflow_tracking_server.mlflow[0]
}

################################################################################
# SageMaker Pipeline
################################################################################

# SageMaker Pipeline for Medical Image Classification MLOps: validation,
# preprocessing, training, evaluation, ensemble, fairness check, clinical
# quality gate and model registration. The definition lives in
# pipeline.json.tftpl.
locals {
  # Resolves at run time to the execution's ID. Evaluation, ensemble and bias
  # outputs are written under <prefix>/<execution-id>, so every registered
  # model package points at its own weights and reports instead of one key
  # that the next run overwrites.
  execution_id = { Get = "Execution.PipelineExecutionId" }

  # SageMaker rejects VolumeKmsKeyId on instance types with local NVMe
  # instance storage (encrypted by the instance hardware instead): families
  # with a "d" suffix (m5d, c6id, g4dn, p4d) plus g5, g6, g6e, p5 and trn.
  local_storage_instance_regex = "^ml\\.([a-z]+[0-9]+[a-z]*dn?|p4de|g5|g6e?|p5e?n?|trn[12]n?)\\."

  pipeline_vpc_config = var.vpc_config == null ? null : {
    Subnets          = var.vpc_config.subnet_ids
    SecurityGroupIds = var.vpc_config.security_group_ids
  }
}

resource "aws_sagemaker_pipeline" "medical_image_pipeline" {
  pipeline_name         = "${var.project_name}-pipeline"
  pipeline_display_name = "Medical-Image-Classification-Pipeline"
  pipeline_description  = "MLOps pipeline for medical image classification with custom models and built-in preprocessing"
  role_arn              = module.sagemaker_execution_role.role_arn

  # Run the three independent model trainers concurrently instead of serially.
  parallelism_configuration {
    max_parallel_execution_steps = var.pipeline_max_parallel_steps
  }

  pipeline_definition = templatefile("${path.module}/pipeline.json.tftpl", {
    project_name             = var.project_name
    aws_region               = var.aws_region
    role_arn                 = module.sagemaker_execution_role.role_arn
    kms_key_arn              = module.kms.key_arn
    model_package_group_name = aws_sagemaker_model_package_group.medical_image_models.model_package_group_name
    buckets                  = local.base_buckets
    images = {
      tensorflow_cpu       = data.aws_sagemaker_prebuilt_ecr_image.tensorflow_cpu.registry_path
      tensorflow_gpu       = data.aws_sagemaker_prebuilt_ecr_image.tensorflow_gpu.registry_path
      tensorflow_inference = data.aws_sagemaker_prebuilt_ecr_image.tensorflow_inference.registry_path
    }

    steps            = var.pipeline_steps
    models           = var.models
    model_order      = local.model_order
    model_names      = local.model_names
    data_config      = var.data_config
    container_paths  = local.container_paths
    processing_paths = local.processing_paths
    script_paths     = local.script_paths

    training_data_path           = var.training_data_path
    training_input_mode          = var.training_input_mode
    preprocessing_target_size    = var.preprocessing_target_size
    min_images_per_class         = var.min_images_per_class
    enable_managed_spot_training = var.enable_managed_spot_training
    spot_max_wait_buffer_seconds = var.spot_max_wait_buffer_seconds
    training_keep_alive_seconds  = var.training_keep_alive_seconds
    enable_experiments           = var.enable_experiments
    enable_debugger              = var.enable_debugger
    debugger_rule_image          = var.debugger_rule_image
    enable_network_isolation     = var.enable_network_isolation
    vpc_config                   = local.pipeline_vpc_config
    local_storage_instance_regex = local.local_storage_instance_regex

    clinical_quality_gate = var.clinical_quality_gate
    fairness_gate         = var.fairness_gate
    allow_not_evaluable   = var.allow_not_evaluable

    # Defaults for the RetrainingReason, DatasetVersion and CodeCommitSha
    # pipeline parameters.
    retraining_reason = var.retraining_reason
    dataset_version   = var.dataset_version
    code_commit_sha   = var.code_commit_sha

    execution_id          = local.execution_id
    evaluation_output_uri = { Get = "Steps.${var.pipeline_steps.evaluation.step_name}.ProcessingOutputConfig.Outputs['evaluation-results'].S3Output.S3Uri" }
    bias_output_uri       = { Get = "Steps.${var.pipeline_steps.bias.step_name}.ProcessingOutputConfig.Outputs['bias-metrics'].S3Output.S3Uri" }
  })
}
