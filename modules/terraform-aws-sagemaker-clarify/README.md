# sagemaker-clarify

SageMaker Clarify bias monitoring schedule for a production endpoint.

## What It Does

1. Provisions a SageMaker monitoring schedule that runs Clarify against live endpoint traffic
2. Creates the associated data-quality job definition bound to the Clarify container image
3. Writes bias-metric reports (pre-training and post-training) to the configured S3 bucket
4. Emits results under `s3://<results_bucket>/bias-reports/` on the configured cron

## CI

Consumed from `stack-inference/` alongside the endpoint module when `enable_bias_monitoring = true`.

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
| [aws_sagemaker_data_quality_job_definition.bias](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sagemaker_data_quality_job_definition) | resource |
| [aws_sagemaker_monitoring_schedule.bias](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sagemaker_monitoring_schedule) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| bias\_monitoring\_name | Name for the Clarify bias monitoring schedule | `string` | n/a | yes |
| clarify\_image\_uri | SageMaker Clarify container image URI | `string` | n/a | yes |
| endpoint\_name | SageMaker endpoint to monitor | `string` | n/a | yes |
| execution\_role\_arn | IAM role ARN used by Clarify processing jobs | `string` | n/a | yes |
| kms\_key\_arn | KMS key ARN for encrypting output artifacts | `string` | n/a | yes |
| results\_bucket | S3 bucket where bias analysis outputs are written | `string` | n/a | yes |
| baseline\_constraints\_s3\_uri | S3 URI of the baseline constraints.json file. When empty, no baseline is configured. | `string` | `""` | no |
| baseline\_statistics\_s3\_uri | S3 URI of the baseline statistics.json file. When empty, no baseline is configured. | `string` | `""` | no |
| bias\_schedule\_expression | CRON or rate expression for scheduling bias analysis | `string` | `"cron(0 0 * * ? *)"` | no |
| enable\_bias\_monitoring | Whether to create the Clarify bias monitoring schedule | `bool` | `true` | no |
| job\_max\_runtime\_seconds | Maximum runtime for a single Clarify job | `number` | `3600` | no |
| label\_column | Name of the label column (or 'prediction' for output bias) | `string` | `"prediction"` | no |
| processing\_instance\_type | Instance type for Clarify processing jobs | `string` | `"ml.m5.xlarge"` | no |
| tags | Tags applied to all resources | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| job\_definition\_arn | ARN of the Clarify data quality job definition |
| monitoring\_schedule\_arn | ARN of the Clarify bias monitoring schedule |
| monitoring\_schedule\_name | Name of the Clarify bias monitoring schedule |
<!-- END_TF_DOCS -->

## File Structure

```
modules/terraform-aws-sagemaker-clarify/
├── main.tf        # Monitoring schedule + data-quality job definition
├── variables.tf   # Inputs
├── outputs.tf     # Outputs
└── README.md      # This file
```
