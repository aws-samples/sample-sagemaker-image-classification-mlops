# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

module "s3_sbom" {
  count  = var.enable_sbom_bucket ? 1 : 0
  source = "../modules/terraform-aws-s3"

  bucket_name       = "${var.project_name}-sbom-${random_id.sbom_suffix[0].hex}"
  kms_key_arn       = module.kms.key_arn
  enable_versioning = true
  force_destroy     = false

  lifecycle_rules = [{
    id = "sbom-retention"
    # Keep SBOMs for long enough that auditors can reconstruct what
    # shipped in any given month. Shorter than CloudTrail because SBOMs
    # are re-derivable from the image if we still have it.
    expiration_days                 = var.sbom_retention_days
    noncurrent_version_days         = 30
    abort_incomplete_multipart_days = 7
  }]
}

resource "random_id" "sbom_suffix" {
  count       = var.enable_sbom_bucket ? 1 : 0
  byte_length = 4
}
