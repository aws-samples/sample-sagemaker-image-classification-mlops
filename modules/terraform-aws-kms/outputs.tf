# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "key_id" {
  description = "The globally unique identifier for the key"
  value       = aws_kms_key.this.key_id
}

output "key_arn" {
  description = "The Amazon Resource Name (ARN) of the key"
  value       = aws_kms_key.this.arn
}

################################################################################
# KMS Alias
################################################################################

output "alias_arn" {
  description = "The Amazon Resource Name (ARN) of the key alias"
  value       = var.alias_name != null ? aws_kms_alias.this[0].arn : null
}
