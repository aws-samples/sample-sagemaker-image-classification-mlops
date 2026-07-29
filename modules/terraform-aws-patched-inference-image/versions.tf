# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

terraform {
  required_version = "~> 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # null_resource.build_on_create triggers the first patched-image build.
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}
