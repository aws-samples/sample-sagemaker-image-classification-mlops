# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

module "s3_codepipeline_artifacts" {
  source = "../modules/terraform-aws-s3"

  bucket_name       = "${var.project_name}-codepipeline-artifacts"
  enable_versioning = true
  force_destroy     = var.force_destroy_buckets
  kms_key_arn       = data.aws_kms_alias.state.target_key_arn

  tags = local.common_tags
}

################################################################################
# CodeStar Connection
################################################################################

resource "aws_codestarconnections_connection" "github" {
  name          = "${var.project_name}-github"
  provider_type = "GitHub"
}

################################################################################
# CodeBuild Projects
################################################################################

module "codebuild_baseline_model" {
  source = "../modules/terraform-aws-codebuild"

  name               = "${var.project_name}-baseline-model-creation"
  description        = "Creates baseline model if none exists in Model Registry"
  service_role_arn   = module.codebuild_role.role_arn
  build_timeout      = 10
  compute_type       = "BUILD_GENERAL1_SMALL"
  buildspec_path     = "stack-cicd/codebuild/baseline-model-buildspec.yml"
  encryption_key_arn = data.aws_kms_alias.state.target_key_arn
  log_kms_key_arn    = data.aws_kms_alias.state.target_key_arn
  log_retention_days = var.log_retention_days

  environment_variables = concat(local.terraform_environment, [
    { name = "MODEL_PACKAGE_GROUP_NAME", value = local.model_package_group_name },
    { name = "AWS_REGION", value = var.aws_region },
    # Match the DLC used by the inference pipeline so the baseline model
    # references the same image as approved models.
    { name = "DLC_ACCOUNT_ID", value = var.dlc_account_id },
    { name = "INFERENCE_IMAGE_TAG", value = var.inference_image_tag },
  ])

  tags = local.common_tags
}

module "codebuild_training_deploy" {
  source = "../modules/terraform-aws-codebuild"

  name                  = "${var.project_name}-training-deploy"
  service_role_arn      = module.codebuild_role.role_arn
  buildspec_path        = "stack-cicd/codebuild/training-deploy-buildspec.yml"
  encryption_key_arn    = data.aws_kms_alias.state.target_key_arn
  log_kms_key_arn       = data.aws_kms_alias.state.target_key_arn
  log_retention_days    = var.log_retention_days
  environment_variables = local.terraform_environment
  tags                  = local.common_tags
}

module "codebuild_script_upload" {
  source = "../modules/terraform-aws-codebuild"

  name                  = "${var.project_name}-script-upload"
  service_role_arn      = module.codebuild_role.role_arn
  buildspec_path        = "stack-cicd/codebuild/script-upload-buildspec.yml"
  encryption_key_arn    = data.aws_kms_alias.state.target_key_arn
  log_kms_key_arn       = data.aws_kms_alias.state.target_key_arn
  log_retention_days    = var.log_retention_days
  environment_variables = local.terraform_environment
  tags                  = local.common_tags
}

module "codebuild_inference_deploy" {
  source = "../modules/terraform-aws-codebuild"

  name               = "${var.project_name}-inference-deploy"
  service_role_arn   = module.codebuild_role.role_arn
  buildspec_path     = "stack-cicd/codebuild/inference-deploy-buildspec.yml"
  encryption_key_arn = data.aws_kms_alias.state.target_key_arn
  log_kms_key_arn    = data.aws_kms_alias.state.target_key_arn
  log_retention_days = var.log_retention_days
  # The buildspec resolves TF_VAR_model_package_arn from this group.
  environment_variables = concat(local.terraform_environment, [
    { name = "MODEL_PACKAGE_GROUP_NAME", value = local.model_package_group_name },
  ])
  tags = local.common_tags
}

################################################################################
# CodePipeline
################################################################################

resource "aws_codepipeline" "pipeline" {
  name     = "${var.project_name}-pipeline"
  role_arn = module.codepipeline_role.role_arn

  artifact_store {
    location = module.s3_codepipeline_artifacts.bucket_id
    type     = "S3"

    # Encrypt artifacts in the pipeline bucket with the project CMK (same
    # key as CodeBuild projects so a single key policy covers the whole CI/CD).
    encryption_key {
      id   = data.aws_kms_alias.state.target_key_arn
      type = "KMS"
    }
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn        = aws_codestarconnections_connection.github.arn
        FullRepositoryId     = "${var.github_owner}/${var.github_repo}"
        BranchName           = var.github_branch
        OutputArtifactFormat = "CODE_ZIP"
      }
    }
  }

  stage {
    name = "Training-Deploy"

    action {
      name            = "Deploy-Training"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source_output"]

      configuration = {
        ProjectName = module.codebuild_training_deploy.project_name
      }
    }
  }

  stage {
    name = "BaselineModelCreation"

    action {
      name             = "CreateBaselineModel"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["baseline_output"]

      configuration = {
        ProjectName = module.codebuild_baseline_model.project_name
      }
    }
  }

  stage {
    name = "Script-Upload"

    action {
      name            = "Upload-ML-Scripts"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source_output"]

      configuration = {
        ProjectName = module.codebuild_script_upload.project_name
      }
    }
  }

  stage {
    name = "Inference-Deploy"

    # Optional manual approval before touching production inference.
    # Gated on var.require_manual_approval so dev/test pipelines can still
    # fully auto-deploy. When enabled, pipeline execution pauses here until
    # a human approves in the console (or via API).
    dynamic "action" {
      for_each = var.require_manual_approval ? [1] : []
      content {
        name      = "ManualApprovalBeforeInference"
        category  = "Approval"
        owner     = "AWS"
        provider  = "Manual"
        version   = "1"
        run_order = 1

        configuration = {
          NotificationArn = aws_sns_topic.pipeline_approvals[0].arn
          CustomData      = "Review the model card and drift metrics, then approve to roll out to production."
        }
      }
    }

    action {
      name            = "Deploy-Inference-Pipeline"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source_output"]
      run_order       = var.require_manual_approval ? 2 : 1

      configuration = {
        ProjectName = module.codebuild_inference_deploy.project_name
      }
    }
  }
}

