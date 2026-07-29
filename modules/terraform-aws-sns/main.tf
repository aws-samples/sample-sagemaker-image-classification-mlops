# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

resource "aws_sns_topic" "this" {
  name = var.topic_name

  # Server-side encryption. AWS-managed `alias/aws/sns` is the minimum;
  # callers can pass a customer-managed KMS key ARN for tighter control.
  kms_master_key_id = coalesce(var.kms_master_key_id, "alias/aws/sns")

  tags = var.tags
}

resource "aws_sns_topic_subscription" "email_alerts" {
  count     = var.email_endpoint != "" ? 1 : 0
  topic_arn = aws_sns_topic.this.arn
  protocol  = "email"
  endpoint  = var.email_endpoint
}

################################################################################
# CloudWatch Alarms
################################################################################

resource "aws_cloudwatch_metric_alarm" "alarms" {
  for_each = var.alarms

  alarm_name          = each.value.alarm_name
  comparison_operator = each.value.comparison_operator
  evaluation_periods  = each.value.evaluation_periods
  metric_name         = each.value.metric_name
  namespace           = each.value.namespace
  period              = each.value.period
  statistic           = each.value.statistic
  threshold           = each.value.threshold
  alarm_description   = each.value.alarm_description
  alarm_actions       = [aws_sns_topic.this.arn]
  treat_missing_data  = each.value.treat_missing_data

  dimensions = each.value.dimensions

  tags = var.tags
}

################################################################################
# Composite Alarm
################################################################################

resource "aws_cloudwatch_composite_alarm" "composite_alarm" {
  count = var.composite_alarm != null ? 1 : 0

  alarm_name        = var.composite_alarm.alarm_name
  alarm_description = var.composite_alarm.alarm_description
  alarm_rule        = var.composite_alarm.alarm_rule
  alarm_actions     = [aws_sns_topic.this.arn]
  ok_actions        = [aws_sns_topic.this.arn]

  depends_on = [aws_cloudwatch_metric_alarm.alarms]

  tags = var.tags
}
