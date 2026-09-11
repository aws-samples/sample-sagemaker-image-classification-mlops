# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

module "s3_codepipeline_artifacts" {
  source = "../modules/terraform-aws-s3"

  bucket_name       = "${var.project_name}-codepipeline-artifacts"
  enable_versioning = true

  tags = local.common_tags
}

################################################################################
# CodeStar Connection
################################################################################

# CodeStar connection for GitHub
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

  environment_variables = [
    { name = "MODEL_PACKAGE_GROUP_NAME", value = var.model_package_group_name },
    { name = "AWS_REGION", value = var.aws_region },
    # Match the DLC used by the inference pipeline so the baseline model
    # references the same image as approved models.
    { name = "DLC_ACCOUNT_ID", value = var.dlc_account_id },
    { name = "INFERENCE_IMAGE_TAG", value = var.inference_image_tag },
  ]

  tags = local.common_tags
}

module "codebuild_training_deploy" {
  source = "../modules/terraform-aws-codebuild"

  name               = "${var.project_name}-training-deploy"
  service_role_arn   = module.codebuild_role.role_arn
  buildspec_path     = "stack-cicd/codebuild/training-deploy-buildspec.yml"
  encryption_key_arn = data.aws_kms_alias.state.target_key_arn
  tags               = local.common_tags
}

module "codebuild_script_upload" {
  source = "../modules/terraform-aws-codebuild"

  name               = "${var.project_name}-script-upload"
  service_role_arn   = module.codebuild_role.role_arn
  buildspec_path     = "stack-cicd/codebuild/script-upload-buildspec.yml"
  encryption_key_arn = data.aws_kms_alias.state.target_key_arn
  tags               = local.common_tags
}

module "codebuild_inference_deploy" {
  source = "../modules/terraform-aws-codebuild"

  name               = "${var.project_name}-inference-deploy"
  service_role_arn   = module.codebuild_role.role_arn
  buildspec_path     = "stack-cicd/codebuild/inference-deploy-buildspec.yml"
  encryption_key_arn = data.aws_kms_alias.state.target_key_arn
  tags               = local.common_tags
}

################################################################################
# CodePipeline
################################################################################

# CodePipeline
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
    # a human approves in the console (or via API) - critical for medical
    # ML deployments where a bad model can cause real harm.
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
  # Server-side encryption using the AWS-managed SNS key. Good enough for
  # approval notifications (no sensitive data in the payload) and doesn't
  # require a custom KMS grant from CodePipeline to publish.
  kms_master_key_id = "alias/aws/sns"
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

# IAM roles using module
module "codepipeline_role" {
  source = "../modules/terraform-aws-iam"

  role_name = "${var.project_name}-codepipeline-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "codepipeline.amazonaws.com"
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
        # Publish approval notifications to the SNS topic used by the
        # manual approval gate. Scoped by wildcard so the policy works
        # regardless of whether the topic exists yet (first-apply order).
        {
          Effect   = "Allow"
          Action   = ["sns:Publish"]
          Resource = "arn:aws:sns:*:*:${var.project_name}-pipeline-approvals"
        }
      ]
    })
  }

  tags = local.common_tags
}

module "codebuild_role" {
  source = "../modules/terraform-aws-iam"

