# auto-deployment

EventBridge-triggered Lambda that repoints a SageMaker endpoint to a newly-approved model. SageMaker runs the blue/green rollout + auto-rollback natively using the endpoint's declared `deployment_config`.

## What It Does

1. EventBridge rule listens for `SageMaker Model Package State Change` events with `ModelApprovalStatus=Approved`
2. The Lambda checks that the package belongs to the expected group, then creates a SageMaker model and endpoint configuration for it through the SageMaker API
3. The Lambda calls `UpdateEndpoint`; SageMaker applies the endpoint's blue/green deployment and auto-rollback configuration. If the update call fails, the Lambda deletes the model and configuration it created
4. Failed asynchronous invocations go to a KMS-encrypted SQS dead-letter queue, with an alarm on queue depth
5. A CloudWatch log group (`log_retention_days`) and an alarm that notifies SNS on Lambda errors

The Lambda logs only identifiers (package ARN, artefact URI, model and config names), not the full event. It changes only `endpoint_config_name` on the endpoint, which the endpoint module ignores; Terraform owns everything else. The rule exists only once `stack-inference` is applied, so approving the placeholder baseline before the first inference deploy does not invoke it.

## Serving Image

If `serving_image_uri` is set (the patched image, pinned by digest), the Lambda runs the approved package's artefact and environment on that image. Pass the same value to the endpoint module so Terraform-created and auto-deployed models share one image. Data capture mirrors the endpoint module: Output only unless `data_capture_input = true`.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | ~> 1.15 |
| archive | ~> 2.0 |
| aws | ~> 6.0 |

## Providers

| Name | Version |
| ---- | ------- |
| archive | ~> 2.0 |
| aws | ~> 6.0 |

## Resources

| Name | Type |
| ---- | ---- |
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
| ---- | ----------- | ---- | ------- | :------: |
| endpoint\_name | Name of the SageMaker endpoint to update | `string` | n/a | yes |
| model\_package\_group\_name | Name of the SageMaker model package group | `string` | n/a | yes |
| monitoring\_bucket | Name of the monitoring S3 bucket for data capture | `string` | n/a | yes |
| project\_name | Name of the project | `string` | n/a | yes |
| sagemaker\_role\_arn | ARN of the SageMaker execution role | `string` | n/a | yes |
| artifacts\_kms\_key\_arn | KMS key that encrypts the model artefacts and monitoring buckets, for the baseline copy. Null when they use SSE-S3. | `string` | `null` | no |
| data\_capture\_input | Also capture request payloads in auto-deployed endpoint configs. Must match the endpoint module (default false: Output only). | `bool` | `false` | no |
| data\_capture\_sampling\_percentage | Percentage of endpoint invocations captured for drift detection. Must match the endpoint module. | `number` | `100` | no |
| drift\_baseline\_key | Object key in the monitoring bucket that the drift job reads its baseline scores from. | `string` | `"monitoring/baselines/output-only/statistics.json"` | no |
| endpoint\_instance\_type | EC2 instance type for the endpoint production variant | `string` | `"ml.m5.xlarge"` | no |
| env\_kms\_key\_arn | KMS CMK ARN used to encrypt Lambda environment variables. Null = AWS-managed key (still encrypted). | `string` | `null` | no |
| log\_kms\_key\_arn | KMS key ARN used to encrypt the CloudWatch log group. Null = no customer-managed encryption (logs still encrypted at rest with AWS-managed key). | `string` | `null` | no |
| log\_retention\_days | CloudWatch log retention in days for the auto-deployment Lambda | `number` | `14` | no |
| model\_artifacts\_bucket | Bucket holding the ensemble artefacts. After each deploy the Lambda copies the package's predictions.json (next to model.tar.gz) from here to drift\_baseline\_key in the monitoring bucket. Empty disables the baseline refresh. | `string` | `""` | no |
| permissions\_boundary\_arn | ARN of the permissions boundary attached to the IAM roles this module creates. null leaves them unbounded. | `string` | `null` | no |
| serverless\_max\_concurrency | Max concurrent invocations per serverless variant when use\_serverless\_inference = true. | `number` | `10` | no |
| serverless\_memory\_size\_mb | Memory (MB) per serverless worker when use\_serverless\_inference = true. | `number` | `3072` | no |
| serving\_image\_uri | Inference image every auto-deployed model runs on, pinned by digest. Pass the same value as the endpoint module's serving\_image\_uri so Terraform-created and auto-deployed models share one image. Empty = use the image recorded in the model package. | `string` | `""` | no |
| sns\_topic\_arn | ARN of SNS topic for alerts (optional) | `string` | `null` | no |
| tags | Tags to apply to resources | `map(string)` | `{}` | no |
| use\_serverless\_inference | When true, the auto-deploy Lambda creates serverless endpoint configs instead of instance-based ones. Must match the endpoint module's flag. | `bool` | `false` | no |
| volume\_kms\_key\_arn | KMS key ARN for the ML storage volume of the endpoint configs the Lambda creates (real-time mode). Null leaves the volume on the SageMaker default key. | `string` | `null` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| eventbridge\_rule\_arn | ARN of the EventBridge rule |
| eventbridge\_rule\_name | Name of the EventBridge rule |
| lambda\_function\_arn | ARN of the auto-deployment Lambda function |
| lambda\_function\_name | Name of the auto-deployment Lambda function |
<!-- END_TF_DOCS -->
