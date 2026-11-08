# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

terraform {
  required_version = "~> 1.15"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # 6.54 stops a perpetual diff on guardrail filter modalities.
      version = "~> 6.54"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.8"
    }
    awscc = {
      source  = "hashicorp/awscc"
      version = "~> 1.0"
    }
  }
}
