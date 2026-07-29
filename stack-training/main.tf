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
  tags                    = local.common_tags
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
  tags                = local.common_tags
}

module "s3_processed_data" {
  source = "../modules/terraform-aws-s3"

  bucket_name         = "${var.project_name}-${var.environment}-processed-data-${random_id.bucket_suffix.hex}"
  force_destroy       = var.bucket_defaults.force_destroy
  kms_key_arn         = module.kms.key_arn
  enable_versioning   = var.bucket_defaults.enable_versioning
  block_public_access = var.bucket_defaults.block_public_access
  tags                = local.common_tags
}

module "s3_scripts" {
  source = "../modules/terraform-aws-s3"

  bucket_name         = "${var.project_name}-${var.environment}-scripts-${random_id.bucket_suffix.hex}"
  force_destroy       = var.bucket_defaults.force_destroy
  kms_key_arn         = module.kms.key_arn
  enable_versioning   = var.bucket_defaults.enable_versioning
  block_public_access = var.bucket_defaults.block_public_access
  tags                = local.common_tags
}

module "s3_model_artifacts" {
  source = "../modules/terraform-aws-s3"

  bucket_name         = "${var.project_name}-${var.environment}-model-artifacts-${random_id.bucket_suffix.hex}"
  force_destroy       = var.bucket_defaults.force_destroy
  kms_key_arn         = module.kms.key_arn
  enable_versioning   = var.bucket_defaults.enable_versioning
  block_public_access = var.bucket_defaults.block_public_access
  tags                = local.common_tags
}

module "s3_inference_results" {
  source = "../modules/terraform-aws-s3"

  bucket_name         = "${var.project_name}-${var.environment}-inference-results-${random_id.bucket_suffix.hex}"
  force_destroy       = var.bucket_defaults.force_destroy
  kms_key_arn         = module.kms.key_arn
  enable_versioning   = var.bucket_defaults.enable_versioning
  block_public_access = var.bucket_defaults.block_public_access
  tags                = local.common_tags
}

module "s3_monitoring" {
  source = "../modules/terraform-aws-s3"

  bucket_name         = "${var.project_name}-${var.environment}-monitoring-${random_id.bucket_suffix.hex}"
  force_destroy       = var.bucket_defaults.force_destroy
  kms_key_arn         = module.kms.key_arn
  enable_versioning   = var.bucket_defaults.enable_versioning
  block_public_access = var.bucket_defaults.block_public_access
  tags                = local.common_tags
}

################################################################################
# IAM
################################################################################

# SageMaker execution role
module "sagemaker_execution_role" {
  source = "../modules/terraform-aws-iam"

  role_name = "${var.project_name}-sagemaker-execution-role"
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
      Statement = [
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
            var.sagemaker_model_monitor_image_arn,
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
      ]
    })
  }

  tags = local.common_tags
}

################################################################################
# SageMaker Model Registry
################################################################################

# SageMaker Pipeline
resource "aws_sagemaker_model_package_group" "medical_image_models" {
  model_package_group_name        = "${var.project_name}-model-package-group"
  model_package_group_description = "Model package group for medical image classification models"

  lifecycle {
    prevent_destroy = false
  }
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
      factors_affecting_model_efficiency = "Performance varies by scanner/stain and may not generalize across datasets (in-distribution ~97% vs external BreakHis ~52%)."
      risk_rating                        = var.model_card_risk_rating
      explanations_for_risk_rating       = "Predictions influence clinical decisions; a missed malignant case (false negative) is high-consequence, hence the recall-weighted clinical quality gate."
    }
    additional_information = {
      ethical_considerations      = "Fairness monitored via Clarify/subgroup bias reports; low-confidence cases route to human review (A2I)."
      caveats_and_recommendations = "Validate thresholds with your clinical team. Do not deploy without review-board approval (models register as PendingManualApproval)."
    }
  })

  tags = local.common_tags
}

################################################################################
# MLflow
################################################################################

