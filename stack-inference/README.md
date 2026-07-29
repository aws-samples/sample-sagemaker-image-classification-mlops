# stack-inference

Production inference pipeline for medical image classification - SageMaker endpoint, API Gateway, Lambda, CloudFront frontend, auto-deployment, and monitoring.

## What It Does

1. Deploys a SageMaker model and endpoint configuration with data capture and auto-scaling
2. Creates a Lambda function for handling inference API requests with Pillow/NumPy layer for image preprocessing
3. Creates an API Gateway REST API with `/predict` (POST) and `/results/{id}` (GET) endpoints
4. Deploys a static frontend on S3 with CloudFront distribution for the web UI
5. Sets up auto-deployment via EventBridge + Lambda that triggers on Model Registry approval events
6. Configures SageMaker Model Monitor with a data quality job definition and monitoring schedule
7. Creates a CloudWatch inference dashboard with API Gateway, Lambda, SageMaker, and custom prediction metrics
8. Sets up SNS alerts with CloudWatch alarms for API errors, endpoint errors, and latency
9. Creates a composite alarm for overall inference pipeline health
10. Creates CloudWatch log groups for Lambda functions with configurable retention

## Architecture

This root module reads outputs from `training` via `terraform_remote_state` to obtain:

- SageMaker execution role ARN
- Model Package Group name
- S3 bucket names (inference, monitoring, processed data)
- KMS key ARN

The SageMaker endpoint is created by the CI/CD baseline model creation stage and subsequently managed by the auto-deploy Lambda - Terraform manages the model and endpoint configuration but not the endpoint resource itself to avoid conflicts with Lambda-driven updates.

## Prerequisites

1. **stack-training** must be deployed first - this module depends on its remote state outputs
2. The S3 backend bucket must exist with the training state at `training/terraform.tfstate`
3. A Lambda layer ZIP (`lambda-layers/pillow-numpy-layer.zip`) must be built before apply (created by CodeBuild pre_build phase)
4. At least one approved model must exist in the Model Registry for the SageMaker model to reference

## Usage

