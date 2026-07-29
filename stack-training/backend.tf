# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

terraform {
  backend "s3" {
    # NOTE: Backend config does not support variables - values must be hardcoded.
    # The bucket and KMS key are provisioned by stack-backend-setup/.
    # After running `terraform apply` in stack-backend-setup/, copy the
    # `state_bucket_id` output here, then run `terraform init -migrate-state`.
    bucket       = "medical-image-classification-terraform-state-1757646452"
    key          = "training/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    kms_key_id   = "alias/medical-image-classification-terraform-state"
    use_lockfile = true
  }
}
