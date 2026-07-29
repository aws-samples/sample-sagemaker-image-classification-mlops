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
  description = "Alias of the state encryption KMS key (usable in backend `kms_key_id`)"
  value       = "alias/${var.project_name}-terraform-state"
}

################################################################################
# Backend Usage Snippet
################################################################################

output "backend_block_example" {
  description = "Copy-paste this backend block into each consumer root (update `key` per root)"
  value       = <<-EOT
    terraform {
      backend "s3" {
        bucket       = "${module.state_bucket.s3_bucket_id}"
        key          = "<root-name>/terraform.tfstate"
        region       = "${module.state_bucket.s3_bucket_region}"
        encrypt      = true
        kms_key_id   = "alias/${var.project_name}-terraform-state"
        use_lockfile = true
      }
    }
  EOT
}