################################################################################
# SNS topic for manual-approval notifications
################################################################################

resource "aws_sns_topic" "pipeline_approvals" {
  count = var.require_manual_approval ? 1 : 0

  name = "${var.project_name}-pipeline-approvals"
  # CodePipeline publishes with its service role, whose policy grants the key.
  kms_master_key_id = data.aws_kms_alias.state.target_key_arn
  tags              = local.common_tags
}

resource "aws_sns_topic_subscription" "pipeline_approvals_email" {
  for_each = var.require_manual_approval ? toset(var.approval_notification_emails) : toset([])

  topic_arn = aws_sns_topic.pipeline_approvals[0].arn
  protocol  = "email"
  endpoint  = each.value
}

################################################################################
# IAM
################################################################################

module "codepipeline_role" {
  source = "../modules/terraform-aws-iam"

  role_name   = "${var.project_name}-codepipeline-role"
  description = "Service role for the ${var.project_name} CodePipeline release pipeline"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "codepipeline.amazonaws.com"
        }
        Condition = {
          StringEquals = { "aws:SourceAccount" = local.account_id }
          ArnLike      = { "aws:SourceArn" = "arn:aws:codepipeline:${var.aws_region}:${local.account_id}:${var.project_name}-pipeline" }
        }
      }
    ]
  })

  inline_policies = {
    codepipeline_policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect = "Allow"
          Action = [
            "s3:GetBucketVersioning",
            "s3:GetObject",
            "s3:GetObjectVersion",
            "s3:PutObject"
          ]
          Resource = [
            module.s3_codepipeline_artifacts.bucket_arn,
            "${module.s3_codepipeline_artifacts.bucket_arn}/*"
          ]
        },
        {
          Effect = "Allow"
          Action = [
            "codestar-connections:UseConnection"
          ]
          Resource = aws_codestarconnections_connection.github.arn
        },
        {
          Effect = "Allow"
          Action = [
            "codebuild:BatchGetBuilds",
            "codebuild:StartBuild"
          ]
          Resource = [
            module.codebuild_baseline_model.project_arn,
            module.codebuild_training_deploy.project_arn,
            module.codebuild_script_upload.project_arn,
            module.codebuild_inference_deploy.project_arn
          ]
        },
        {
          Effect   = "Allow"
          Action   = ["sns:Publish"]
          Resource = "arn:aws:sns:${var.aws_region}:${local.account_id}:${var.project_name}-pipeline-approvals"
        },
        {
          # The artifact store and the approvals topic use the state CMK.
          Effect = "Allow"
          Action = [
            "kms:Decrypt",
            "kms:GenerateDataKey*",
            "kms:DescribeKey",
          ]
          Resource = data.aws_kms_alias.state.target_key_arn
        }
      ]
    })
  }

  tags = local.common_tags
}

module "codebuild_role" {
  source = "../modules/terraform-aws-iam"

  role_name   = "${var.project_name}-codebuild-role"
  description = "Service role for the ${var.project_name} CodeBuild projects that run terraform apply for the training and inference stacks"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "codebuild.amazonaws.com"
        }
        Condition = {
          StringEquals = { "aws:SourceAccount" = local.account_id }
          ArnLike      = { "aws:SourceArn" = "arn:aws:codebuild:${var.aws_region}:${local.account_id}:project/${var.project_name}-*" }
        }
      }
    ]
  })

  tags = local.common_tags
}

################################################################################
# CodeBuild permissions
################################################################################

