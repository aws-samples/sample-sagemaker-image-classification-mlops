# sns-alerts

SNS topic with email subscription, CloudWatch metric alarms, and optional composite alarm.

## What It Does

1. Creates an SNS topic for alert notifications
2. Optionally creates an email subscription on the topic
3. Creates CloudWatch metric alarms from a configurable map, all wired to the SNS topic
4. Optionally creates a composite alarm that aggregates multiple alarms with a custom alarm rule

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| terraform | ~> 1.15 |
| aws | ~> 6.0 |

## Providers

| Name | Version |
|------|---------|
| aws | ~> 6.0 |

## Resources

| Name | Type |
|------|------|
| [aws_cloudwatch_composite_alarm.composite_alarm](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_composite_alarm) | resource |
| [aws_cloudwatch_metric_alarm.alarms](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_sns_topic.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic) | resource |
| [aws_sns_topic_subscription.email_alerts](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_subscription) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| topic\_name | SNS topic name | `string` | n/a | yes |
| alarms | CloudWatch alarms configuration | <pre>map(object({<br/>    alarm_name          = string<br/>    comparison_operator = string<br/>    evaluation_periods  = string<br/>    metric_name         = string<br/>    namespace           = string<br/>    period              = string<br/>    statistic           = string<br/>    threshold           = string<br/>    alarm_description   = string<br/>    treat_missing_data  = optional(string, "notBreaching")<br/>    dimensions          = optional(map(string))<br/>  }))</pre> | `{}` | no |
| composite\_alarm | Composite alarm configuration | <pre>object({<br/>    alarm_name        = string<br/>    alarm_description = string<br/>    alarm_rule        = string<br/>  })</pre> | `null` | no |
| email\_endpoint | Email endpoint for alerts | `string` | `""` | no |
| kms\_master\_key\_id | KMS key ID/ARN/alias used for SNS server-side encryption. Null/empty = alias/aws/sns (AWS-managed, still encrypted). Pass a customer-managed key ARN for tighter control. | `string` | `null` | no |
| tags | Resource tags | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| alarm\_names | Created alarm names |
| sns\_topic\_arn | SNS topic ARN |
<!-- END_TF_DOCS -->

## File Structure

```
modules/terraform-aws-sns/
├── main.tf          # SNS topic, email subscription, CloudWatch alarms, composite alarm
├── outputs.tf       # SNS topic ARN, alarm names map
└── variables.tf     # Topic name, email endpoint, alarms config, composite alarm, tags
```
