# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "description" {
  description = "Description of the KMS key"
  type        = string
}

variable "deletion_window_days" {
  description = "Number of days to wait before deleting KMS key"
  type        = number
  default     = 7
}

variable "enable_key_rotation" {
  description = "Enable automatic rotation of KMS key"
  type        = bool
  default     = true
}

################################################################################
# KMS Alias
################################################################################

variable "alias_name" {
  description = "Alias name for the KMS key (optional)"
  type        = string
  default     = null
}

################################################################################
# Key Administration
################################################################################

variable "key_administrators" {
  description = "IAM ARNs allowed to administer the KMS key (schedule deletion, rotate, manage policy). When empty, the AWS account root gets default admin rights."
  type        = list(string)
  default     = []
}

variable "enable_cloudtrail_sns_grant" {
  description = "Add the key-policy statement CloudTrail needs to publish delivery notifications to an SNS topic encrypted with this CMK (kms:GenerateDataKey* and kms:Decrypt for the CloudTrail service principal)."
  type        = bool
  default     = false
}

variable "enable_cloudtrail_grant" {
  description = "Add a key-policy statement allowing the CloudTrail service principal to GenerateDataKey/DescribeKey. Required when this CMK encrypts a CloudTrail trail, otherwise CreateTrail fails with InsufficientEncryptionPolicyException."
  type        = bool
  default     = false
}

################################################################################
# Tags
################################################################################

variable "tags" {
  description = "Tags to apply to the KMS key"
  type        = map(string)
  default     = {}
}
