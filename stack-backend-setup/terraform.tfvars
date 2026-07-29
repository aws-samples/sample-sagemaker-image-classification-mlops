# © 2026 Amazon Web Services, Inc. or its affiliates. All Rights Reserved.
#
# This AWS Content is provided subject to the terms of the AWS Customer Agreement
# available at http://aws.amazon.com/agreement or other written agreement between
# Customer and either Amazon Web Services, Inc. or Amazon Web Services EMEA SARL or both.

project_name = "medical-image-classification"
environment  = "dev"
aws_region   = "us-east-1"

# Leave bucket_name empty to auto-generate a unique name with a random suffix.
# Once provisioned, copy the state_bucket_id output into the other roots'
# backend.tf `bucket` attribute.
bucket_name = "medical-image-classification-terraform-state-1757646452"

force_destroy                     = true
noncurrent_version_retention_days = 90
kms_key_deletion_window_days      = 30
kms_key_administrators            = []