# MLflow Tracking Server for experiment tracking
resource "aws_sagemaker_mlflow_tracking_server" "mlflow" {
  tracking_server_name = "${var.project_name}-mlflow"
  artifact_store_uri   = "s3://${module.s3_model_artifacts.bucket_id}/mlflow-artifacts"
  role_arn             = module.sagemaker_execution_role.role_arn
  tracking_server_size = "Small"

  tags = {
    Name    = "${var.project_name}-mlflow-tracking"
    Purpose = "experiment-tracking"
  }
}

################################################################################
# SageMaker Pipeline
################################################################################

# Fetch SageMaker prebuilt images dynamically using data sources
data "aws_caller_identity" "current" {}

# SageMaker Pipeline for Medical Image Classification MLOps
# This pipeline includes: validation, preprocessing, training,
# evaluation, ensemble creation, model registration, and deployment
resource "aws_sagemaker_pipeline" "medical_image_pipeline" {
  pipeline_name         = "${var.project_name}-pipeline"
  pipeline_display_name = "Medical-Image-Classification-Pipeline"
  pipeline_description  = "MLOps pipeline for medical image classification with custom models and built-in preprocessing"
  role_arn              = module.sagemaker_execution_role.role_arn

  # Run the three independent model trainers concurrently instead of serially.
  parallelism_configuration {
    max_parallel_execution_steps = var.pipeline_max_parallel_steps
  }

  pipeline_definition = jsonencode({
    Version = "2020-12-01"
    Parameters = [
      {
        Name         = "ModelNames"
        Type         = "String"
        DefaultValue = local.model_names
      },
      {
        Name         = "RetrainingReason"
        Type         = "String"
        DefaultValue = var.retraining_reason
      }
    ]
    Steps = concat(
      [
        # Step 1: Data Validation
        {
          Name = var.pipeline_steps.validation.step_name
          Type = var.pipeline_steps.validation.step_type
          Arguments = {
            ProcessingResources = {
              ClusterConfig = {
                InstanceType   = var.pipeline_steps.validation.instance_type
                InstanceCount  = var.pipeline_steps.validation.instance_count
                VolumeSizeInGB = var.pipeline_steps.validation.volume_size
              }
            }
            AppSpecification = {
              ImageUri = data.aws_sagemaker_prebuilt_ecr_image.sklearn.registry_path
              ContainerEntrypoint = [
                "python3", local.script_paths.validation_script,
                "--input-path", local.processing_paths.input_data,
                "--output-path", local.processing_paths.output
              ]
            }
            ProcessingInputs = [
              {
                InputName = "code"
                S3Input = {
                  S3Uri       = "s3://${local.base_buckets.scripts}/validation/"
                  LocalPath   = "/opt/ml/processing/input/code"
                  S3DataType  = var.data_config.s3_data_type
                  S3InputMode = var.data_config.s3_input_mode
                }
              },
              {
                InputName = "raw-data"
                S3Input = {
                  S3Uri       = "s3://${local.base_buckets.raw_data}/${var.training_data_path}"
                  LocalPath   = "/opt/ml/processing/input/data"
                  S3DataType  = var.data_config.s3_data_type
                  S3InputMode = var.data_config.s3_input_mode
                }
              }
            ]
            ProcessingOutputConfig = {
              Outputs = [
                {
                  OutputName = "validation-report"
                  S3Output = {
                    S3Uri        = "s3://${module.s3_processed_data.bucket_id}/validation-reports/"
                    LocalPath    = "/opt/ml/processing/output"
                    S3UploadMode = var.data_config.s3_upload_mode
                  }
                }
              ]
            }
            RoleArn = module.sagemaker_execution_role.role_arn
            Environment = {
              PROJECT_NAME         = var.project_name
              AWS_DEFAULT_REGION   = var.aws_region
              MIN_IMAGES_PER_CLASS = tostring(var.min_images_per_class)
            }
          }
          CacheConfig = {
            Enabled     = var.pipeline_steps.validation.enable_cache
            ExpireAfter = var.pipeline_steps.validation.cache_expiry
          }
        },
        # Step 2: Data Preprocessing
        {
          Name = var.pipeline_steps.preprocessing.step_name
          Type = var.pipeline_steps.preprocessing.step_type
          Arguments = {
            ProcessingResources = {
              ClusterConfig = {
                InstanceType   = var.pipeline_steps.preprocessing.instance_type
                InstanceCount  = var.pipeline_steps.preprocessing.instance_count
                VolumeSizeInGB = var.pipeline_steps.preprocessing.volume_size
              }
            }
            AppSpecification = {
              ImageUri = data.aws_sagemaker_prebuilt_ecr_image.sklearn.registry_path
              # Install the preprocessing deps (imbalanced-learn for SMOTE,
              # Pillow) before running. A raw ProcessingJob entrypoint does not
              # auto-install requirements.txt the way ScriptProcessor does, and
              # each ContainerEntrypoint string is capped at 256 chars, so the
              # install + run is delegated to a small wrapper script uploaded
              # alongside the preprocessor (run_preprocessing.sh).
              ContainerEntrypoint = ["/bin/sh", "${local.container_paths.code}/run_preprocessing.sh"]
              ContainerArguments = [
                "--input-path", local.processing_paths.input_data,
                "--output-path", local.processing_paths.output,
                "--target-size", tostring(var.preprocessing_target_size),
                "--apply-smote"
              ]
            }
            ProcessingInputs = [
              {
                InputName = "code"
                S3Input = {
                  S3Uri       = "s3://${module.s3_scripts.bucket_id}/preprocessing/"
                  LocalPath   = "/opt/ml/processing/input/code"
                  S3DataType  = var.data_config.s3_data_type
                  S3InputMode = var.data_config.s3_input_mode
                }
              },
              {
                InputName = "raw-data"
                S3Input = {
                  S3Uri       = "s3://${module.s3_raw_data.bucket_id}/${var.training_data_path}"
                  LocalPath   = "/opt/ml/processing/input/data"
                  S3DataType  = var.data_config.s3_data_type
                  S3InputMode = var.data_config.s3_input_mode
                }
              }
            ]
            ProcessingOutputConfig = {
              Outputs = [
                {
                  OutputName = "train-data"
                  S3Output = {
                    S3Uri        = "s3://${module.s3_processed_data.bucket_id}/train/"
                    LocalPath    = "/opt/ml/processing/output/train"
                    S3UploadMode = var.data_config.s3_upload_mode
                  }
                },
                {
                  OutputName = "validation-data"
                  S3Output = {
                    S3Uri        = "s3://${module.s3_processed_data.bucket_id}/validation/"
                    LocalPath    = "/opt/ml/processing/output/validation"
                    S3UploadMode = var.data_config.s3_upload_mode
                  }
                },
                {
                  OutputName = "test-data"
                  S3Output = {
                    S3Uri        = "s3://${module.s3_processed_data.bucket_id}/test/"
                    LocalPath    = "/opt/ml/processing/output/test"
                    S3UploadMode = var.data_config.s3_upload_mode
                  }
                }
              ]
            }
            RoleArn = module.sagemaker_execution_role.role_arn
            Environment = {
              PROJECT_NAME       = var.project_name
              AWS_DEFAULT_REGION = var.aws_region
            }
          }
          CacheConfig = {
            Enabled     = var.pipeline_steps.preprocessing.enable_cache
            ExpireAfter = var.pipeline_steps.preprocessing.cache_expiry
          }
          DependsOn = [var.pipeline_steps.validation.step_name]
        }
      ],
      # Steps 3-6: Model Training
      [
        for model_key in local.model_order : {
          Name = var.models[model_key].step_name
          Type = "Training"
          Arguments = merge(
            # CheckpointConfig only applies to managed-spot training; including
            # it as a null key breaks the pipeline-definition JSON parser, so
            # add the key only when spot is enabled.
            var.enable_managed_spot_training ? {
              CheckpointConfig = {
                S3Uri     = "s3://${local.base_buckets.model_artifacts}/checkpoints/${model_key}/"
                LocalPath = "/opt/ml/checkpoints"
              }
            } : {},
            # SageMaker Experiments: associate each training run with a trial
            # component so runs are tracked/comparable (Part 2). Inside a
            # Pipeline, the experiment+trial are auto-managed from the pipeline
            # execution, so only TrialComponentDisplayName is accepted here
            # (passing ExperimentName is rejected by the pipeline parser).
            var.enable_experiments ? {
              ExperimentConfig = {
                TrialComponentDisplayName = var.models[model_key].step_name
              }
            } : {},
            # SageMaker Debugger built-in rules: surface overfitting and stalled
            # loss within minutes (Part 2). RuleEvaluatorImage is region-specific.
            # Built via list-spread merge (one-element list when enabled, empty
            # otherwise) because a `cond ? {nested-list} : {}` ternary fails
            # Terraform's conditional type-unification at plan time.
            merge([
              for _ in(var.enable_debugger ? [1] : []) : {
                DebugHookConfig = {
                  S3OutputPath = "s3://${local.base_buckets.model_artifacts}/debug-output/${model_key}/"
                }
                DebugRuleConfigurations = [
                  {
                    RuleConfigurationName = "Overfit"
                    RuleEvaluatorImage    = var.debugger_rule_image
                    RuleParameters        = { rule_to_invoke = "Overfit" }
                  },
                  {
                    RuleConfigurationName = "LossNotDecreasing"
                    RuleEvaluatorImage    = var.debugger_rule_image
                    RuleParameters        = { rule_to_invoke = "LossNotDecreasing" }
                  }
                ]
            }]...),
            {
              AlgorithmSpecification = {
                # Pick the CPU or GPU training DLC based on the model's instance
                # type. p-family and g-family are GPU; everything else (c5/m5)
                # uses the CPU image. Lets the pipeline run on CPU when GPU quota
                # is unavailable.
                TrainingImage     = can(regex("^ml\\.(p|g)", var.models[model_key].instance_type)) ? data.aws_sagemaker_prebuilt_ecr_image.tensorflow_gpu.registry_path : data.aws_sagemaker_prebuilt_ecr_image.tensorflow_cpu.registry_path
                TrainingInputMode = var.training_input_mode
                MetricDefinitions = [
                  {
                    Name  = "train_loss"
                    Regex = "Train Loss: ([0-9\\.]+)"
                  },
                  {
                    Name  = "train_accuracy"
                    Regex = "Train Accuracy: ([0-9\\.]+)"
                  },
                  {
                    Name  = "validation_loss"
                    Regex = "Validation Loss: ([0-9\\.]+)"
                  },
                  {
                    Name  = "validation_accuracy"
                    Regex = "Validation Accuracy: ([0-9\\.]+)"
                  }
                ]
              }
              RoleArn = module.sagemaker_execution_role.role_arn
              # The "weights" channel feeds pre-downloaded ImageNet weights for
              # network-isolation mode. It is only added when network isolation
              # is enabled - otherwise the prefix may be empty and
              # CreateTrainingJob fails ("No S3 objects found"). With isolation
              # off, the trainers download ImageNet weights over the network
              # (see resolve_weights_path in scripts/training/_common.py).
              InputDataConfig = concat(
                [
                  {
                    ChannelName = "training"
                    DataSource = {
                      S3DataSource = {
                        S3DataType = var.data_config.s3_data_type
                        S3Uri = {
                          Get = "Steps.${var.pipeline_steps.preprocessing.step_name}.ProcessingOutputConfig.Outputs['train-data'].S3Output.S3Uri"
                        }
                      }
                    }
                    ContentType     = var.data_config.content_type
                    CompressionType = var.data_config.compression_type
                  }
                ],
                var.enable_network_isolation ? [
                  {
                    ChannelName = "weights"
                    DataSource = {
                      S3DataSource = {
                        S3DataType = "S3Prefix"
                        S3Uri      = "s3://${local.base_buckets.scripts}/pretrained-weights/"
                      }
                    }
                  }
                ] : []
              )
              OutputDataConfig = {
                S3OutputPath = "s3://${local.base_buckets.model_artifacts}/models/${model_key}/"
              }
              ResourceConfig = merge(
                {
                  InstanceType   = var.models[model_key].instance_type
                  InstanceCount  = var.models[model_key].instance_count
                  VolumeSizeInGB = var.models[model_key].volume_size
                },
                # Warm pools and managed spot are mutually exclusive ("Spot
                # training job can't retain cluster"), so only request a
                # keep-alive period when spot is disabled.
                (var.training_keep_alive_seconds > 0 && !var.enable_managed_spot_training) ? {
                  KeepAlivePeriodInSeconds = var.training_keep_alive_seconds
                } : {},
              )
              StoppingCondition = merge(
                {
                  MaxRuntimeInSeconds = var.models[model_key].max_runtime
                },
                var.enable_managed_spot_training ? {
                  MaxWaitTimeInSeconds = var.models[model_key].max_runtime + var.spot_max_wait_buffer_seconds
                } : {},
              )
              EnableManagedSpotTraining = var.enable_managed_spot_training
              HyperParameters = merge({
                sagemaker_program          = var.models[model_key].script_name
                sagemaker_submit_directory = "s3://${local.base_buckets.scripts}/training/${var.models[model_key].tar_file}"
              }, var.models[model_key].hyperparameters)
              EnableNetworkIsolation = var.enable_network_isolation
              Environment = {
                PROJECT_NAME       = var.project_name
                AWS_DEFAULT_REGION = var.aws_region
              }
            }
          )
          CacheConfig = {
            Enabled     = var.models[model_key].enable_cache
            ExpireAfter = var.models[model_key].cache_expiry
          }
          DependsOn = [var.pipeline_steps.preprocessing.step_name]
        }
      ],
      [
        # Step 7: Model Evaluation
        {
          Name = var.pipeline_steps.evaluation.step_name
          Type = var.pipeline_steps.evaluation.step_type
          Arguments = {
            ProcessingResources = {
              ClusterConfig = {
                InstanceType   = var.pipeline_steps.evaluation.instance_type
                InstanceCount  = var.pipeline_steps.evaluation.instance_count
                VolumeSizeInGB = var.pipeline_steps.evaluation.volume_size
              }
            }
            AppSpecification = {
              ImageUri = data.aws_sagemaker_prebuilt_ecr_image.tensorflow_cpu.registry_path
              ContainerEntrypoint = [
                "python3", local.script_paths.evaluation_script,
                "--models-path", local.processing_paths.input_models,
                "--data-path", local.processing_paths.input_test,
                "--output-path", local.processing_paths.output
              ]
            }
            ProcessingInputs = concat([
              {
                InputName = "code"
                S3Input = {
                  S3Uri       = "s3://${module.s3_scripts.bucket_id}/evaluation/"
                  LocalPath   = "/opt/ml/processing/input/code"
                  S3DataType  = var.data_config.s3_data_type
                  S3InputMode = var.data_config.s3_input_mode
                }
              },
              {
                InputName = "test-data"
                S3Input = {
                  S3Uri = {
                    Get = "Steps.${var.pipeline_steps.preprocessing.step_name}.ProcessingOutputConfig.Outputs['test-data'].S3Output.S3Uri"
                  }
                  LocalPath   = "/opt/ml/processing/input/data/test"
                  S3DataType  = var.data_config.s3_data_type
                  S3InputMode = var.data_config.s3_input_mode
                }
              }
              ], [
              for model_key in local.model_order : {
                InputName = "${model_key}-model"
                S3Input = {
                  S3Uri = {
                    Get = "Steps.${var.models[model_key].step_name}.ModelArtifacts.S3ModelArtifacts"
                  }
                  LocalPath   = "/opt/ml/processing/input/models/${model_key}"
                  S3DataType  = var.data_config.s3_data_type
                  S3InputMode = var.data_config.s3_input_mode
                }
              }
            ])
            ProcessingOutputConfig = {
              Outputs = [
                {
                  OutputName = "evaluation-results"
                  S3Output = {
                    S3Uri        = "s3://${module.s3_model_artifacts.bucket_id}/evaluation/"
                    LocalPath    = "/opt/ml/processing/output"
                    S3UploadMode = var.data_config.s3_upload_mode
                  }
                }
              ]
            }
            RoleArn = module.sagemaker_execution_role.role_arn
            Environment = {
              PROJECT_NAME       = var.project_name
              AWS_DEFAULT_REGION = var.aws_region
              MODEL_NAMES        = { "Get" : "Parameters.ModelNames" }
            }
          }
          CacheConfig = {
            Enabled     = var.pipeline_steps.evaluation.enable_cache
            ExpireAfter = var.pipeline_steps.evaluation.cache_expiry
          }
          DependsOn = [for key in local.model_order : var.models[key].step_name]
        }
      ],
      [
        # Step 8: Ensemble Creation
        {
          Name = var.pipeline_steps.ensemble.step_name
          Type = var.pipeline_steps.ensemble.step_type
          Arguments = {
            ProcessingResources = {
              ClusterConfig = {
                InstanceType   = var.pipeline_steps.ensemble.instance_type
                InstanceCount  = var.pipeline_steps.ensemble.instance_count
                VolumeSizeInGB = var.pipeline_steps.ensemble.volume_size
              }
            }
            AppSpecification = {
              ImageUri = data.aws_sagemaker_prebuilt_ecr_image.tensorflow_cpu.registry_path
              ContainerEntrypoint = [
                "python3", local.script_paths.ensemble_script,
                "--models-path", local.processing_paths.input_models,
                "--evaluation-path", local.processing_paths.input_eval,
                "--data-path", local.processing_paths.input_test,
                "--output-path", local.processing_paths.output
              ]
            }
            ProcessingInputs = concat([
              {
                InputName = "code"
                S3Input = {
                  S3Uri       = "s3://${module.s3_scripts.bucket_id}/ensemble/"
                  LocalPath   = "/opt/ml/processing/input/code"
                  S3DataType  = var.data_config.s3_data_type
                  S3InputMode = var.data_config.s3_input_mode
                }
              },
              {
                InputName = "test-data"
                S3Input = {
                  S3Uri = {
                    Get = "Steps.${var.pipeline_steps.preprocessing.step_name}.ProcessingOutputConfig.Outputs['test-data'].S3Output.S3Uri"
                  }
                  LocalPath   = "/opt/ml/processing/input/data/test"
                  S3DataType  = var.data_config.s3_data_type
                  S3InputMode = var.data_config.s3_input_mode
                }
              },
              {
                InputName = "evaluation-results"
                S3Input = {
                  S3Uri = {
                    Get = "Steps.${var.pipeline_steps.evaluation.step_name}.ProcessingOutputConfig.Outputs['evaluation-results'].S3Output.S3Uri"
                  }
                  LocalPath   = "/opt/ml/processing/input/evaluation"
                  S3DataType  = var.data_config.s3_data_type
                  S3InputMode = var.data_config.s3_input_mode
                }
              }
              ], [
              for model_key in local.model_order : {
                InputName = "${model_key}-model"
                S3Input = {
                  S3Uri = {
                    Get = "Steps.${var.models[model_key].step_name}.ModelArtifacts.S3ModelArtifacts"
                  }
                  LocalPath   = "/opt/ml/processing/input/models/${model_key}"
                  S3DataType  = var.data_config.s3_data_type
                  S3InputMode = var.data_config.s3_input_mode
                }
              }
            ])
            ProcessingOutputConfig = {
              Outputs = [
                {
                  OutputName = "ensemble-artifacts"
                  S3Output = {
                    S3Uri        = "s3://${module.s3_model_artifacts.bucket_id}/ensemble/"
                    LocalPath    = "/opt/ml/processing/output"
                    S3UploadMode = var.data_config.s3_upload_mode
                  }
                }
              ]
            }
            RoleArn = module.sagemaker_execution_role.role_arn
            Environment = {
              PROJECT_NAME       = var.project_name
              AWS_DEFAULT_REGION = var.aws_region
              MODEL_NAMES        = { "Get" : "Parameters.ModelNames" }
            }
          }
          CacheConfig = {
            Enabled     = var.pipeline_steps.ensemble.enable_cache
            ExpireAfter = var.pipeline_steps.ensemble.cache_expiry
          }
          DependsOn = [var.pipeline_steps.evaluation.step_name]
        },
        # Step 9 : Clinical quality gate. Register only if the ensemble clears
        # ALL of accuracy / recall / precision / AUC. Recall is the highest bar
        # (0.95) because a missed malignant case is the costly error. The
        # condition reads each metric from ensemble_results.json, the same file
        # scripts/ensemble/ensemble_creator.py computes the clinical gate into.
        {
          Name        = "Condition"
          Type        = "Condition"
          DisplayName = "Clinical Quality Gate"
          Arguments = {
            Conditions = [
              {
                Type = "GreaterThanOrEqualTo"
                LeftValue = {
                  "Std:JsonGet" = {
                    Path = "ensemble_accuracy"
                    S3Uri = {
                      "Std:Join" = {
                        On = "",
                        Values = [
                          "s3://${module.s3_model_artifacts.bucket_id}/ensemble/ensemble_results.json"
                        ]
                      }
                    }
                  }
                }
                RightValue = var.clinical_quality_gate.accuracy
              },
              {
                Type = "GreaterThanOrEqualTo"
                LeftValue = {
                  "Std:JsonGet" = {
                    Path = "ensemble_recall"
                    S3Uri = {
                      "Std:Join" = {
                        On = "",
                        Values = [
                          "s3://${module.s3_model_artifacts.bucket_id}/ensemble/ensemble_results.json"
                        ]
                      }
                    }
                  }
                }
                RightValue = var.clinical_quality_gate.recall
              },
              {
                Type = "GreaterThanOrEqualTo"
                LeftValue = {
                  "Std:JsonGet" = {
                    Path = "ensemble_precision"
                    S3Uri = {
                      "Std:Join" = {
                        On = "",
                        Values = [
                          "s3://${module.s3_model_artifacts.bucket_id}/ensemble/ensemble_results.json"
                        ]
                      }
                    }
                  }
                }
                RightValue = var.clinical_quality_gate.precision
              },
              {
                Type = "GreaterThanOrEqualTo"
                LeftValue = {
                  "Std:JsonGet" = {
                    Path = "ensemble_auc"
                    S3Uri = {
                      "Std:Join" = {
                        On = "",
                        Values = [
                          "s3://${module.s3_model_artifacts.bucket_id}/ensemble/ensemble_results.json"
                        ]
                      }
                    }
                  }
                }
                RightValue = var.clinical_quality_gate.auc_roc
              }
            ]
            IfSteps = [{
              Name = var.pipeline_steps.registry.step_name
              Type = var.pipeline_steps.registry.step_type
              Arguments = {
                ModelPackageGroupName = aws_sagemaker_model_package_group.medical_image_models.model_package_group_name
                # Register as PendingManualApproval so a clinical review board
                # (not the pipeline) decides what reaches an endpoint. The
                # auto-deploy Lambda fires on the Approved state change, so the
                # human approval IS the deploy trigger.
                ModelApprovalStatus     = "PendingManualApproval"
                ModelPackageDescription = "Medical image classification ensemble model"

                # Audit-traceability metadata: which retraining reason produced
                # this version and the clinical metrics it cleared. Lets an
                # auditor reconstruct provenance from the registry alone.
                CustomerMetadataProperties = {
                  retraining_reason   = var.retraining_reason
                  accuracy_threshold  = tostring(var.clinical_quality_gate.accuracy)
                  recall_threshold    = tostring(var.clinical_quality_gate.recall)
                  precision_threshold = tostring(var.clinical_quality_gate.precision)
                  auc_threshold       = tostring(var.clinical_quality_gate.auc_roc)
                  project_name        = var.project_name
                  # Data + code lineage (DVC-style) so an auditor can reconstruct
                  # exactly which dataset hash and git commit produced this model
                  # version. Populated from pipeline parameters / CI env.
                  data_version = var.dataset_version
                  code_commit  = var.code_commit_sha
                }

                InferenceSpecification = {
                  Containers = [
                    {
                      Image        = data.aws_sagemaker_prebuilt_ecr_image.tensorflow_inference.registry_path
                      ModelDataUrl = "s3://${module.s3_model_artifacts.bucket_id}/ensemble/model.tar.gz"
                      Environment = {
                        SAGEMAKER_PROGRAM          = "inference.py"
                        SAGEMAKER_SUBMIT_DIRECTORY = "/opt/ml/code"
                      }
                    }
                  ]
                  SupportedContentTypes                   = ["application/json", "image/jpeg", "image/png"]
                  SupportedResponseMIMETypes              = ["application/json"]
                  SupportedRealtimeInferenceInstanceTypes = ["ml.m5.large", "ml.m5.xlarge", "ml.m5.2xlarge"]
                  SupportedTransformInstanceTypes         = ["ml.m5.large", "ml.m5.xlarge"]
                }

                ModelMetrics = {
                  ModelQuality = {
                    Statistics = {
                      ContentType = "application/json"
                      S3Uri       = "s3://${module.s3_model_artifacts.bucket_id}/evaluation/model_quality_statistics.json"
                    }
                    Constraints = {
                      ContentType = "application/json"
                      S3Uri       = "s3://${module.s3_model_artifacts.bucket_id}/evaluation/model_quality_constraints.json"
                    }
                  }

                  ModelDataQuality = {
                    Statistics = {
                      ContentType = "application/json"
                      S3Uri       = "s3://${module.s3_model_artifacts.bucket_id}/evaluation/data_quality_statistics.json"
                    }
                    Constraints = {
                      ContentType = "application/json"
                      S3Uri       = "s3://${module.s3_model_artifacts.bucket_id}/evaluation/data_quality_constraints.json"
                    }
                  }

                  Bias = {
                    Report = {
                      ContentType = "application/json"
                      S3Uri       = "s3://${module.s3_model_artifacts.bucket_id}/evaluation/bias_report.json"
                    }
                    PreTrainingReport = {
                      ContentType = "application/json"
                      S3Uri       = "s3://${module.s3_model_artifacts.bucket_id}/evaluation/data_bias_report.json"
                    }
                  }

                  Explainability = {
                    Report = {
                      ContentType = "application/json"
                      S3Uri       = "s3://${module.s3_model_artifacts.bucket_id}/evaluation/explainability_report.json"
                    }
                  }
                }
              }
              DependsOn = [var.pipeline_steps.ensemble.step_name]
              }
            ]
            ElseSteps = [
              {
                Name        = "Fail"
                Type        = "Fail"
                DisplayName = "Fail Clinical Quality Gate"
                Arguments = {
                  ErrorMessage = "Ensemble did not meet clinical quality gate (accuracy/recall/precision/AUC). See ensemble_results.json clinical_quality_gate for the failing metric and gap."
                }
              }
            ]
          }
          DependsOn = [var.pipeline_steps.ensemble.step_name]
        }
      ]
    )
  })
}
