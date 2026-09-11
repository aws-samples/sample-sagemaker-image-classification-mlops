# sagemaker-endpoint

SageMaker model, endpoint configuration, CloudWatch alarms, and auto-scaling for real-time inference. Optionally switches to **Serverless Inference** for low-traffic endpoints.

## What It Does

1. Fetches the latest approved model package from SageMaker Model Registry via an external data source
2. Creates a SageMaker Model using the approved model's container image and model data URL
3. Creates a SageMaker Endpoint Configuration - either real-time (with data capture enabled for drift detection) or serverless (scales to zero)
4. Creates CloudWatch alarms for endpoint error rate (4XX errors) and latency monitoring, wired to the endpoint's auto-rollback configuration
5. Creates an Application Auto Scaling target and target-tracking scaling policy (skipped in serverless mode - serverless scales via `max_concurrency`)

## Inference Modes

### Real-time (default)

`use_serverless_inference = false` (default) - provisioned `ml.m5.xlarge` (or whatever `instance_type` you set) runs 24/7. Full data-capture + drift-detection + auto-scaling support. ~$168/month baseline at 1 instance.

Best for:

- Production workloads with steady traffic
- Use cases requiring strict p50 latency (< 200ms)
- Regulated / clinical deployments where data-capture audit is required
- Any case where data capture or drift detection matters

### Serverless (opt-in)

Set `use_serverless_inference = true` - SageMaker provisions workers per request and scales to zero when idle. Pay per millisecond of inference time. For a blog demo with <1000 requests/day this drops the bill to **~$5-10/month** (90%+ savings).

**You lose**:

- **Data capture**: serverless variants do not support `DataCaptureConfig`, so the scheduled drift job is skipped when serverless is enabled (see `stack-inference/monitoring.tf`). If you need drift detection in serverless mode, log predictions from your inference handler into S3 yourself.
- **Weekly endpoint OS refresh**: no long-lived host to refresh; serverless workers are short-lived by design.
- **Application Auto Scaling**: not supported on serverless variants. Tuning happens via `serverless_max_concurrency`.
- **p50 latency guarantees**: cold starts are 1-5 seconds after idle periods. The first request after an idle window pays this tax; subsequent requests in the same window are fast.

**You get**:

- Scale to zero when idle - huge cost savings for bursty / demo workloads
- Same invocation API (boto3 `invoke_endpoint`), same Lambda integration, no client changes
- No auto-scaling to tune

**Constraints**:

- `serverless_memory_size_mb` must be one of: 1024, 2048, 3072, 4096, 5120, 6144
- `serverless_max_concurrency` must be 1-200 per variant
- Max request payload: 4 MB
- Max invocation duration: 60 seconds

When opting in, the auto-deploy Lambda also switches its endpoint-config creation to serverless mode - see `modules/terraform-aws-auto-deployment/auto_deploy_handler.py` for the `USE_SERVERLESS_INFERENCE` env var.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| terraform | ~> 1.15 |
| aws | ~> 6.0 |
| external | ~> 2.0 |

## Providers

| Name | Version |
|------|---------|
| aws | ~> 6.0 |
| external | ~> 2.0 |

## Resources

