# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

module "kms" {
  source = "../modules/terraform-aws-kms"

  description          = "KMS key for S3 bucket encryption"
  deletion_window_days = var.kms_deletion_window_days
  enable_key_rotation  = var.enable_kms_key_rotation
  alias_name           = "alias/${var.project_name}-s3-key"
  key_administrators   = var.kms_key_administrators

  # This CMK also encrypts the CloudTrail trail + its CloudWatch log group, so
  # grant the CloudTrail service principal encrypt rights on the key.
  enable_cloudtrail_grant = var.enable_cloudtrail

  # The optional CloudTrail SNS topic is encrypted with this CMK too.
  enable_cloudtrail_sns_grant = var.enable_cloudtrail && var.enable_cloudtrail_sns
  cloudtrail_source_arn       = "arn:aws:cloudtrail:${var.aws_region}:${data.aws_caller_identity.current.account_id}:trail/${var.project_name}-audit-trail"

  # The stack-inference alerts topic is encrypted with this CMK.
  enable_cloudwatch_alarms_grant = true

  # The stack-inference frontend bucket is encrypted with this CMK and read by
  # CloudFront through origin access control.
  enable_cloudfront_grant = true
}

################################################################################
# S3 Buckets
################################################################################

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

locals {
  access_log_bucket_name = "${var.project_name}-${var.environment}-access-logs-${random_id.bucket_suffix.hex}"
  access_log_bucket      = var.enable_s3_access_logging ? module.s3_access_logs[0].bucket_id : null
}

# Server access logs of every project bucket, and the stack-inference
# CloudFront standard logs (v2) under cloudfront/. S3 delivers server access
# logs only to a bucket with SSE-S3 default encryption, hence no CMK on this
# one bucket. The module's TLS-only policy also carries both delivery grants.
module "s3_access_logs" {
  count  = var.enable_s3_access_logging ? 1 : 0
  source = "../modules/terraform-aws-s3"

  bucket_name         = local.access_log_bucket_name
  force_destroy       = var.audit_bucket_force_destroy
  enable_versioning   = true
  block_public_access = true

  policy_statements = [
    {
      Sid       = "S3ServerAccessLogsPolicy"
      Effect    = "Allow"
      Principal = { Service = "logging.s3.amazonaws.com" }
      Action    = "s3:PutObject"
      Resource  = "arn:aws:s3:::${local.access_log_bucket_name}/*"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:s3:::${var.project_name}-*" }
      }
    },
    {
      # CloudFront standard logging (v2) delivery sources live in us-east-1.
      Sid       = "CloudFrontLogDeliveryWrite"
      Effect    = "Allow"
      Principal = { Service = "delivery.logs.amazonaws.com" }
      Action    = "s3:PutObject"
      Resource  = "arn:aws:s3:::${local.access_log_bucket_name}/cloudfront/*"
      Condition = {
        StringEquals = {
          "s3:x-amz-acl"      = "bucket-owner-full-control"
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
        ArnLike = { "aws:SourceArn" = "arn:aws:logs:us-east-1:${data.aws_caller_identity.current.account_id}:delivery-source:${var.project_name}-*" }
      }
    },
    {
      # Without these the delivery service logs AccessDenied in CloudTrail.
      Sid       = "CloudFrontLogDeliveryAclCheck"
      Effect    = "Allow"
      Principal = { Service = "delivery.logs.amazonaws.com" }
      Action    = ["s3:GetBucketAcl", "s3:ListBucket"]
      Resource  = "arn:aws:s3:::${local.access_log_bucket_name}"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:logs:us-east-1:${data.aws_caller_identity.current.account_id}:delivery-source:${var.project_name}-*" }
      }
    },
  ]

  lifecycle_rules = [{
    id                      = "expire-access-logs"
    expiration_days         = var.access_log_retention_days
    noncurrent_version_days = 30
  }]
}

module "s3_raw_data" {
  source = "../modules/terraform-aws-s3"

  logging_target_bucket = local.access_log_bucket
  enable_access_logging = var.enable_s3_access_logging