```bash
cd stack-inference

# Initialize with S3 backend
terraform init

# Review the plan
terraform plan

# Apply
terraform apply
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| terraform | ~> 1.15 |
| aws | ~> 6.0 |
| external | ~> 2.3 |
| random | ~> 3.8 |

## Providers

| Name | Version |
|------|---------|
| aws | ~> 6.0 |
| random | ~> 3.8 |
| terraform | n/a |

## Resources

| Name | Type |
|------|------|
| [aws_bedrock_guardrail.hybrid](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrock_guardrail) | resource |
| [aws_cloudwatch_dashboard.inference_dashboard](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_dashboard) | resource |
| [aws_cloudwatch_event_rule.drift_retrain](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_rule.weekly_endpoint_refresh](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_target.drift_retrain_pipeline](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_event_target.weekly_endpoint_refresh](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_metric_alarm.prediction_drift](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_iam_role.drift_retrain](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.drift_retrain](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_lambda_layer_version.pillow](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_layer_version) | resource |
| [aws_lambda_permission.api_gateway_invoke](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_lambda_permission.eventbridge_invoke_refresher](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_sagemaker_data_quality_job_definition.medical_image_data_quality](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sagemaker_data_quality_job_definition) | resource |
| [aws_sagemaker_monitoring_schedule.medical_image_monitoring](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sagemaker_monitoring_schedule) | resource |
| [random_id.frontend_suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| aws\_region | AWS region | `string` | n/a | yes |
| environment | Environment name | `string` | n/a | yes |
| project\_name | Name of the project | `string` | n/a | yes |
| alert\_email | Email address for alerts | `string` | `""` | no |
| api\_stage\_name | API Gateway stage name | `string` | `"prod"` | no |
| api\_throttling\_burst\_limit | API Gateway stage-wide burst limit - max concurrent requests. | `number` | `50` | no |
| api\_throttling\_rate\_limit | API Gateway stage-wide throttle - requests per second. Low default (20) protects a demo endpoint from bill-inflation attacks. | `number` | `20` | no |
| bedrock\_confidence\_threshold | Predictions with confidence below this route to Bedrock for additional reasoning. 0.70 per the blog. | `number` | `0.7` | no |
| bedrock\_model\_id | Bedrock model id (inference profile) used for low-confidence hybrid reasoning. Nova Pro is multimodal and accepts the base64 image. See https://docs.aws.amazon.com/nova/latest/userguide/modalities-image-examples.html | `string` | `"us.amazon.nova-pro-v1:0"` | no |
| bias\_schedule\_expression | CRON or rate expression for Clarify bias analysis (defaults to daily midnight UTC) | `string` | `"cron(0 0 * * ? *)"` | no |
| data\_capture\_sampling\_percentage | Percentage of data to capture for monitoring (0-100) | `number` | `100` | no |
| deployment\_max\_timeout | Maximum deployment timeout in seconds (600-14400) | `number` | `3600` | no |
| dlc\_ecr\_registry | ECR registry hostname for the AWS Deep Learning Containers. Defaults to commercial-region canonical DLC registry. Override for GovCloud/CN: see https://github.com/aws/deep-learning-containers/blob/master/available_images.md | `string` | `""` | no |
| dlc\_source\_repository | DLC repository name to pull and patch (e.g. tensorflow-inference, pytorch-inference) | `string` | `"tensorflow-inference"` | no |
| drift\_alarm\_period | Evaluation period (seconds) for the drift alarm. Should be >= the monitoring schedule interval (hourly = 3600) so each scheduled monitor run produces one data point. | `number` | `3600` | no |
| drift\_feature\_name | Feature name whose feature\_baseline\_drift\_<name> CloudWatch metric the drift alarm watches. For an image model only the model output is monitored, so this is the prediction score column from the output-only baseline. | `string` | `"prediction_score"` | no |
| drift\_threshold | Model Monitor baseline-drift value (on the prediction-score distribution) above which the drift alarm fires and retraining is triggered. Matches the constraints baseline emit threshold. | `number` | `0.2` | no |
| enable\_async\_explainability | When true, the inference response includes a pointer to where the asynchronous Grad-CAM/SHAP explainability artifact is written (Part 4). The artifact itself is produced by an async job; the API Lambda cannot run Grad-CAM inline (no TF runtime / conv-layer access in the served ensemble). | `bool` | `false` | no |
| enable\_bedrock\_hybrid\_inference | When true, the inference Lambda routes low-confidence predictions to an Amazon Bedrock foundation model for additional reasoning and a natural-language explanation (Part 3 hybrid inference). Adds bedrock:InvokeModel to the Lambda role. | `bool` | `false` | no |
| enable\_bias\_monitoring | Enable SageMaker Clarify bias monitoring schedule | `bool` | `true` | no |
| enable\_human\_review | When true, create the A2I human-review flow and let the inference Lambda route low-confidence predictions to a radiologist review queue (Part 4 human-in-the-loop). Requires review\_workteam\_arn for the flow definition to be created. | `bool` | `false` | no |
| enable\_model\_monitor | Enable the SageMaker Model Monitor data-quality schedule (drift detection on the prediction-score distribution). Always off for serverless endpoints, which do not support data capture. | `bool` | `true` | no |
| endpoint\_initial\_instance\_count | Initial number of instances for SageMaker endpoint | `number` | `1` | no |
| endpoint\_instance\_type | Instance type for SageMaker endpoint | `string` | `"ml.m5.xlarge"` | no |
| endpoint\_max\_capacity | Maximum number of instances for auto-scaling | `number` | `3` | no |
| endpoint\_min\_capacity | Minimum number of instances for auto-scaling | `number` | `1` | no |
| inference\_lambda\_reserved\_concurrency | Reserved concurrent executions for the inference API Lambda. Caps blast-radius of a traffic spike on /predict and prevents starvation of other functions in the account. -1 = unreserved (account default). | `number` | `50` | no |
| lambda\_memory\_size | Lambda function memory size in MB | `number` | `1024` | no |
| lambda\_timeout | Lambda function timeout in seconds | `number` | `300` | no |
| log\_retention\_days | CloudWatch log retention in days | `number` | `14` | no |
| max\_image\_bytes | Max size of a base64-encoded image accepted by the /predict endpoint. Images above this size return HTTP 413 without invoking SageMaker. Default 5 MB is generous for 224x224 histopathology. | `number` | `5242880` | no |
| model\_monitor\_config | Model Monitor configuration | <pre>object({<br/>    setup_on_deploy        = bool<br/>    data_quality_schedule  = string<br/>    model_quality_schedule = string<br/>    instance_type          = string<br/>    volume_size            = number<br/>    max_runtime            = number<br/>  })</pre> | <pre>{<br/>  "data_quality_schedule": "cron(0 * * * ? *)",<br/>  "instance_type": "ml.m5.xlarge",<br/>  "max_runtime": 3600,<br/>  "model_quality_schedule": "cron(0 */6 * * ? *)",<br/>  "setup_on_deploy": true,<br/>  "volume_size": 30<br/>}</pre> | no |
| patched\_image\_source\_tag | DLC source tag to base the patched inference image on. Use the floating major.minor tag (no -v1.X suffix) to auto-pick up the latest AWS patch version. | `string` | `"2.19.0-cpu-py312-ubuntu22.04-sagemaker"` | no |
| review\_workteam\_arn | ARN of the SageMaker private workteam that reviews flagged cases. The private workforce is a one-time per-account Cognito setup outside this codebase. Empty = task UI is created but no flow definition (no review queue). | `string` | `""` | no |
| serverless\_max\_concurrency | Maximum concurrent invocations per serverless variant (1-200). | `number` | `10` | no |
| serverless\_memory\_size\_mb | Memory (MB) per serverless inference worker. Valid values: 1024, 2048, 3072, 4096, 5120, 6144. | `number` | `3072` | no |
| target\_concurrent\_requests\_per\_model | Target concurrent in-flight requests per model container. Uses the SageMaker high-resolution metric (10s granularity) for sub-minute scale-out. | `number` | `5` | no |
| termination\_wait\_seconds | Seconds to wait after deployment before terminating old fleet | `number` | `120` | no |
| use\_serverless\_inference | Opt-in flag to deploy the endpoint as a SageMaker Serverless Inference<br/>variant instead of an always-on instance. Recommended for low-traffic<br/>demo/blog endpoints: scales to zero when idle and can cut the monthly<br/>bill from ~$170 to ~$5-10. Not recommended when Model Monitor data<br/>capture or strict p50 latency matter - see the sagemaker-endpoint<br/>module README for the full tradeoff list. | `bool` | `false` | no |

## Outputs

| Name | Description |
|------|-------------|
| api\_gateway\_url | API Gateway URL for inference |
| auto\_deployment\_eventbridge\_rule | Name of the EventBridge rule for auto-deployment |
| auto\_deployment\_lambda\_arn | ARN of the auto-deployment Lambda function |
| dashboard\_url | CloudWatch inference dashboard URL |
| endpoint\_arn | ARN of the SageMaker endpoint |
| endpoint\_error\_rate\_alarm\_arn | ARN of the CloudWatch alarm for endpoint error rate |
| endpoint\_error\_rate\_alarm\_name | Name of the CloudWatch alarm for endpoint error rate (used for auto-rollback) |
| endpoint\_latency\_alarm\_arn | ARN of the CloudWatch alarm for endpoint latency |
| endpoint\_latency\_alarm\_name | Name of the CloudWatch alarm for endpoint latency (used for auto-rollback) |
| endpoint\_name | Name of the SageMaker endpoint |
| frontend\_cloudfront\_distribution\_id | CloudFront distribution ID for cache invalidation |
| frontend\_cloudfront\_url | CloudFront URL for frontend |
| frontend\_s3\_bucket | S3 bucket name for frontend |
| inference\_bucket\_name | S3 bucket name for inference data |
| lambda\_function\_names | Lambda function names |
| log\_groups | CloudWatch log group names |
| sns\_topic\_arn | SNS topic ARN for alerts |
<!-- END_TF_DOCS -->

## File Structure

```
stack-inference/
├── backend.tf                  # S3 backend configuration for Terraform state
├── data.tf                     # Remote state, SageMaker ECR image, Lambda layer, locals
├── deploy-frontend.sh          # Script to deploy frontend assets
├── lambda/                     # Lambda function source code
│   ├── inference_handler.py    # Inference API request handler
│   └── requirements.txt        # Python dependencies for Lambda
├── lambda-layers/              # Lambda layer build artifacts
│   ├── .gitkeep                # Placeholder for git tracking
│   ├── python/                 # Layer Python packages (built by CodeBuild)
│   └── requirements.txt        # Layer dependencies (Pillow, NumPy)
├── main.tf                     # Module calls, dashboard, API GW permission, log groups, frontend
├── monitoring.tf               # SageMaker Model Monitor job definition and schedule
├── outputs.tf                  # API URL, bucket names, Lambda names, alarms, frontend URL
├── static-frontend/            # Frontend template files
│   └── index.html.tpl          # HTML template with API URL injection
├── terraform.tfvars            # Variable values for this environment
├── variables.tf                # All input variables
└── versions.tf                 # Terraform and provider version constraints
```
