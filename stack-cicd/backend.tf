# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Partial backend configuration. The bucket, region and KMS key come from
# backend.hcl, which `make backend-config` writes from the stack-backend-setup
# outputs (see backend.hcl.example):
#
#   terraform init -backend-config=backend.hcl
terraform {
  backend "s3" {
    key          = "cicd/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
