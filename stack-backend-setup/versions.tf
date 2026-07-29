# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

terraform {
  required_version = "~> 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.8"
    }
  }

  # Local state for the bootstrap stack. Once the S3 bucket this stack creates
  # exists, the other stacks use it as their remote backend (with native
  # use_lockfile = true). This stack never migrates into the bucket it owns.
}