| Name | Type |
|------|------|
| [aws_appautoscaling_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/appautoscaling_policy) | resource |
| [aws_appautoscaling_target.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/appautoscaling_target) | resource |
| [aws_cloudwatch_metric_alarm.endpoint_error_rate](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.endpoint_latency](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_sagemaker_endpoint.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sagemaker_endpoint) | resource |
| [aws_sagemaker_endpoint_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sagemaker_endpoint_configuration) | resource |
| [aws_sagemaker_model.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sagemaker_model) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| aws\_region | AWS region for SageMaker API calls | `string` | n/a | yes |
| endpoint\_name | Name of the SageMaker endpoint | `string` | n/a | yes |
| execution\_role\_arn | ARN of the IAM execution role for SageMaker | `string` | n/a | yes |
| model\_package\_group\_name | Name of the SageMaker Model Package Group | `string` | n/a | yes |
| monitoring\_bucket | S3 bucket name for data capture and monitoring output | `string` | n/a | yes |
| project\_name | Name of the project | `string` | n/a | yes |
| data\_capture\_sampling\_percentage | Percentage of data to capture for monitoring (0-100) | `number` | `100` | no |
| deployment\_max\_timeout | Maximum deployment timeout in seconds (600-14400) | `number` | `3600` | no |
| error\_rate\_threshold | Error rate threshold percentage for the CloudWatch alarm | `number` | `5` | no |
| initial\_instance\_count | Initial number of instances for the endpoint | `number` | `1` | no |
| initial\_variant\_weight | Initial traffic weight for the primary production variant. With one variant this is always 100% of traffic; exposing it lets callers add a weighted canary variant and shift traffic via update\_endpoint\_weights\_and\_capacities. | `number` | `1` | no |
| instance\_type | Instance type for the SageMaker endpoint | `string` | `"ml.m5.xlarge"` | no |
| latency\_threshold | Latency threshold in milliseconds for the CloudWatch alarm | `number` | `30000` | no |
| max\_capacity | Maximum number of instances for auto-scaling | `number` | `3` | no |
| min\_capacity | Minimum number of instances for auto-scaling | `number` | `1` | no |
| serverless\_max\_concurrency | Maximum concurrent invocations per serverless variant (1-200). Only used when use\_serverless\_inference = true. | `number` | `10` | no |
| serverless\_memory\_size\_mb | Memory (MB) allocated per serverless inference request. Valid values: 1024, 2048, 3072, 4096, 5120, 6144. Only used when use\_serverless\_inference = true. | `number` | `3072` | no |
| shadow\_model\_name | Name of an existing SageMaker model to run as a shadow variant (Part 3 shadow testing). The shadow receives a copy of production traffic but its predictions are not returned to callers. Null = no shadow variant. Real-time only. | `string` | `null` | no |
| tags | Tags to apply to all resources | `map(string)` | `{}` | no |
| target\_concurrent\_requests\_per\_model | Target concurrent in-flight requests per model container. Uses the SageMaker high-resolution metric (10s granularity) for sub-minute scale-out detection. | `number` | `5` | no |
| termination\_wait\_seconds | Seconds to wait after deployment before terminating old fleet | `number` | `120` | no |
| traffic\_shift\_wait\_interval | Wait interval in seconds between each linear traffic shift step | `number` | `60` | no |
| use\_serverless\_inference | When true, provision a SageMaker Serverless Inference variant instead of<br/>an instance-based real-time variant. Serverless scales to zero when idle<br/>(large cost savings for low-traffic endpoints like a blog demo) but loses<br/>several features:<br/><br/>  - No DataCaptureConfig on the endpoint config (drift detection cannot<br/>    read captured payloads; your inference handler must log predictions<br/>    itself if drift detection matters).<br/>  - No Application Auto Scaling (scales internally via max\_concurrency).<br/>  - Cold starts of 1-5 seconds after idle periods.<br/>  - Max memory = 6 GB, max concurrent requests per variant = 200.<br/><br/>Default is false to preserve the project's compliance/monitoring story.<br/>Opt in only when the cost win outweighs these tradeoffs. | `bool` | `false` | no |
| volume\_kms\_key\_arn | KMS key ARN used to encrypt the ML storage volume attached to real-time (instance-based) inference variants. The volume buffers the model artifact and in-flight inference data (potential PHI for a medical model), so it should use the project CMK rather than the AWS-managed default key. Ignored for serverless variants, which do not attach a volume. Null falls back to the default key. | `string` | `null` | no |

## Outputs

| Name | Description |
|------|-------------|
| autoscaling\_target\_resource\_id | Resource ID of the auto-scaling target (null when running in serverless mode) |
| endpoint\_arn | ARN of the SageMaker endpoint |
| endpoint\_config\_name | Name of the SageMaker endpoint configuration |
| endpoint\_name | Name of the SageMaker endpoint |
| error\_rate\_alarm\_arn | ARN of the endpoint error rate CloudWatch alarm |
| error\_rate\_alarm\_name | Name of the endpoint error rate CloudWatch alarm |
| latency\_alarm\_arn | ARN of the endpoint latency CloudWatch alarm |
| latency\_alarm\_name | Name of the endpoint latency CloudWatch alarm |
| model\_name | Name of the SageMaker model |
<!-- END_TF_DOCS -->

## File Structure

```
modules/terraform-aws-sagemaker-endpoint/
├── main.tf          # External data source, SageMaker model/config, CloudWatch alarms, auto-scaling
├── outputs.tf       # Model name, endpoint config/name, alarm ARNs/names, scaling target ID
└── variables.tf     # Project name, endpoint config, scaling, alarm thresholds, tags
```