  role_name = "${var.project_name}-codebuild-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "codebuild.amazonaws.com"
        }
      }
    ]
  })

  # Least-privilege policy for CodeBuild. CodeBuild runs `terraform apply`
  # against the training and inference roots plus the baseline-model script,
  # so it needs broad CRUD on project resources - but scoped to project
  # ARNs wherever AWS allows ARN-level IAM. APIs that only support `*`
  # resource (ListBuckets, DescribeEndpoints without filter, ECR
  # GetAuthorizationToken, CloudFront, etc.) are isolated into read-only
  # statements with tightly-enumerated actions.
  inline_policies = {
    # --- CloudWatch Logs: CodeBuild's own log group + Lambda log groups -------
    logs = jsonencode({
      Version = "2012-10-17"
      Statement = [
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
            "arn:aws:logs:*:*:log-group:/aws/codebuild/${var.project_name}-*",
            "arn:aws:logs:*:*:log-group:/aws/codebuild/${var.project_name}-*:*",
            "arn:aws:logs:*:*:log-group:/aws/lambda/${var.project_name}-*",
            "arn:aws:logs:*:*:log-group:/aws/lambda/${var.project_name}-*:*",
            "arn:aws:logs:*:*:log-group:/aws/sagemaker/*",
            "arn:aws:logs:*:*:log-group:/aws/sagemaker/*:*",
            "arn:aws:logs:*:*:log-group:/aws/apigateway/${var.project_name}-*",
            "arn:aws:logs:*:*:log-group:/aws/apigateway/${var.project_name}-*:*",
          ]
        },
      ]
    })

    # --- S3: project buckets + Terraform state bucket ------------------------
    s3 = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect = "Allow"
          # ListBucket and related bucket-level ops support ARN-level scoping
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
          # Object-level ops scoped to the project buckets
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
          Effect = "Allow"
          # ListAllMyBuckets is required by several buildspecs to discover
          # dynamically-named buckets (e.g. data_uploader.sh, baseline-model
          # buildspec). Only supports "*" per IAM docs.
          Action   = ["s3:ListAllMyBuckets"]
          Resource = "*"
        },
      ]
    })

    # --- SageMaker: pipelines, endpoints, models, model registry -------------
    sagemaker = jsonencode({
      Version = "2012-10-17"
      Statement = [
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
            "sagemaker:CreateModelPackage",
            "sagemaker:UpdateModelPackage",
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
          ]
          Resource = "*"
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
    })

    # --- IAM: create/manage project roles and policies -----------------------
    iam = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect = "Allow"
          Action = [
            "iam:CreateRole",
            "iam:DeleteRole",
            "iam:GetRole",
            "iam:UpdateRole",
            "iam:UpdateAssumeRolePolicy",
            "iam:TagRole",
            "iam:UntagRole",
            "iam:ListRoleTags",
            "iam:AttachRolePolicy",
            "iam:DetachRolePolicy",
            "iam:ListAttachedRolePolicies",
            "iam:PutRolePolicy",
            "iam:DeleteRolePolicy",
            "iam:GetRolePolicy",
            "iam:ListRolePolicies",
          ]
          Resource = [
            "arn:aws:iam::*:role/${var.project_name}-*",
          ]
        },
        {
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
            "arn:aws:iam::*:policy/${var.project_name}-*",
          ]
        },
        {
          Effect = "Allow"
          # PassRole is required to hand project roles to SageMaker, Lambda,
          # API Gateway, EventBridge, etc. during Terraform apply. Scope
          # to project roles and restrict to the services that consume them.
          Action = ["iam:PassRole"]
          Resource = [
            "arn:aws:iam::*:role/${var.project_name}-*",
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
                "codepipeline.amazonaws.com",
                "cloudfront.amazonaws.com",
                "sns.amazonaws.com",
                # CreateSchedule / UpdateSchedule require PassRole for the role
                # the schedule's target assumes (the drift and fairness
                # Processing job schedulers).
                "scheduler.amazonaws.com",
              ]
            }
          }
        },
        {
          Effect = "Allow"
          # Terraform reads the caller identity on every run.
          Action = [
            "iam:GetAccountSummary",
            "iam:ListAccountAliases",
            "iam:GetUser",
            "iam:GetRole",
          ]
          Resource = "*"
        },
      ]
    })

    # --- KMS: project keys ---------------------------------------------------
    kms = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect = "Allow"
          Action = [
            "kms:CreateKey",
            "kms:DescribeKey",
            "kms:ListKeys",
            "kms:ListAliases",
            "kms:CreateAlias",
            "kms:DeleteAlias",
            "kms:UpdateAlias",
            "kms:EnableKey",
            "kms:DisableKey",
            "kms:EnableKeyRotation",
            "kms:DisableKeyRotation",
            "kms:GetKeyRotationStatus",
            "kms:GetKeyPolicy",
            "kms:PutKeyPolicy",
            "kms:ScheduleKeyDeletion",
            "kms:CancelKeyDeletion",
            "kms:TagResource",
            "kms:UntagResource",
            "kms:ListResourceTags",
            "kms:Encrypt",
            "kms:Decrypt",
            "kms:GenerateDataKey",
            "kms:ReEncryptFrom",
            "kms:ReEncryptTo",
          ]
          # KMS key ARNs contain UUIDs we can't predict, but aliases are scoped.
          # CreateKey requires * resource per AWS IAM docs. This is an
          # intentional, narrow wildcard that other statements compensate for.
          Resource = [
            "arn:aws:kms:*:*:key/*",
            "arn:aws:kms:*:*:alias/${var.project_name}-*",
            "arn:aws:kms:*:*:alias/medical-image-classification-*",
          ]
        },
      ]
    })

    # --- Lambda: project functions + layers ----------------------------------
    lambda = jsonencode({
      Version = "2012-10-17"
      Statement = [
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
    })

    # --- API Gateway ---------------------------------------------------------
    apigateway = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect = "Allow"
          Action = [
            "apigateway:GET",
            "apigateway:POST",
            "apigateway:PUT",
            "apigateway:PATCH",
            "apigateway:DELETE",
            "apigateway:TagResource",
            "apigateway:UntagResource",
          ]
          # APIGateway v1 REST APIs are not scopable by name - only by
          # auto-generated API ID. We scope by service and rely on the
          # project-name tag applied via provider default_tags.
          Resource = [
            "arn:aws:apigateway:*::/restapis",
            "arn:aws:apigateway:*::/restapis/*",
            "arn:aws:apigateway:*::/tags/*",
          ]
        },
      ]
    })

    # --- CloudWatch metrics, alarms, dashboards ------------------------------
    cloudwatch = jsonencode({
      Version = "2012-10-17"
      Statement = [
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
            "arn:aws:cloudwatch:*:*:alarm:${var.project_name}-*",
          ]
        },
        {
          Effect = "Allow"
          # PutDashboard, PutMetricData, and a handful of others do not
          # support resource-level permissions per AWS IAM docs.
          Action = [
            "cloudwatch:PutDashboard",
            "cloudwatch:DeleteDashboards",
            "cloudwatch:GetDashboard",
            "cloudwatch:ListDashboards",
            "cloudwatch:PutMetricData",
            "cloudwatch:GetMetricData",
            "cloudwatch:GetMetricStatistics",
            "cloudwatch:ListMetrics",
          ]
          Resource = "*"
        },
      ]
    })

    # --- EventBridge: project rules + targets --------------------------------
    events = jsonencode({
      Version = "2012-10-17"
      Statement = [
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
    })

    # --- SNS: project topics -------------------------------------------------
    sns = jsonencode({
      Version = "2012-10-17"
      Statement = [
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
    })

    # --- CloudFront: distribution + OAC --------------------------------------
    cloudfront = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect = "Allow"
          # CloudFront uses global ARNs and distribution IDs aren't
          # predictable at policy time. Enumerate actions tightly instead
          # of granting cloudfront:*.
          Action = [
            "cloudfront:CreateDistribution",
            "cloudfront:UpdateDistribution",
            "cloudfront:DeleteDistribution",
            "cloudfront:GetDistribution",
            "cloudfront:GetDistributionConfig",
            "cloudfront:ListDistributions",
            "cloudfront:TagResource",
            "cloudfront:UntagResource",
            "cloudfront:ListTagsForResource",
            "cloudfront:CreateOriginAccessControl",
            "cloudfront:UpdateOriginAccessControl",
            "cloudfront:DeleteOriginAccessControl",
            "cloudfront:GetOriginAccessControl",
            "cloudfront:GetOriginAccessControlConfig",
            "cloudfront:ListOriginAccessControls",
          ]
          Resource = "*"
        },
      ]
    })

    # --- Application Auto Scaling: SageMaker endpoint scaling ----------------
    autoscaling = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect = "Allow"
          # application-autoscaling targets don't support resource-level
          # permissions; scope by service via ScalableDimension.
          Action = [
            "application-autoscaling:RegisterScalableTarget",
            "application-autoscaling:DeregisterScalableTarget",
            "application-autoscaling:DescribeScalableTargets",
            "application-autoscaling:PutScalingPolicy",
            "application-autoscaling:DeleteScalingPolicy",
            "application-autoscaling:DescribeScalingPolicies",
            "application-autoscaling:TagResource",
            "application-autoscaling:UntagResource",
            "application-autoscaling:ListTagsForResource",
          ]
          Resource = "*"
          Condition = {
            StringEquals = {
              "application-autoscaling:service-namespace" = "sagemaker"
            }
          }
        },
      ]
    })

    # --- ECR: patched-image pipeline reads DLCs, writes project repo ---------
    ecr = jsonencode({
      Version = "2012-10-17"
      Statement = [
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
    })

    # --- STS: GetCallerIdentity is used throughout the Terraform roots -------
    sts = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect   = "Allow"
          Action   = ["sts:GetCallerIdentity"]
          Resource = "*"
        },
      ]
    })

    # --- CodeBuild: read build status for pipeline reporting -----------------
    codebuild = jsonencode({
      Version = "2012-10-17"
      Statement = [
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
      ]
    })
  }

  tags = local.common_tags
}
