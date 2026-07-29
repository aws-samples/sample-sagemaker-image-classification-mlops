# auto-deployment

EventBridge-triggered Lambda that repoints a SageMaker endpoint to a newly-approved model. SageMaker runs the blue/green rollout + auto-rollback natively using the endpoint's declared `deployment_config`.

## What It Does

1. EventBridge rule listens for `SageMaker Model Package State Change` events with `ModelApprovalStatus=Approved`
2. Lambda creates a fresh `aws_sagemaker_model` + `aws_sagemaker_endpoint_configuration` from the approved model package
3. Lambda calls `UpdateEndpoint` - SageMaker applies the endpoint's existing `deployment_config` (blue/green + auto-rollback)
4. CloudWatch log group for Lambda logs (14-day retention)
5. CloudWatch alarm fires SNS on Lambda errors

The Lambda owns `endpoint_config_name` on the endpoint; Terraform owns everything else.

## Patched Image Path

If `patched_image_uri` is non-empty, the Lambda swaps the public DLC image for that private ECR URI while keeping the model artefact from the approved model package.

## Inputs

| Name                     | Description                                                        | Type          | Default          | Required |
| ------------------------ | ------------------------------------------------------------------ | ------------- | ---------------- | -------- |
| project_name             | Name of the project                                                | `string`      | n/a              | yes      |
| model_package_group_name | Name of the SageMaker model package group                          | `string`      | n/a              | yes      |
| endpoint_name            | Name of the SageMaker endpoint to update                           | `string`      | n/a              | yes      |
| endpoint_instance_type   | EC2 instance type for the endpoint production variant              | `string`      | `"ml.m5.xlarge"` | no       |
| sagemaker_role_arn       | ARN of the SageMaker execution role                                | `string`      | n/a              | yes      |
| monitoring_bucket        | S3 bucket for data capture                                         | `string`      | n/a              | yes      |
| patched_image_uri        | ECR URI of a CVE-patched inference image (empty to use public DLC) | `string`      | `""`             | no       |
| sns_topic_arn            | SNS topic for deployment-failure alarms                            | `string`      | `null`           | no       |
| tags                     | Tags to apply to resources                                         | `map(string)` | `{}`             | no       |


<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| terraform | ~> 1.15 |
| archive | ~> 2.0 |
| aws | ~> 6.0 |

## Providers

| Name | Version |
|------|---------|
| archive | ~> 2.0 |
| aws | ~> 6.0 |

## Resources

| Name | Type |
|------|------|
| [aws_cloudwatch_event_rule.model_approved](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_target.deploy_lambda](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_log_group.auto_deploy_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_metric_alarm.deployment_failure](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.dlq_visible](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_iam_role.auto_deploy_lambda_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.auto_deploy_lambda_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_lambda_function.auto_deploy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_lambda_permission.allow_eventbridge](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_sqs_queue.dlq](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| endpoint\_name | Name of the SageMaker endpoint to update | `string` | n/a | yes |
| model\_package\_group\_name | Name of the SageMaker model package group | `string` | n/a | yes |
| monitoring\_bucket | Name of the monitoring S3 bucket for data capture | `string` | n/a | yes |
| project\_name | Name of the project | `string` | n/a | yes |
| sagemaker\_role\_arn | ARN of the SageMaker execution role | `string` | n/a | yes |
| data\_capture\_sampling\_percentage | Percentage of endpoint invocations captured for Model Monitor | `number` | `100` | no |
| endpoint\_instance\_type | EC2 instance type for the endpoint production variant | `string` | `"ml.m5.xlarge"` | no |
| env\_kms\_key\_arn | KMS CMK ARN used to encrypt Lambda environment variables. Null = AWS-managed key (still encrypted). | `string` | `null` | no |
| log\_kms\_key\_arn | KMS key ARN used to encrypt the CloudWatch log group. Null = no customer-managed encryption (logs still encrypted at rest with AWS-managed key). | `string` | `null` | no |
| log\_retention\_days | CloudWatch log retention in days for the auto-deployment Lambda | `number` | `14` | no |
| patched\_image\_uri | ECR URI (optional) of a CVE-patched inference image. When set, the auto-deployer swaps the public DLC image for this one on every deployment. | `string` | `""` | no |
| serverless\_max\_concurrency | Max concurrent invocations per serverless variant when use\_serverless\_inference = true. | `number` | `10` | no |
| serverless\_memory\_size\_mb | Memory (MB) per serverless worker when use\_serverless\_inference = true. | `number` | `3072` | no |
| sns\_topic\_arn | ARN of SNS topic for alerts (optional) | `string` | `null` | no |
| tags | Tags to apply to resources | `map(string)` | `{}` | no |
| use\_serverless\_inference | When true, the auto-deploy Lambda creates serverless endpoint configs instead of instance-based ones. Must match the endpoint module's flag. | `bool` | `false` | no |

## Outputs

| Name | Description |
|------|-------------|
| eventbridge\_rule\_arn | ARN of the EventBridge rule |
| eventbridge\_rule\_name | Name of the EventBridge rule |
| lambda\_function\_arn | ARN of the auto-deployment Lambda function |
| lambda\_function\_name | Name of the auto-deployment Lambda function |
<!-- END_TF_DOCS -->