  bucket_name         = "${var.project_name}-${var.environment}-raw-data-${random_id.bucket_suffix.hex}"
  force_destroy       = var.bucket_defaults.force_destroy
  kms_key_arn         = module.kms.key_arn
  enable_versioning   = var.bucket_defaults.enable_versioning
  block_public_access = var.bucket_defaults.block_public_access
  # Object Created events feed both the pipeline auto-trigger and the upload
  # quarantine (quarantine.tf).
  enable_eventbridge = var.enable_auto_trigger || var.enable_upload_quarantine
}

module "s3_processed_data" {
  source = "../modules/terraform-aws-s3"

  logging_target_bucket = local.access_log_bucket
  enable_access_logging = var.enable_s3_access_logging

  bucket_name         = "${var.project_name}-${var.environment}-processed-data-${random_id.bucket_suffix.hex}"
  force_destroy       = var.bucket_defaults.force_destroy
  kms_key_arn         = module.kms.key_arn
  enable_versioning   = var.bucket_defaults.enable_versioning
  block_public_access = var.bucket_defaults.block_public_access

  # Each execution writes a full copy of the splits under
  # executions/<execution-id>/; expire them once no step can still read them.
  lifecycle_rules = [{
    id                      = "expire-pipeline-executions"
    prefix                  = "executions/"
    expiration_days         = var.processed_data_retention_days
    noncurrent_version_days = 1
  }]
}

module "s3_scripts" {
  source = "../modules/terraform-aws-s3"

  logging_target_bucket = local.access_log_bucket
  enable_access_logging = var.enable_s3_access_logging

  bucket_name         = "${var.project_name}-${var.environment}-scripts-${random_id.bucket_suffix.hex}"
  force_destroy       = var.bucket_defaults.force_destroy
  kms_key_arn         = module.kms.key_arn
  enable_versioning   = var.bucket_defaults.enable_versioning
  block_public_access = var.bucket_defaults.block_public_access
}

module "s3_model_artifacts" {
  source = "../modules/terraform-aws-s3"

  logging_target_bucket = local.access_log_bucket
  enable_access_logging = var.enable_s3_access_logging

  bucket_name         = "${var.project_name}-${var.environment}-model-artifacts-${random_id.bucket_suffix.hex}"
  force_destroy       = var.bucket_defaults.force_destroy
  kms_key_arn         = module.kms.key_arn
  enable_versioning   = var.bucket_defaults.enable_versioning
  block_public_access = var.bucket_defaults.block_public_access
}

module "s3_inference_results" {
  source = "../modules/terraform-aws-s3"

  logging_target_bucket = local.access_log_bucket
  enable_access_logging = var.enable_s3_access_logging

  bucket_name         = "${var.project_name}-${var.environment}-inference-results-${random_id.bucket_suffix.hex}"
  force_destroy       = var.bucket_defaults.force_destroy
  kms_key_arn         = module.kms.key_arn
  enable_versioning   = var.bucket_defaults.enable_versioning
  block_public_access = var.bucket_defaults.block_public_access

  # The inference function writes each uploaded image and its prediction
  # under predictions/<request-id>/.
  lifecycle_rules = [
    {
      id                      = "expire-predictions"
      prefix                  = "predictions/"
      expiration_days         = var.inference_results_retention_days
      noncurrent_version_days = var.inference_results_retention_days
    },
    {
      id                      = "expire-noncurrent-versions"
      noncurrent_version_days = var.inference_results_retention_days
    },
  ]
}

module "s3_monitoring" {
  source = "../modules/terraform-aws-s3"

  logging_target_bucket = local.access_log_bucket
  enable_access_logging = var.enable_s3_access_logging

  bucket_name         = "${var.project_name}-${var.environment}-monitoring-${random_id.bucket_suffix.hex}"
  force_destroy       = var.bucket_defaults.force_destroy
  kms_key_arn         = module.kms.key_arn
  enable_versioning   = var.bucket_defaults.enable_versioning
  block_public_access = var.bucket_defaults.block_public_access
}

################################################################################
# IAM
################################################################################

