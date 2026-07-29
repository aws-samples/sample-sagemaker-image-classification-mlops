# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

resource "aws_iam_role" "this" {
  name                 = var.role_name
  assume_role_policy   = var.assume_role_policy
  description          = var.description
  path                 = var.path
  max_session_duration = var.max_session_duration
  tags                 = var.tags
}

################################################################################
# IAM Policies
################################################################################

resource "aws_iam_role_policy_attachment" "managed_policies" {
  for_each   = toset(var.managed_policy_arns)
  role       = aws_iam_role.this.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "inline_policies" {
  for_each = var.inline_policies
  name     = each.key
  role     = aws_iam_role.this.id
  policy   = each.value
}
