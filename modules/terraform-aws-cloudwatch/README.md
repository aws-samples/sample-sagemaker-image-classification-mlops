# cloudwatch

Dual-mode CloudWatch monitoring module supporting ML training dashboards and generic observability.

## What It Does

1. Creates CloudWatch log groups - SageMaker-specific (training mode) or custom with optional KMS encryption (generic mode)
2. Creates CloudWatch metric filters to extract metrics from logs - ML training metrics (training mode) or user-defined filters (generic mode)
3. Creates a CloudWatch dashboard - auto-generated ML training dashboard (training mode) or custom JSON dashboard (generic mode)
4. Training mode generates metric filters for data processing, training accuracy/loss/precision/recall, evaluation summary, ensemble performance, and model registry metrics

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | ~> 1.15 |
| aws | ~> 6.0 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | ~> 6.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_dashboard.generic](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_dashboard) | resource |
| [aws_cloudwatch_dashboard.training_dashboard](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_dashboard) | resource |
| [aws_cloudwatch_log_group.generic](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_group.processing_jobs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_group.training_jobs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_metric_filter.data_metrics](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_metric_filter) | resource |
| [aws_cloudwatch_log_metric_filter.ensemble_metrics](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_metric_filter) | resource |
| [aws_cloudwatch_log_metric_filter.evaluation_summary_metrics](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_metric_filter) | resource |
| [aws_cloudwatch_log_metric_filter.generic](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_metric_filter) | resource |
| [aws_cloudwatch_log_metric_filter.registry_metrics](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_metric_filter) | resource |
| [aws_cloudwatch_log_metric_filter.training_metrics](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_metric_filter) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| aws\_region | AWS region for monitoring | `string` | n/a | yes |
| project\_name | Project name for resource naming | `string` | n/a | yes |
| dashboard\_config | Dashboard configuration JSON (generic mode only) | `string` | `""` | no |
| dashboard\_name | CloudWatch dashboard name (generic mode only, training mode auto-generates) | `string` | `null` | no |
| enable\_training\_monitoring | Enable ML training monitoring (uses hardcoded ML metrics) | `bool` | `false` | no |
| kms\_key\_arn | KMS key ARN for log group encryption (generic mode only) | `string` | `null` | no |
| log\_group\_names | Log group names for metric filters (only used when enable\_training\_monitoring = true) | `map(string)` | `{}` | no |
| log\_groups | Map of log groups to create (generic mode only) | <pre>map(object({<br/>    name              = string<br/>    retention_in_days = optional(number, 14)<br/>  }))</pre> | `{}` | no |
| log\_retention\_days | Default CloudWatch log retention in days (generic mode only) | `number` | `14` | no |
| metric\_filters | Map of metric filters to create (generic mode only) | <pre>map(object({<br/>    log_group_name = string<br/>    pattern        = string<br/>    metric_transformation = object({<br/>      name      = string<br/>      namespace = string<br/>      value     = string<br/>      unit      = optional(string, "None")<br/>    })<br/>  }))</pre> | `{}` | no |
| metric\_namespaces | Metric namespaces for CloudWatch metrics (only used when enable\_training\_monitoring = true) | `map(string)` | `{}` | no |
| tags | Resource tags | `map(string)` | `{}` | no |
| training\_models | List of training models to monitor (only used when enable\_training\_monitoring = true) | `list(string)` | `[]` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| dashboard\_name | Dashboard name |
| generic\_log\_groups | Generic log groups created |
| metric\_filters | Metric filters created |
| pipeline\_log\_groups | SageMaker default log groups used |
| training\_dashboard\_url | Training monitoring dashboard URL |
| training\_log\_groups | SageMaker default log groups used |
<!-- END_TF_DOCS -->

## File Structure

```
modules/terraform-aws-cloudwatch/
|-- main.tf          # Log groups, dashboards, metric filters (training + generic modes)
|-- outputs.tf       # Dashboard name/URL, log groups, metric filters
|-- README.md        # Module documentation
`-- variables.tf     # Project config, training monitoring, generic monitoring, tags
```
