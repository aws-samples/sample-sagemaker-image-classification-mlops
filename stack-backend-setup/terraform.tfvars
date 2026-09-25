# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

project_name = "medical-image-classification"
environment  = "dev"
aws_region   = "us-east-1"

# Leave bucket_name empty to generate a unique name with a random suffix.
# After apply, run `make backend-config` to write backend.hcl for the other
# stacks from this stack's outputs.
bucket_name = ""

# Leave empty to use alias/<project_name>-terraform-state.
kms_key_alias = ""

# Keep false: the state bucket holds every other stack's state.
force_destroy                     = false
noncurrent_version_retention_days = 90
kms_key_deletion_window_days      = 30
kms_key_administrators            = []
