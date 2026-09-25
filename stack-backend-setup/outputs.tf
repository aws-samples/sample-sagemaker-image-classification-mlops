# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "state_bucket_id" {
  description = "Name of the S3 bucket holding Terraform remote state"
  value       = module.state_bucket.s3_bucket_id
}

output "state_bucket_arn" {
  description = "ARN of the state bucket"
  value       = module.state_bucket.s3_bucket_arn
}

output "state_bucket_region" {
  description = "AWS region of the state bucket"
  value       = module.state_bucket.s3_bucket_region
}

################################################################################
# KMS
################################################################################

output "kms_key_id" {
  description = "ID of the KMS key used to encrypt state"
  value       = module.kms.key_id
}

output "kms_key_arn" {
  description = "ARN of the KMS key used to encrypt state"
  value       = module.kms.key_arn
}

output "kms_key_alias" {
  description = "Alias of the state encryption KMS key (usable as the backend kms_key_id)"
  value       = "alias/${local.kms_key_alias}"
}

################################################################################
# IAM
################################################################################

output "workload_boundary_arn" {
  description = "ARN of the permissions boundary that every training and inference role must carry"
  value       = aws_iam_policy.workload_boundary.arn
}

################################################################################
# Backend configuration for the other stacks
################################################################################

output "backend_hcl" {
  description = "Contents for backend.hcl in stack-training, stack-inference and stack-cicd (`make backend-config` writes it for you)"
  value       = <<-EOT
    bucket     = "${module.state_bucket.s3_bucket_id}"
    region     = "${module.state_bucket.s3_bucket_region}"
    kms_key_id = "alias/${local.kms_key_alias}"
  EOT
}