# Two SageMaker roles. The job role runs the pipeline's Processing and
# Training steps: it reads the scripts and data, writes only the job output
# prefixes and calls no SageMaker API, so code running in a job cannot change
# the pipeline scripts or a model package. The execution role is the pipeline
# role (it starts the jobs with the job role and registers the model package)
# and the role of the MLflow tracking server here and, in stack-inference, of
# the endpoint model, the scheduled drift and fairness jobs and the Amazon A2I
# flow. Neither role can approve a model package or deploy an endpoint: people
# approve with their own credentials, and the deploy and refresh Lambda
# functions in stack-inference have their own roles.
locals {
  # IfExists: the SageMaker confused-deputy guide covers pipelines, jobs and
  # endpoints, not every caller of these roles (the MLflow tracking server).
  sagemaker_assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "sagemaker.amazonaws.com"
        }
        Condition = {
          StringEqualsIfExists = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
          ArnLikeIfExists      = { "aws:SourceArn" = "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*" }
        }
      }
    ]
  })

  # Statements both roles need.
  sagemaker_common_statements = concat([
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
      # Jobs and the endpoint encrypt their ML storage volumes with the
      # project CMK (VolumeKmsKeyId), which needs a grant for the EBS
      # attachment.
      Effect   = "Allow"
      Action   = ["kms:CreateGrant"]
      Resource = [module.kms.key_arn]
      Condition = {
        Bool = { "kms:GrantIsForAWSResource" = "true" }
      }
    },
    {
      # SageMaker jobs and endpoints log to /aws/sagemaker/<JobType>.
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      Resource = [
        "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/sagemaker/*",
        "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/sagemaker/*:log-stream:*",
      ]
    },
    {
      # PutMetricData requires no resource; the namespace condition keeps
      # the jobs to this project's metrics.
      Effect   = "Allow"
      Action   = ["cloudwatch:PutMetricData"]
      Resource = "*"
      Condition = {
        StringLike = { "cloudwatch:namespace" = "${var.project_name}/*" }
      }
    },
    {
      # GetAuthorizationToken has no resource type and supports only "*".
      Effect   = "Allow"
      Action   = ["ecr:GetAuthorizationToken"]
      Resource = "*"
    },
    ],
    # ENI management for jobs that run in a VPC (the training VPC or
    # var.vpc_config): the set the SageMaker execution-role documentation
    # lists for VPC jobs. The documentation says not to scope these with
    # resources or conditions, or the job-creation checks fail, hence
    # Resource "*". The scheduled drift and fairness jobs of stack-inference
    # run in the same subnets with the execution role.
    local.job_vpc_enabled ? [
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
  ] : [])

  mlflow_tracking_server_arn = "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:mlflow-tracking-server/${var.project_name}-mlflow"

  # A prefix URI (the README's folder of <model>.weights.h5 files) or a single
  # file: SageMaker downloads every object under the S3Prefix channel URI, so
  # the grant follows the same prefix.
  backbone_weights_statements = [
    for statement in [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "arn:aws:s3:::${local.backbone_weights.bucket}/${local.backbone_weights.key}*"
      },
      {
        # SageMaker lists the channel URI to resolve the S3Prefix channel.
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${local.backbone_weights.bucket}"
        Condition = {
          StringLike = { "s3:prefix" = "${local.backbone_weights.key}*" }
        }
      },
    ] : statement if var.backbone_weights_s3_uri != ""
  ]
}

module "sagemaker_job_role" {
  source = "../modules/terraform-aws-iam"

  role_name                = "${var.project_name}-sagemaker-job-role"
  description              = "Role of the ${var.project_name} SageMaker pipeline Processing and Training jobs: reads scripts and data, writes the job outputs"
  permissions_boundary_arn = var.permissions_boundary_arn
  assume_role_policy       = local.sagemaker_assume_role_policy

