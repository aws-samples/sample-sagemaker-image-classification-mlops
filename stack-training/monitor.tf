# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

module "cloudwatch_monitoring" {
  source = "../modules/terraform-aws-cloudwatch"

  project_name    = var.project_name
  aws_region      = var.aws_region
  training_models = keys(var.models)

  enable_training_monitoring = var.enable_training_monitoring

  log_groups = var.log_groups

  log_retention_days = var.log_retention_days

  log_group_names = var.log_group_names

  metric_namespaces = var.metric_namespaces

  dashboard_name   = var.dashboard_name
  dashboard_config = var.dashboard_config

  kms_key_arn = module.kms.key_arn
}