# CodeBuild runs `terraform apply` against the training and inference
# roots plus the baseline-model script, so it needs create, update and
# delete on project resources. Every statement is scoped to project-prefixed
# ARNs where the service supports resource-level permissions; actions that
# only accept "*" are isolated into their own statements.
#
# The statements are grouped into a few customer managed policies because the
# combined size exceeds the 10,240-character limit for a role's inline
# policies. Policy names use the <project_name>-ci- prefix, which the IAM
# statements deny CodeBuild from changing.
locals {
  codebuild_statements = {
    # --- CloudWatch Logs: CodeBuild's own log group + Lambda log groups -------
    logs = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
          "logs:PutRetentionPolicy",
          "logs:DeleteLogGroup",
          "logs:TagResource",
          "logs:UntagResource",
          "logs:ListTagsForResource",
          "logs:PutMetricFilter",
          "logs:DeleteMetricFilter",
          "logs:DescribeMetricFilters",
        ]
        Resource = [
          "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/codebuild/${var.project_name}-*",
          "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/codebuild/${var.project_name}-*:*",
          "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/lambda/${var.project_name}-*",
          "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/lambda/${var.project_name}-*:*",
          # The two SageMaker job log groups stack-training manages when
          # enable_training_monitoring is on.
          "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/sagemaker/ProcessingJobs",
          "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/sagemaker/ProcessingJobs:*",
          "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/sagemaker/TrainingJobs",
          "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/sagemaker/TrainingJobs:*",
          "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/apigateway/${var.project_name}-*",
          "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/apigateway/${var.project_name}-*:*",
          "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/cloudtrail/${var.project_name}",
          "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/cloudtrail/${var.project_name}:*",
          # WAF requires the aws-waf-logs- prefix on its log group.
          "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:aws-waf-logs-${var.project_name}-*",
          "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:aws-waf-logs-${var.project_name}-*:*",
        ]
      },
      {
        # WAF web ACL logging to CloudWatch Logs: the log delivery and log
        # resource policy calls the AWS WAF guide lists; none of them support
        # resource-level permissions.
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups",
        ]
        Resource = "*"
      },
    ]

    # --- S3: project buckets + Terraform state bucket ------------------------
    s3 = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:GetBucketVersioning",
          "s3:GetBucketPolicy",
          "s3:GetBucketAcl",
          "s3:GetBucketTagging",
          "s3:GetBucketLogging",
          "s3:GetBucketNotification",
          "s3:GetEncryptionConfiguration",
          "s3:GetLifecycleConfiguration",
          "s3:GetBucketPublicAccessBlock",
          "s3:GetBucketOwnershipControls",
          "s3:GetBucketCORS",
          "s3:GetBucketRequestPayment",
          "s3:GetBucketWebsite",
          "s3:GetReplicationConfiguration",
          "s3:GetAccelerateConfiguration",
          "s3:PutBucketVersioning",
          "s3:PutBucketPolicy",
          "s3:PutBucketTagging",
          "s3:PutBucketLogging",
          "s3:PutBucketNotification",
          "s3:PutEncryptionConfiguration",
          "s3:PutLifecycleConfiguration",
          "s3:PutBucketPublicAccessBlock",
          "s3:PutBucketOwnershipControls",
          "s3:PutBucketCORS",
          "s3:CreateBucket",
          "s3:DeleteBucket",
          "s3:DeleteBucketPolicy",
        ]
        Resource = [
          "arn:aws:s3:::${var.project_name}-*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:GetObjectTagging",
          "s3:GetObjectAcl",
          "s3:PutObject",
          "s3:PutObjectTagging",
          "s3:PutObjectAcl",
          "s3:DeleteObject",
          "s3:DeleteObjectVersion",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = [
          "arn:aws:s3:::${var.project_name}-*/*",
        ]
      },
      {
        # Bucket names are global, so the project prefix must not reach a
        # bucket of the same name in another account.
        Effect = "Deny"
        Action = ["s3:*"]
        Resource = [
          "arn:aws:s3:::${var.project_name}-*",
          "arn:aws:s3:::${var.project_name}-*/*",
        ]
        Condition = {
          StringNotEqualsIfExists = { "s3:ResourceAccount" = local.account_id }
        }
      },
      {
        # The Terraform state of the training and inference stacks, in the
        # bucket stack-backend-setup owns: what the S3 backend needs (list,
        # read and write the state, delete the use_lockfile lock files).
        Sid      = "TerraformStateBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${var.state_bucket_name}"
      },
      {
        Sid    = "TerraformStateObjects"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject"]
        Resource = [
          "arn:aws:s3:::${var.state_bucket_name}/training/*",
          "arn:aws:s3:::${var.state_bucket_name}/inference/*",
        ]
      },
      {
        Sid    = "TerraformStateLocks"
        Effect = "Allow"
        Action = ["s3:DeleteObject"]
        Resource = [
          "arn:aws:s3:::${var.state_bucket_name}/training/*.tflock",
          "arn:aws:s3:::${var.state_bucket_name}/inference/*.tflock",
        ]
      },
      {
        # The default state bucket name also matches <project_name>-*, so the
        # statements above could otherwise administer it, purge state
        # history or rewrite this stack's own state.
        Sid    = "DenyStateBucketAdministration"
        Effect = "Deny"
        Action = [
          "s3:CreateBucket",
          "s3:DeleteBucket",
          "s3:DeleteBucketPolicy",
          "s3:PutBucketCORS",
          "s3:PutBucketLogging",
          "s3:PutBucketNotification",
          "s3:PutBucketOwnershipControls",
          "s3:PutBucketPolicy",
          "s3:PutBucketPublicAccessBlock",
          "s3:PutBucketTagging",
          "s3:PutBucketVersioning",
          "s3:PutEncryptionConfiguration",
          "s3:PutLifecycleConfiguration",
        ]
        Resource = "arn:aws:s3:::${var.state_bucket_name}"
      },
      {
        Sid    = "DenyStateHistoryChanges"
        Effect = "Deny"
        Action = [
          "s3:DeleteObjectVersion",
          "s3:PutObjectAcl",
        ]
        Resource = "arn:aws:s3:::${var.state_bucket_name}/*"
      },
      {
        Sid    = "DenyStateFileDeletes"
        Effect = "Deny"
        Action = ["s3:DeleteObject"]
        Resource = [
          "arn:aws:s3:::${var.state_bucket_name}/*.tfstate",
          "arn:aws:s3:::${var.state_bucket_name}/cicd/*",
        ]
      },
      {
        Sid      = "DenyCicdStateWrites"
        Effect   = "Deny"
        Action   = ["s3:PutObject"]
        Resource = "arn:aws:s3:::${var.state_bucket_name}/cicd/*"
      },
      {
        Effect = "Allow"
        # ListAllMyBuckets is required by several buildspecs to discover
        # dynamically-named buckets (e.g. data_uploader.sh, baseline-model
        # buildspec). Only supports "*" per IAM docs.
        Action   = ["s3:ListAllMyBuckets"]
        Resource = "*"
      },
    ]

    # --- SageMaker: pipelines, endpoints, models, model registry -------------
    sagemaker = [
      {
        Effect = "Allow"
        Action = [
          "sagemaker:CreatePipeline",
          "sagemaker:UpdatePipeline",
          "sagemaker:DeletePipeline",
          "sagemaker:DescribePipeline",
          "sagemaker:StartPipelineExecution",
          "sagemaker:StopPipelineExecution",
          "sagemaker:CreateModel",
          "sagemaker:DeleteModel",
          "sagemaker:DescribeModel",
          "sagemaker:CreateEndpoint",
          "sagemaker:UpdateEndpoint",
          "sagemaker:DeleteEndpoint",
          "sagemaker:DescribeEndpoint",
          "sagemaker:CreateEndpointConfig",
          "sagemaker:DeleteEndpointConfig",
          "sagemaker:DescribeEndpointConfig",
          "sagemaker:CreateModelPackageGroup",
          "sagemaker:DeleteModelPackageGroup",
          "sagemaker:DescribeModelPackageGroup",
          "sagemaker:DescribeModelPackage",
          "sagemaker:CreateMlflowTrackingServer",
          "sagemaker:UpdateMlflowTrackingServer",
          "sagemaker:DeleteMlflowTrackingServer",
          "sagemaker:DescribeMlflowTrackingServer",
          "sagemaker:AddTags",
          "sagemaker:DeleteTags",
          "sagemaker:ListTags",
        ]
        Resource = [
          "arn:aws:sagemaker:*:*:pipeline/${var.project_name}-*",
          "arn:aws:sagemaker:*:*:model/${var.project_name}-*",
          "arn:aws:sagemaker:*:*:endpoint/${var.project_name}-*",
          "arn:aws:sagemaker:*:*:endpoint-config/${var.project_name}-*",
          "arn:aws:sagemaker:*:*:model-package-group/${var.project_name}-*",
          "arn:aws:sagemaker:*:*:model-package/${var.project_name}-*/*",
          "arn:aws:sagemaker:*:*:mlflow-tracking-server/${var.project_name}-*",
        ]
      },
      {
        # The baseline build registers its placeholder only as
        # PendingManualApproval; a person approves it.
        Effect = "Allow"
        Action = ["sagemaker:CreateModelPackage"]
        Resource = [
          "arn:aws:sagemaker:${var.aws_region}:${local.account_id}:model-package-group/${var.project_name}-*",
          "arn:aws:sagemaker:${var.aws_region}:${local.account_id}:model-package/${var.project_name}-*/*",
        ]
        Condition = {
          StringEquals = { "sagemaker:ModelApprovalStatus" = "PendingManualApproval" }
        }
      },
      {
        Effect = "Allow"
        # List* operations don't support ARN-level IAM and are read-only.
        Action = [
          "sagemaker:ListPipelines",
          "sagemaker:ListModels",
          "sagemaker:ListEndpoints",
          "sagemaker:ListEndpointConfigs",
          "sagemaker:ListModelPackageGroups",
          "sagemaker:ListModelPackages",
          "sagemaker:ListMlflowTrackingServers",
          "sagemaker:ListModelCards",
        ]
        Resource = "*"
      },
      {
        # The awscc_sagemaker_model_package data source in the endpoint module
        # reads the approved package through Cloud Control, which calls
        # sagemaker:DescribeModelPackage (granted above) on the caller's behalf.
        Effect   = "Allow"
        Action   = ["cloudformation:GetResource"]
        Resource = "*"
      },
      {
        # Model card for the model package group (stack-training, on by
        # default through enable_model_card).
        Effect = "Allow"
        Action = [
          "sagemaker:CreateModelCard",
          "sagemaker:DescribeModelCard",
          "sagemaker:UpdateModelCard",
          "sagemaker:DeleteModelCard",
          "sagemaker:ListModelCardVersions",
          "sagemaker:AddTags",
          "sagemaker:DeleteTags",
          "sagemaker:ListTags",
        ]
        Resource = [
          "arn:aws:sagemaker:*:*:model-card/${var.project_name}-*",
        ]
      },
      {
        # EventBridge Scheduler schedules for the drift and fairness
        # Processing jobs (stack-inference/monitoring.tf). These four actions
        # all take the `schedule` resource type, whose ARN embeds the schedule
        # group; the schedules live in the account's default group. The
        # iam:PassRole that CreateSchedule/UpdateSchedule also require is
        # granted below, gated on iam:PassedToService.
        Effect = "Allow"
        Action = [
          "scheduler:CreateSchedule",
          "scheduler:UpdateSchedule",
          "scheduler:DeleteSchedule",
          "scheduler:GetSchedule",
        ]
        Resource = [
          "arn:aws:scheduler:*:*:schedule/default/${var.project_name}-*",
        ]
      },
      {
        # ListSchedules does not support ARN-level IAM and is read-only.
        Effect   = "Allow"
        Action   = ["scheduler:ListSchedules"]
        Resource = "*"
      },
    ]

    # --- IAM: create/manage project roles and policies -----------------------
    # Guardrails against privilege escalation through this role:
    #   - every role write requires the workload permissions boundary, so a
    #     role CodeBuild creates or edits can never exceed it;
    #   - AttachRolePolicy is limited to an allowlist of policy ARNs;
    #   - the CI/CD roles, their ci- policies and the boundary are denied.
    iam = [
      {
        Sid    = "ManageProjectRoles"
        Effect = "Allow"
        Action = [
          "iam:GetRole",
          "iam:GetRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:ListInstanceProfilesForRole",
          "iam:ListRoleTags",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:UpdateRole",
          "iam:DeleteRole",
        ]
        Resource = [
          "arn:aws:iam::${local.account_id}:role/${var.project_name}-*",
        ]
      },
      {
        Sid    = "WriteBoundedProjectRoles"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:UpdateAssumeRolePolicy",
          "iam:PutRolePermissionsBoundary",
        ]
        Resource = [
          "arn:aws:iam::${local.account_id}:role/${var.project_name}-*",
        ]
        Condition = {
          StringEquals = {
            "iam:PermissionsBoundary" = data.aws_iam_policy.workload_boundary.arn
          }
        }
      },
      {
        Sid    = "AttachAllowlistedPolicies"
        Effect = "Allow"
        Action = [
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
        ]
        Resource = [
          "arn:aws:iam::${local.account_id}:role/${var.project_name}-*",
        ]
        Condition = {
          StringEquals = {
            "iam:PermissionsBoundary" = data.aws_iam_policy.workload_boundary.arn
          }
          ArnLike = {
            "iam:PolicyARN" = local.attachable_policy_arns
          }
        }
      },
      {
        Sid    = "ManageProjectPolicies"
        Effect = "Allow"
        Action = [
          "iam:CreatePolicy",
          "iam:DeletePolicy",
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:CreatePolicyVersion",
          "iam:DeletePolicyVersion",
          "iam:ListPolicyVersions",
          "iam:TagPolicy",
          "iam:UntagPolicy",
        ]
        Resource = [
          "arn:aws:iam::${local.account_id}:policy/${var.project_name}-*",
        ]
      },
      {
        Sid    = "PassProjectRoles"
        Effect = "Allow"
        # PassRole hands project roles to SageMaker, Lambda, API Gateway,
        # EventBridge and the other consuming services during apply.
        Action = ["iam:PassRole"]
        Resource = [
          "arn:aws:iam::${local.account_id}:role/${var.project_name}-*",
        ]
        Condition = {
          StringEquals = {
            "iam:PassedToService" = [
              "sagemaker.amazonaws.com",
              "lambda.amazonaws.com",
              "apigateway.amazonaws.com",
              "events.amazonaws.com",
              "application-autoscaling.amazonaws.com",
              "codebuild.amazonaws.com",
              "cloudtrail.amazonaws.com",
              "sns.amazonaws.com",
              # CreateSchedule / UpdateSchedule require PassRole for the role
              # the schedule's target assumes (the drift and fairness
              # Processing job schedulers).
              "scheduler.amazonaws.com",
              "vpc-flow-logs.amazonaws.com",
            ]
          }
        }
      },
      {
        Sid    = "DenyCiRoleChanges"
        Effect = "Deny"
        Action = [
          "iam:AttachRolePolicy",
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:DeleteRolePermissionsBoundary",
          "iam:DeleteRolePolicy",
          "iam:DetachRolePolicy",
          "iam:PassRole",
          "iam:PutRolePermissionsBoundary",
          "iam:PutRolePolicy",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:UpdateAssumeRolePolicy",
          "iam:UpdateRole",
        ]
        Resource = local.ci_role_arns
      },
      {
        Sid    = "DenyBoundaryAndCiPolicyChanges"
        Effect = "Deny"
        Action = [
          "iam:CreatePolicyVersion",
          "iam:DeletePolicy",
          "iam:DeletePolicyVersion",
          "iam:SetDefaultPolicyVersion",
          "iam:TagPolicy",
          "iam:UntagPolicy",
        ]
        Resource = [
          data.aws_iam_policy.workload_boundary.arn,
          "arn:aws:iam::${local.account_id}:policy/${var.project_name}-ci-*",
        ]
      },
      {
        # Neither the CI/CD policies nor the boundary may be attached as a
        # role's permissions policy.
        Sid      = "DenyAttachingCiPoliciesAndBoundary"
        Effect   = "Deny"
        Action   = ["iam:AttachRolePolicy"]
        Resource = "*"
        Condition = {
          ArnLike = {
            "iam:PolicyARN" = [
              "arn:aws:iam::${local.account_id}:policy/${var.project_name}-ci-*",
              data.aws_iam_policy.workload_boundary.arn,
            ]
          }
        }
      },
      {
        Sid    = "DenyBoundaryRemoval"
        Effect = "Deny"
        Action = ["iam:DeleteRolePermissionsBoundary"]
        Resource = [
          "arn:aws:iam::${local.account_id}:role/${var.project_name}-*",
        ]
      },
      {
        Sid    = "AccountReads"
        Effect = "Allow"
        # Account-level reads; they support only "*".
        Action = [
          "iam:GetAccountSummary",
          "iam:ListAccountAliases",
        ]
        Resource = "*"
      },
    ]

    # --- KMS: project keys ---------------------------------------------------
    # Project keys are found by their Project tag (provider default_tags):
    # key IDs are not known when the policy is written. Tagging is limited so
    # the role cannot bring another key under these statements: it may tag a
    # key only while the key has no Project tag (a key it is creating) or
    # already carries this project's, never set Project to another value, and
    # use only the tag keys the stacks set.
    kms = [
      {
        Sid    = "CreateProjectKeys"
        Effect = "Allow"
        # CreateKey has no resource type; the request must carry the tag.
        Action   = ["kms:CreateKey"]
        Resource = "*"
        Condition = {
          StringEquals                = { "aws:RequestTag/Project" = var.project_name }
          "ForAllValues:StringEquals" = { "aws:TagKeys" = local.resource_tag_keys }
        }
      },
      {
        # The tags sent with CreateKey: KMS requires TagResource in an IAM
        # policy that is not restricted to particular keys.
        Sid      = "TagNewProjectKeys"
        Effect   = "Allow"
        Action   = ["kms:TagResource"]
        Resource = "arn:aws:kms:${var.aws_region}:${local.account_id}:key/*"
        Condition = {
          Null                        = { "aws:ResourceTag/Project" = "true" }
          StringEquals                = { "aws:RequestTag/Project" = var.project_name }
          "ForAllValues:StringEquals" = { "aws:TagKeys" = local.resource_tag_keys }
        }
      },
      {
        Sid      = "RetagProjectKeys"
        Effect   = "Allow"
        Action   = ["kms:TagResource"]
        Resource = "arn:aws:kms:${var.aws_region}:${local.account_id}:key/*"
        Condition = {
          StringEquals                = { "aws:ResourceTag/Project" = var.project_name }
          StringEqualsIfExists        = { "aws:RequestTag/Project" = var.project_name }
          "ForAllValues:StringEquals" = { "aws:TagKeys" = local.resource_tag_keys }
        }
      },
      {
        Sid    = "ManageProjectKeys"
        Effect = "Allow"
        Action = [
          "kms:CreateAlias",
          "kms:DeleteAlias",
          "kms:UpdateAlias",
          "kms:DescribeKey",
          "kms:EnableKey",
          "kms:DisableKey",
          "kms:EnableKeyRotation",
          "kms:DisableKeyRotation",
          "kms:GetKeyRotationStatus",
          "kms:GetKeyPolicy",
          "kms:PutKeyPolicy",
          "kms:ScheduleKeyDeletion",
          "kms:CancelKeyDeletion",
          "kms:UntagResource",
          "kms:ListResourceTags",
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:ReEncryptFrom",
          "kms:ReEncryptTo",
          "kms:CreateGrant",
        ]
        Resource = "arn:aws:kms:${var.aws_region}:${local.account_id}:key/*"
        Condition = {
          StringEquals = { "aws:ResourceTag/Project" = var.project_name }
        }
      },
      {
        # The alias half of CreateAlias/DeleteAlias/UpdateAlias; aliases
        # carry no tags.
        Sid      = "ManageProjectAliases"
        Effect   = "Allow"
        Action   = ["kms:CreateAlias", "kms:DeleteAlias", "kms:UpdateAlias"]
        Resource = "arn:aws:kms:${var.aws_region}:${local.account_id}:alias/${var.project_name}-*"
      },
      {
        # The state key, by its ARN: the Terraform state, the artifact store,
        # the CodeBuild output and logs and the approvals topic.
        Sid    = "UseStateKey"
        Effect = "Allow"
        Action = [
          "kms:DescribeKey",
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
        ]
        Resource = data.aws_kms_alias.state.target_key_arn
      },
      {
        # The state key also carries the Project tag (stack-backend-setup
        # default_tags), so nothing above may change it or its alias.
        Sid    = "DenyStateKeyAdministration"
        Effect = "Deny"
        Action = [
          "kms:CreateAlias",
          "kms:CreateGrant",
          "kms:DeleteAlias",
          "kms:DisableKey",
          "kms:DisableKeyRotation",
          "kms:PutKeyPolicy",
          "kms:ScheduleKeyDeletion",
          "kms:TagResource",
          "kms:UntagResource",
          "kms:UpdateAlias",
        ]
        Resource = [
          data.aws_kms_alias.state.target_key_arn,
          data.aws_kms_alias.state.arn,
        ]
      },
      {
        # ListKeys and ListAliases have no resource type and support only "*".
        Sid    = "ListKeys"
        Effect = "Allow"
        Action = [
          "kms:ListKeys",
          "kms:ListAliases",
        ]
        Resource = "*"
      },
    ]

    # --- Lambda: project functions + layers ----------------------------------
    lambda = [
      {
        Effect = "Allow"
        Action = [
          "lambda:CreateFunction",
          "lambda:UpdateFunctionCode",
          "lambda:UpdateFunctionConfiguration",
          "lambda:DeleteFunction",
          "lambda:GetFunction",
          "lambda:GetFunctionCodeSigningConfig",
          "lambda:AddPermission",
          "lambda:RemovePermission",
          "lambda:GetPolicy",
          "lambda:InvokeFunction",
          "lambda:TagResource",
          "lambda:UntagResource",
          "lambda:ListTags",
          "lambda:PublishLayerVersion",
          "lambda:DeleteLayerVersion",
          "lambda:GetLayerVersion",
          "lambda:ListLayerVersions",
        ]
        Resource = [
          "arn:aws:lambda:*:*:function:${var.project_name}-*",
          "arn:aws:lambda:*:*:layer:${var.project_name}-*",
          "arn:aws:lambda:*:*:layer:${var.project_name}-*:*",
        ]
      },
    ]

    # --- API Gateway ---------------------------------------------------------
    # REST API, key and usage plan IDs are generated, so writes are scoped by
    # the Project tag: creation must send it, and changes need it on the
    # resource. Stages, deployments, methods and the other children inherit
    # their REST API's tags for this check, usage plan keys their usage
    # plan's (API Gateway tagging guide).
    apigateway = [
      {
        Effect   = "Allow"
        Action   = ["apigateway:GET"]
        Resource = ["arn:aws:apigateway:${var.aws_region}::/*"]
      },
      {
        Effect = "Allow"
        Action = ["apigateway:POST"]
        Resource = [
          "arn:aws:apigateway:${var.aws_region}::/restapis",
          "arn:aws:apigateway:${var.aws_region}::/apikeys",
          "arn:aws:apigateway:${var.aws_region}::/usageplans",
        ]
        Condition = {
          StringEquals                = { "aws:RequestTag/Project" = var.project_name }
          "ForAllValues:StringEquals" = { "aws:TagKeys" = local.resource_tag_keys }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "apigateway:POST",
          "apigateway:PUT",
          "apigateway:PATCH",
          "apigateway:DELETE",
          # Associating the WAF web ACL with the stage.
          "apigateway:SetWebACL",
        ]
        Resource = [
          "arn:aws:apigateway:${var.aws_region}::/restapis/*",
          "arn:aws:apigateway:${var.aws_region}::/apikeys/*",
          "arn:aws:apigateway:${var.aws_region}::/usageplans/*",
        ]
        Condition = {
          StringEquals = { "aws:ResourceTag/Project" = var.project_name }
        }
      },
      {
        # Tag updates: the tags resource supports no aws:ResourceTag, so only
        # this project's Project tag and the stacks' tag keys may be set.
        Effect   = "Allow"
        Action   = ["apigateway:PUT"]
        Resource = ["arn:aws:apigateway:${var.aws_region}::/tags/*"]
        Condition = {
          StringEquals                = { "aws:RequestTag/Project" = var.project_name }
          "ForAllValues:StringEquals" = { "aws:TagKeys" = local.resource_tag_keys }
        }
      },
      {
        # The account-wide API Gateway setting (its CloudWatch Logs role),
        # which has no tags.
        Effect   = "Allow"
        Action   = ["apigateway:PATCH"]
        Resource = ["arn:aws:apigateway:${var.aws_region}::/account"]
      },
    ]

    # --- WAF: regional web ACL on the API stage ------------------------------
    waf = [
      {
        Effect = "Allow"
        Action = [
          "wafv2:CreateWebACL",
          "wafv2:UpdateWebACL",
          "wafv2:DeleteWebACL",
          "wafv2:GetWebACL",
          "wafv2:GetWebACLForResource",
          "wafv2:AssociateWebACL",
          "wafv2:DisassociateWebACL",
          "wafv2:PutLoggingConfiguration",
          "wafv2:DeleteLoggingConfiguration",
          "wafv2:GetLoggingConfiguration",
          "wafv2:TagResource",
          "wafv2:UntagResource",
          "wafv2:ListTagsForResource",
        ]
        # CreateWebACL and UpdateWebACL also authorize the AWS managed rule
        # groups the ACL references; AssociateWebACL also authorizes the stage.
        Resource = [
          "arn:aws:wafv2:*:*:regional/webacl/${var.project_name}-*/*",
          "arn:aws:wafv2:*:*:regional/managedruleset/*/*",
          "arn:aws:apigateway:*::/restapis/*/stages/*",
        ]
      },
      {
        # ListWebACLs does not support resource-level permissions.
        Effect   = "Allow"
        Action   = ["wafv2:ListWebACLs"]
        Resource = "*"
      },
    ]

    # --- CloudWatch metrics, alarms, dashboards ------------------------------
    cloudwatch = [
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricAlarm",
          "cloudwatch:DeleteAlarms",
          "cloudwatch:DescribeAlarms",
          "cloudwatch:PutCompositeAlarm",
          "cloudwatch:TagResource",
          "cloudwatch:UntagResource",
          "cloudwatch:ListTagsForResource",
        ]
        Resource = [
          "arn:aws:cloudwatch:${var.aws_region}:${local.account_id}:alarm:${var.project_name}-*",
        ]
      },
      {
        # Dashboard ARNs have no Region.
        Effect = "Allow"
        Action = [
          "cloudwatch:PutDashboard",
          "cloudwatch:DeleteDashboards",
          "cloudwatch:GetDashboard",
        ]
        Resource = [
          "arn:aws:cloudwatch::${local.account_id}:dashboard/${var.project_name}-*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringLike = { "cloudwatch:namespace" = "${var.project_name}/*" }
        }
      },
      {
        # Read-only calls whose resource type is optional or absent: they
        # accept "*".
        Effect = "Allow"
        Action = [
          "cloudwatch:ListDashboards",
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics",
        ]
        Resource = "*"
      },
    ]

    # --- EventBridge: project rules + targets --------------------------------
    events = [
      {
        Effect = "Allow"
        Action = [
          "events:PutRule",
          "events:DeleteRule",
          "events:DescribeRule",
          "events:EnableRule",
          "events:DisableRule",
          "events:PutTargets",
          "events:RemoveTargets",
          "events:ListTargetsByRule",
          "events:TagResource",
          "events:UntagResource",
          "events:ListTagsForResource",
        ]
        Resource = [
          "arn:aws:events:*:*:rule/${var.project_name}-*",
        ]
      },
    ]

    # --- SNS: project topics -------------------------------------------------
    sns = [
      {
        Effect = "Allow"
        Action = [
          "sns:CreateTopic",
          "sns:DeleteTopic",
          "sns:GetTopicAttributes",
          "sns:SetTopicAttributes",
          "sns:Subscribe",
          "sns:Unsubscribe",
          "sns:GetSubscriptionAttributes",
          "sns:SetSubscriptionAttributes",
          "sns:ListSubscriptionsByTopic",
          "sns:TagResource",
          "sns:UntagResource",
          "sns:ListTagsForResource",
        ]
        Resource = [
          "arn:aws:sns:*:*:${var.project_name}-*",
        ]
      },
    ]

    # --- CloudFront: distribution + OAC --------------------------------------
    # Distribution IDs are generated, so writes are limited by the Project
    # tag, and tagging is limited as for the KMS keys: only a distribution
    # without a Project tag (one being created) or with this project's, only
    # this project's value and only the stacks' tag keys.
    cloudfront = [
      {
        # No resource type: listing and these creations support only "*".
        Effect = "Allow"
        Action = [
          "cloudfront:ListDistributions",
          "cloudfront:CreateOriginAccessControl",
          "cloudfront:ListOriginAccessControls",
          "cloudfront:CreateResponseHeadersPolicy",
          "cloudfront:ListResponseHeadersPolicies",
        ]
        Resource = "*"
      },
      {
        # CreateDistributionWithTags is authorized as CreateDistribution plus
        # TagResource; the request must carry this project's tag.
        Effect   = "Allow"
        Action   = ["cloudfront:CreateDistribution"]
        Resource = "*"
        Condition = {
          StringEquals                = { "aws:RequestTag/Project" = var.project_name }
          "ForAllValues:StringEquals" = { "aws:TagKeys" = local.resource_tag_keys }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "cloudfront:UpdateDistribution",
          "cloudfront:DeleteDistribution",
          "cloudfront:GetDistribution",
          "cloudfront:GetDistributionConfig",
          "cloudfront:UntagResource",
          "cloudfront:ListTagsForResource",
        ]
        Resource = "arn:aws:cloudfront::${local.account_id}:distribution/*"
        Condition = {
          StringEquals = { "aws:ResourceTag/Project" = var.project_name }
        }
      },
      {
        # Tags sent with CreateDistribution, before the distribution has any.
        Effect   = "Allow"
        Action   = ["cloudfront:TagResource"]
        Resource = "arn:aws:cloudfront::${local.account_id}:distribution/*"
        Condition = {
          Null                        = { "aws:ResourceTag/Project" = "true" }
          StringEquals                = { "aws:RequestTag/Project" = var.project_name }
          "ForAllValues:StringEquals" = { "aws:TagKeys" = local.resource_tag_keys }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["cloudfront:TagResource"]
        Resource = "arn:aws:cloudfront::${local.account_id}:distribution/*"
        Condition = {
          StringEquals                = { "aws:ResourceTag/Project" = var.project_name }
          StringEqualsIfExists        = { "aws:RequestTag/Project" = var.project_name }
          "ForAllValues:StringEquals" = { "aws:TagKeys" = local.resource_tag_keys }
        }
      },
      {
        # Origin access controls and response headers policies have
        # generated IDs and support no condition keys, so they cannot be
        # limited to this project's; deploy into a dedicated account.
        Effect = "Allow"
        Action = [
          "cloudfront:UpdateOriginAccessControl",
          "cloudfront:DeleteOriginAccessControl",
          "cloudfront:GetOriginAccessControl",
          "cloudfront:GetOriginAccessControlConfig",
        ]
        Resource = "arn:aws:cloudfront::${local.account_id}:origin-access-control/*"
      },
      {
        Effect = "Allow"
        Action = [
          "cloudfront:UpdateResponseHeadersPolicy",
          "cloudfront:DeleteResponseHeadersPolicy",
          "cloudfront:GetResponseHeadersPolicy",
        ]
        Resource = "arn:aws:cloudfront::${local.account_id}:response-headers-policy/*"
      },
    ]

    # --- Application Auto Scaling: SageMaker endpoint scaling ----------------
    autoscaling = [
      {
        Effect = "Allow"
        Action = [
          "application-autoscaling:RegisterScalableTarget",
          "application-autoscaling:DeregisterScalableTarget",
          "application-autoscaling:PutScalingPolicy",
          "application-autoscaling:DeleteScalingPolicy",
        ]
        Resource = "arn:aws:application-autoscaling:${var.aws_region}:${local.account_id}:scalable-target/*"
        Condition = {
          StringEquals = { "application-autoscaling:service-namespace" = "sagemaker" }
        }
      },
      {
        # The tagging actions do not take the service-namespace key.
        Effect = "Allow"
        Action = [
          "application-autoscaling:TagResource",
          "application-autoscaling:UntagResource",
          "application-autoscaling:ListTagsForResource",
        ]
        Resource = "arn:aws:application-autoscaling:${var.aws_region}:${local.account_id}:scalable-target/*"
      },
      {
        # Describe calls have no resource type and support only "*".
        Effect = "Allow"
        Action = [
          "application-autoscaling:DescribeScalableTargets",
          "application-autoscaling:DescribeScalingPolicies",
        ]
        Resource = "*"
      },
    ]

    # --- ECR: patched-image pipeline reads DLCs, writes project repo ---------
    ecr = [
      {
        Effect = "Allow"
        # Repository-scoped write access for the patched-inference image
        Action = [
          "ecr:CreateRepository",
          "ecr:DeleteRepository",
          "ecr:DescribeRepositories",
          "ecr:ListTagsForResource",
          "ecr:TagResource",
          "ecr:UntagResource",
          "ecr:SetRepositoryPolicy",
          "ecr:DeleteRepositoryPolicy",
          "ecr:GetRepositoryPolicy",
          "ecr:PutLifecyclePolicy",
          "ecr:DeleteLifecyclePolicy",
          "ecr:GetLifecyclePolicy",
          "ecr:PutImageScanningConfiguration",
          "ecr:PutImageTagMutability",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages",
          "ecr:ListImages",
        ]
        Resource = [
          "arn:aws:ecr:*:*:repository/${var.project_name}-*",
        ]
      },
      {
        Effect = "Allow"
        # GetAuthorizationToken only supports "*" resource.
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
    ]

    # --- CloudTrail: project audit trail (stack-training, enable_cloudtrail) --
    cloudtrail = [
      {
        Effect = "Allow"
        Action = [
          "cloudtrail:CreateTrail",
          "cloudtrail:UpdateTrail",
          "cloudtrail:DeleteTrail",
          "cloudtrail:GetTrail",
          "cloudtrail:GetTrailStatus",
          "cloudtrail:StartLogging",
          "cloudtrail:StopLogging",
          "cloudtrail:GetEventSelectors",
          "cloudtrail:PutEventSelectors",
          "cloudtrail:GetInsightSelectors",
          "cloudtrail:PutInsightSelectors",
          "cloudtrail:AddTags",
          "cloudtrail:RemoveTags",
          "cloudtrail:ListTags",
        ]
        Resource = [
          "arn:aws:cloudtrail:*:${local.account_id}:trail/${var.project_name}-*",
        ]
      },
      {
        Effect = "Allow"
        # DescribeTrails and ListTrails do not support resource-level
        # permissions and are read-only.
        Action = [
          "cloudtrail:DescribeTrails",
          "cloudtrail:ListTrails",
        ]
        Resource = "*"
      },
    ]

    # --- Budgets: project monthly budget (stack-training, monthly_budget_usd) -
    budgets = [
      {
        Effect = "Allow"
        Action = [
          "budgets:ModifyBudget",
          "budgets:ViewBudget",
          "budgets:TagResource",
          "budgets:UntagResource",
          "budgets:ListTagsForResource",
        ]
        Resource = [
          "arn:aws:budgets::${local.account_id}:budget/${var.project_name}-*",
        ]
      },
    ]

    # --- SQS: auto-deployment dead-letter queue (stack-inference) ------------
    sqs = [
      {
        Effect = "Allow"
        Action = [
          "sqs:CreateQueue",
          "sqs:DeleteQueue",
          "sqs:GetQueueAttributes",
          "sqs:SetQueueAttributes",
          "sqs:GetQueueUrl",
          "sqs:TagQueue",
          "sqs:UntagQueue",
          "sqs:ListQueueTags",
        ]
        Resource = [
          "arn:aws:sqs:*:${local.account_id}:${var.project_name}-*",
        ]
      },
    ]

    # --- STS: GetCallerIdentity is used throughout the Terraform roots -------
    sts = [
      {
        # GetCallerIdentity supports only "*".
        Effect   = "Allow"
        Action   = ["sts:GetCallerIdentity"]
        Resource = "*"
      },
    ]

    # --- CodeBuild: read build status for pipeline reporting -----------------
    codebuild = [
      {
        Effect = "Allow"
        Action = [
          "codebuild:BatchGetBuilds",
          "codebuild:ListBuildsForProject",
          "codebuild:BatchGetProjects",
        ]
        Resource = [
          "arn:aws:codebuild:*:*:project/${var.project_name}-*",
        ]
      },
      {
        # Only CodePipeline starts the deploy projects. The role they run as
        # may not start, retry or reconfigure them, so a build cannot carry
        # its commands into later releases.
        Sid    = "DenyCiProjectChanges"
        Effect = "Deny"
        Action = [
          "codebuild:CreateWebhook",
          "codebuild:DeleteProject",
          "codebuild:PutResourcePolicy",
          "codebuild:RetryBuild",
          "codebuild:RetryBuildBatch",
          "codebuild:StartBuild",
          "codebuild:StartBuildBatch",
          "codebuild:StartSandbox",
          "codebuild:UpdateProject",
          "codebuild:UpdateProjectVisibility",
          "codebuild:UpdateWebhook",
        ]
        Resource = local.ci_project_arns
      },
    ]
  }

  # Each group stays under the 6,144-character managed policy limit.
  codebuild_policy_groups = {
    iam      = ["iam"]
    data     = ["logs", "s3", "sts"]
    keys     = ["kms", "codebuild"]
    ml       = ["sagemaker", "lambda", "events", "sns", "sqs"]
    edge     = ["apigateway", "waf", "cloudfront"]
    platform = ["cloudwatch", "autoscaling", "ecr", "cloudtrail", "budgets"]
  }
}

resource "aws_iam_policy" "codebuild" {
  for_each = local.codebuild_policy_groups

  name        = "${var.project_name}-ci-codebuild-${each.key}"
  description = "CodeBuild deploy permissions (${join(", ", each.value)})"
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = flatten([for k in each.value : local.codebuild_statements[k]])
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "codebuild" {
  for_each = local.codebuild_policy_groups

  role       = module.codebuild_role.role_name
  policy_arn = aws_iam_policy.codebuild[each.key].arn
}