  inline_policies = {
    job_access = jsonencode({
      Version = "2012-10-17"
      Statement = concat(local.sagemaker_common_statements, [
        {
          # Inputs: the step scripts, the raw images, the splits and reports,
          # and the trained models the evaluation steps read.
          Effect = "Allow"
          Action = ["s3:GetObject", "s3:ListBucket"]
          Resource = [
            module.s3_scripts.bucket_arn,
            module.s3_raw_data.bucket_arn,
            module.s3_processed_data.bucket_arn,
            module.s3_model_artifacts.bucket_arn,
            "${module.s3_scripts.bucket_arn}/*",
            "${module.s3_raw_data.bucket_arn}/*",
            "${module.s3_processed_data.bucket_arn}/*",
            "${module.s3_model_artifacts.bucket_arn}/*",
          ]
        },
        {
          # Outputs: the per-execution reports and splits, and the
          # pipeline.json.tftpl output prefixes in the model artifacts bucket.
          # Nothing in the scripts or raw data buckets.
          Effect = "Allow"
          Action = ["s3:PutObject"]
          Resource = [
            "${module.s3_processed_data.bucket_arn}/executions/*",
            "${module.s3_model_artifacts.bucket_arn}/models/*",
            "${module.s3_model_artifacts.bucket_arn}/checkpoints/*",
            "${module.s3_model_artifacts.bucket_arn}/evaluation/*",
            "${module.s3_model_artifacts.bucket_arn}/ensemble/*",
            "${module.s3_model_artifacts.bucket_arn}/bias/*",
            "${module.s3_model_artifacts.bucket_arn}/debug-output/*",
            "${module.s3_model_artifacts.bucket_arn}/baselines/*",
          ]
        },
        {
          # SageMaker deletes a spot-training checkpoint in S3 when the
          # trainer deletes it in the container.
          Effect   = "Allow"
          Action   = ["s3:DeleteObject"]
          Resource = "${module.s3_model_artifacts.bucket_arn}/checkpoints/*"
        },
        {
          # The training images (Deep Learning Containers registry) and the
          # Debugger rule image when Debugger is on.
          Effect = "Allow"
          Action = [
            "ecr:BatchGetImage",
            "ecr:GetDownloadUrlForLayer",
            "ecr:BatchCheckLayerAvailability"
          ]
          Resource = distinct(compact([
            "arn:aws:ecr:${var.aws_region}:${data.aws_sagemaker_prebuilt_ecr_image.tensorflow_cpu.registry_id}:repository/tensorflow-training",
            "arn:aws:ecr:${var.aws_region}:${data.aws_sagemaker_prebuilt_ecr_image.tensorflow_gpu.registry_id}:repository/tensorflow-training",
            var.enable_debugger ? "arn:aws:ecr:${var.aws_region}:${split(".", var.debugger_rule_image)[0]}:repository/*" : "",
          ]))
        },
        ],
        local.backbone_weights_statements,
        # MLflow client calls from the jobs, and the artifacts they log.
        var.enable_mlflow ? [
          {
            Effect = "Allow"
            Action = [
              "sagemaker-mlflow:CreateExperiment",
              "sagemaker-mlflow:GetExperimentByName",
              "sagemaker-mlflow:CreateRun",
              "sagemaker-mlflow:UpdateRun",
              "sagemaker-mlflow:DeleteRun",
              "sagemaker-mlflow:LogMetric",
              "sagemaker-mlflow:LogParam",
              "sagemaker-mlflow:LogBatch"
            ]
            Resource = local.mlflow_tracking_server_arn
          },
          {
            Effect   = "Allow"
            Action   = ["s3:PutObject"]
            Resource = "${module.s3_model_artifacts.bucket_arn}/mlflow-artifacts/*"
          },
        ] : [],
      )
    })
  }
}

module "sagemaker_execution_role" {
  source = "../modules/terraform-aws-iam"

  role_name                = "${var.project_name}-sagemaker-execution-role"
  description              = "Execution role for the ${var.project_name} SageMaker pipeline, the endpoint model, the scheduled monitoring jobs, the A2I flow and the MLflow tracking server"
  permissions_boundary_arn = var.permissions_boundary_arn
  assume_role_policy       = local.sagemaker_assume_role_policy

  # No AWS-managed AmazonSageMakerFullAccess - it grants account-wide sagemaker:*
  # on Resource "*". Replaced with the scoped inline statements below.
  managed_policy_arns = []

