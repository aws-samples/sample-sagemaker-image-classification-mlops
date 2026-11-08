# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

################################################################################
# Amazon Cognito: application users
################################################################################

# With api_authorization_type = "COGNITO_USER_POOLS", API Gateway's Cognito
# authorizer checks the caller's ID token before the inference Lambda (and so
# the endpoint) is invoked. The stack creates the user pool and an app client
# unless api_cognito_user_pool_arns names existing pools. Administrators
# create the users; there is no self sign-up. User pool data is encrypted at
# rest with an AWS owned key (the AWS provider has no customer managed key
# setting for user pools yet).

locals {
  create_user_pool = var.api_authorization_type == "COGNITO_USER_POOLS" && length(var.api_cognito_user_pool_arns) == 0

  api_cognito_user_pool_arns = local.create_user_pool ? [aws_cognito_user_pool.app_users[0].arn] : var.api_cognito_user_pool_arns

  # Lifetimes of the app client's tokens, each with its unit.
  cognito_token_validity = {
    id      = { value = 60, unit = "minutes" }
    access  = { value = 60, unit = "minutes" }
    refresh = { value = 12, unit = "hours" }
  }
}

resource "aws_cognito_user_pool" "app_users" {
  count = local.create_user_pool ? 1 : 0

  name = "${var.project_name}-app-users"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  # Threat protection is a Plus feature plan capability.
  user_pool_tier = var.cognito_threat_protection_mode == "OFF" ? "ESSENTIALS" : "PLUS"
  user_pool_add_ons {
    advanced_security_mode = var.cognito_threat_protection_mode
  }

  mfa_configuration = var.cognito_mfa_configuration
  software_token_mfa_configuration {
    enabled = true
  }

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 3
  }

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  deletion_protection = var.cognito_deletion_protection ? "ACTIVE" : "INACTIVE"
}

# Public client (no secret) for a browser or CLI sign-in. SRP keeps the
# password off the wire; ADMIN_USER_PASSWORD_AUTH lets an operator with IAM
# credentials fetch a token for smoke tests (stack-inference/README.md).
resource "aws_cognito_user_pool_client" "app" {
  count = local.create_user_pool ? 1 : 0

  name         = "${var.project_name}-app"
  user_pool_id = aws_cognito_user_pool.app_users[0].id

  generate_secret = false
  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_ADMIN_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]
  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  id_token_validity      = local.cognito_token_validity.id.value
  access_token_validity  = local.cognito_token_validity.access.value
  refresh_token_validity = local.cognito_token_validity.refresh.value
  token_validity_units {
    id_token      = local.cognito_token_validity.id.unit
    access_token  = local.cognito_token_validity.access.unit
    refresh_token = local.cognito_token_validity.refresh.unit
  }
}
