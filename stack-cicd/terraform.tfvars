# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# General
project_name = "medical-image-classification"
environment  = "dev"
aws_region   = "us-east-1"

# Terraform state backend: the stack-backend-setup output state_bucket_id.
# `make backend-config` prints it. The KMS alias and boundary name default to
# the stack-backend-setup naming; set them only if you changed that stack.
state_bucket_name = "your-project-tfstate-1a2b3c4d"
# state_kms_key_alias    = "alias/<project_name>-terraform-state"
# workload_boundary_name = "<project_name>-workload-boundary"

# GitHub: your fork of this sample. After the first apply, complete the
# CodeStar connection handshake in the console (see README).
github_owner  = "your-github-org"
github_repo   = "your-repo"
github_branch = "main"

# SageMaker: the Model Package Group defaults to <project_name>-model-package-group (stack-training output
# model_package_group_name); set it only if you changed that name.
# model_package_group_name = "medical-image-classification-model-package-group"

# Manual approval: require a human to review before the inference deploy.
# Strongly recommended for medical ML. Set require_manual_approval = false
# in dev/test environments where fully auto-deploy is acceptable.
require_manual_approval      = true
approval_notification_emails = [] # e.g., ["ml-oncall@example.com"]