  inline_policies = {
    s3_access = jsonencode({
      Version = "2012-10-17"
      Statement = concat(local.sagemaker_common_statements, [
        {
          # The scheduled jobs' scripts, the pipeline's property files and the
          # endpoint's model data, the stored images the A2I task shows, and
          # the monitoring bucket.
          Effect = "Allow"
          Action = ["s3:GetObject", "s3:ListBucket"]
          Resource = [
            module.s3_scripts.bucket_arn,
            module.s3_model_artifacts.bucket_arn,
            module.s3_inference_results.bucket_arn,
            module.s3_monitoring.bucket_arn,
            "${module.s3_scripts.bucket_arn}/*",
            "${module.s3_model_artifacts.bucket_arn}/*",
            "${module.s3_inference_results.bucket_arn}/*",
            "${module.s3_monitoring.bucket_arn}/*",
          ]
        },
        {
          # Endpoint data capture, the fairness reports and the A2I output.
          Effect   = "Allow"
          Action   = ["s3:PutObject"]
          Resource = "${module.s3_monitoring.bucket_arn}/*"
        },
        {
          # The serving image (the Deep Learning Containers image of the
          # model packages, or the patched image in this project's
          # repository) and the scheduled jobs' scikit-learn image.
          Effect = "Allow"
          Action = [
            "ecr:BatchGetImage",
            "ecr:GetDownloadUrlForLayer",
            "ecr:BatchCheckLayerAvailability"
          ]
          Resource = [
            "arn:aws:ecr:${var.aws_region}:${data.aws_sagemaker_prebuilt_ecr_image.tensorflow_inference.registry_id}:repository/tensorflow-inference",
            "arn:aws:ecr:${var.aws_region}:${data.aws_sagemaker_prebuilt_ecr_image.monitoring_jobs.registry_id}:repository/sagemaker-scikit-learn",
            "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${var.project_name}-*",
          ]
        },
        {
          # Pipeline role: start, watch and stop the jobs. Pipeline job names
          # are generated, so job ARNs end in a wildcard; pipeline/<name>-*
          # also covers its executions.
          Effect = "Allow"
          Action = [
            "sagemaker:DescribeModelPackage",
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
            "sagemaker:ListPipelineExecutionSteps",
            "sagemaker:CreateProcessingJob",
            "sagemaker:CreateTrainingJob",
            "sagemaker:CreateTransformJob",
            "sagemaker:AddTags",
            "sagemaker:DeleteTags",
            "sagemaker:ListTags",
          ]
          Resource = [
            "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:model-package/${var.project_name}-*",
            "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:model-package-group/${var.project_name}-*",
            "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:pipeline/${var.project_name}-*",
            "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:processing-job/*",
            "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:training-job/*",
            "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:transform-job/*",
            "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:experiment/*",
            "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:experiment-trial/*",
            "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:experiment-trial-component/*",
          ]
        },
        {
          # Register model packages only as PendingManualApproval, so a
          # person approves every version before the approval rule deploys
          # it.
          Effect = "Allow"
          Action = ["sagemaker:CreateModelPackage"]
          Resource = [
            "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:model-package/${var.project_name}-*",
            "arn:aws:sagemaker:${var.aws_region}:${data.aws_caller_identity.current.account_id}:model-package-group/${var.project_name}-*",
          ]
          Condition = {
            StringEquals = { "sagemaker:ModelApprovalStatus" = "PendingManualApproval" }
          }
        },
        {
          # List and Search calls that have no resource type and support
          # only "*". Read-only.
          Effect = "Allow"
          Action = [
            "sagemaker:ListModelPackages",
            "sagemaker:ListModelPackageGroups",
            "sagemaker:ListProcessingJobs",
            "sagemaker:ListTrainingJobs",
            "sagemaker:Search",
          ]
          Resource = "*"
        },
        {
          # The pipeline hands the job role to its jobs, and only to
          # SageMaker.
          Effect   = "Allow"
          Action   = ["iam:PassRole"]
          Resource = module.sagemaker_job_role.role_arn
          Condition = {
            StringEquals = {
              "iam:PassedToService" = "sagemaker.amazonaws.com"
            }
          }
        },
        ],
        # The MLflow tracking server's artifact store.
        var.enable_mlflow ? [
          {
            Effect   = "Allow"
            Action   = ["s3:PutObject"]
            Resource = "${module.s3_model_artifacts.bucket_arn}/mlflow-artifacts/*"
          }
        ] : [],
      )
    })
  }
}

################################################################################
# SageMaker Model Registry
################################################################################

resource "aws_sagemaker_model_package_group" "image_models" {
  model_package_group_name        = "${var.project_name}-model-package-group"
  model_package_group_description = "Image classification ensemble models for ${var.project_name}"
}

