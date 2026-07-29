# © 2026 Amazon Web Services, Inc. or its affiliates. All Rights Reserved.
#
# This AWS Content is provided subject to the terms of the AWS Customer Agreement
# available at http://aws.amazon.com/agreement or other written agreement between
# Customer and either Amazon Web Services, Inc. or Amazon Web Services EMEA SARL or both.

# General
project_name = "medical-image-classification"
environment  = "dev"
aws_region   = "us-east-1"

# GitHub
github_owner  = "xsagarx-aws"
github_repo   = "Medical_Image_Classification"
github_branch = "main"

# SageMaker
# Model Package Group name - must match training infrastructure
model_package_group_name = "medical-image-classification-model-package-group"

# Manual approval — require a human to review before production inference deploy.
# Strongly recommended for medical ML. Set require_manual_approval = false
# in dev/test environments where fully auto-deploy is acceptable.
require_manual_approval      = true
approval_notification_emails = [] # e.g., ["ml-oncall@example.com"]