# Model Card - documents intended use and risk rating so a review board sees
# the full picture alongside the metrics (Part 2/4). Native resource:
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sagemaker_model_card
resource "aws_sagemaker_model_card" "image_model" {
  count = var.enable_model_card ? 1 : 0

  model_card_name   = "${var.project_name}-model-card"
  model_card_status = "Draft"

  content = jsonencode({
    model_overview = {
      model_name        = "${var.project_name}-ensemble"
      model_description = "Weighted-average ensemble (VGG16 + DenseNet121 + EfficientNetV2M) for binary image classification (positive class: ${var.positive_class})."
      problem_type      = "Binary image classification"
    }
    intended_uses = {
      purpose_of_model                   = "Flag images of the positive class for human review."
      intended_uses                      = "Decision support; low-confidence predictions go to a human reviewer. Not for fully automated decisions."
      factors_affecting_model_efficiency = "Performance depends on how closely new images match the training data (capture device, lighting, resolution, source). Validate on your own data before use."
      risk_rating                        = var.model_card_risk_rating
      explanations_for_risk_rating       = "A missed positive (false negative) is the costly error, hence the recall-weighted quality gate."
    }
    additional_information = {
      ethical_considerations      = "Fairness is checked with Fairlearn subgroup metrics in the pipeline gate and a scheduled monitoring job; low-confidence predictions are flagged in the API response for human review."
      caveats_and_recommendations = "Set the gate thresholds for your use case. Models register as PendingManualApproval and need an approver before deployment."
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

# SageMaker Pipeline: validation, preprocessing, training, evaluation,
# ensemble, fairness check, quality gate and model registration. The
# definition lives in pipeline.json.tftpl.
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

  # Your own subnets (vpc_config) win; otherwise the training VPC
  # (network.tf); otherwise no VPC.
  job_vpc_enabled = var.vpc_config != null || var.training_vpc_enabled
  pipeline_vpc_config = var.vpc_config != null ? {
    Subnets          = var.vpc_config.subnet_ids
    SecurityGroupIds = var.vpc_config.security_group_ids
    } : var.training_vpc_enabled ? {
    Subnets          = aws_subnet.training[*].id
    SecurityGroupIds = [aws_security_group.training_jobs[0].id]
  } : null

  # Quality gate metric -> the Float pipeline parameter that carries its bar.
  quality_gate_parameters = {
    accuracy  = "AccuracyThreshold"
    auc_roc   = "AucThreshold"
    precision = "PrecisionThreshold"
    recall    = "RecallThreshold"
  }

  # QUALITY_GATE for the evaluation and ensemble steps, built at run time from
  # the Float parameters ({"accuracy": 0.85, ...}); Std:Join stringifies them.
  quality_gate_json = {
    "Std:Join" = {
      On = ""
      Values = flatten([
        "{",
        [
          for i, metric in sort(keys(local.quality_gate_parameters)) : [
            "${i == 0 ? "" : ", "}\"${metric}\": ",
            { Get = "Parameters.${local.quality_gate_parameters[metric]}" },
          ]
        ],
        "}",
      ])
    }
  }

  backbone_weights = {
    bucket = try(regex("^s3://([^/]+)/(.+)$", var.backbone_weights_s3_uri)[0], "")
    key    = try(regex("^s3://([^/]+)/(.+)$", var.backbone_weights_s3_uri)[1], "")
  }
}

resource "aws_sagemaker_pipeline" "image_pipeline" {
  pipeline_name         = "${var.project_name}-pipeline"
  pipeline_display_name = "Image-Classification-Pipeline"
  pipeline_description  = "Validation, preprocessing, training, evaluation, ensemble, fairness and quality gates, and model registration"
  role_arn              = module.sagemaker_execution_role.role_arn

  # Run the three independent model trainers concurrently instead of serially.
  parallelism_configuration {
    max_parallel_execution_steps = var.pipeline_max_parallel_steps
  }

  pipeline_definition = templatefile("${path.module}/pipeline.json.tftpl", {
    project_name             = var.project_name
    aws_region               = var.aws_region
    job_role_arn             = module.sagemaker_job_role.role_arn
    kms_key_arn              = module.kms.key_arn
    model_package_group_name = aws_sagemaker_model_package_group.image_models.model_package_group_name
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

    quality_gate            = var.quality_gate
    quality_gate_parameters = local.quality_gate_parameters
    quality_gate_json       = local.quality_gate_json
    fairness_gate           = var.fairness_gate
    allow_not_evaluable     = var.allow_not_evaluable
    positive_class          = var.positive_class
    backbone_weights_s3_uri = var.backbone_weights_s3_uri

    baseline_cnn = var.baseline_cnn

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
