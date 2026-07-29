# api-gateway

REST API Gateway with Lambda proxy integration, CORS support, and binary media types for image uploads.

## What It Does

1. Creates an API Gateway REST API with binary media type support (JPEG, PNG, octet-stream)
2. Creates `/predict` resource with POST method and Lambda proxy integration
3. Creates `/results/{id}` resource with GET method and Lambda proxy integration
4. Configures CORS preflight (OPTIONS) on `/predict` with configurable allowed origins
5. Deploys the API to a named stage

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
| [aws_api_gateway_account.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_account) | resource |
| [aws_api_gateway_deployment.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_deployment) | resource |
| [aws_api_gateway_integration.predict_integration](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_integration) | resource |
| [aws_api_gateway_integration.predict_options_integration](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_integration) | resource |
| [aws_api_gateway_integration.results_integration](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_integration) | resource |
| [aws_api_gateway_integration_response.predict_options_integration_response](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_integration_response) | resource |
| [aws_api_gateway_integration_response.predict_post_integration_response](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_integration_response) | resource |
| [aws_api_gateway_method.predict_options](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_method) | resource |
| [aws_api_gateway_method.predict_post](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_method) | resource |
| [aws_api_gateway_method.results_get](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_method) | resource |
| [aws_api_gateway_method_response.predict_options_response](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_method_response) | resource |
| [aws_api_gateway_method_response.predict_post_response](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_method_response) | resource |
| [aws_api_gateway_method_settings.all](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_method_settings) | resource |
| [aws_api_gateway_model.predict_request](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_model) | resource |
| [aws_api_gateway_request_validator.body](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_request_validator) | resource |
| [aws_api_gateway_resource.predict](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_resource) | resource |
| [aws_api_gateway_resource.results](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_resource) | resource |
| [aws_api_gateway_resource.results_id](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_resource) | resource |
| [aws_api_gateway_rest_api.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_rest_api) | resource |
| [aws_api_gateway_stage.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_stage) | resource |
| [aws_api_gateway_usage_plan.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_usage_plan) | resource |
| [aws_cloudwatch_log_group.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_iam_role.apigw_cloudwatch](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.apigw_cloudwatch](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| api\_name | Name of the API Gateway | `string` | n/a | yes |
| lambda\_function\_arn | ARN of the Lambda function to integrate with | `string` | n/a | yes |
| stage\_name | Stage name for API Gateway deployment | `string` | n/a | yes |
| cors\_origins | List of allowed CORS origins | `list(string)` | <pre>[<br/>  "*"<br/>]</pre> | no |
| create\_usage\_plan | Create an API Gateway usage plan. Enables per-API-key quotas and throttles for authenticated clients. | `bool` | `false` | no |
| enable\_access\_logging | Create a CloudWatch Logs destination for API Gateway access logs and wire up the IAM role + account settings required to write to it. | `bool` | `true` | no |
| enable\_xray\_tracing | Enable AWS X-Ray tracing on the API Gateway stage. Lets you see end-to-end latency from API GW through Lambda to SageMaker. | `bool` | `true` | no |
| log\_kms\_key\_arn | Optional KMS key ARN for encrypting the access log group | `string` | `null` | no |
| log\_retention\_days | Retention in days for the API Gateway access log group | `number` | `90` | no |
| tags | Tags to apply to resources | `map(string)` | `{}` | no |
| throttling\_burst\_limit | Stage-wide throttling burst limit (max concurrent requests in a short burst) | `number` | `50` | no |
| throttling\_rate\_limit | Stage-wide throttling rate limit (requests per second across all methods) | `number` | `20` | no |
| usage\_plan\_burst\_limit | Per-client burst limit when usage plan is enabled | `number` | `20` | no |
| usage\_plan\_quota\_limit | Per-client quota - maximum requests in the `usage_plan_quota_period` | `number` | `10000` | no |
| usage\_plan\_quota\_period | Quota period for usage plan - DAY / WEEK / MONTH | `string` | `"MONTH"` | no |
| usage\_plan\_rate\_limit | Per-client rate limit (req/sec) when usage plan is enabled | `number` | `10` | no |

## Outputs

| Name | Description |
|------|-------------|
| api\_id | ID of the API Gateway |
| api\_name | Name of the API Gateway |
| execution\_arn | Execution ARN of the API Gateway |
| invoke\_url | Invoke URL of the API Gateway |
| stage\_name | Stage name of the deployment |
<!-- END_TF_DOCS -->

## File Structure

```
modules/terraform-aws-api-gateway/
├── data.tf          # AWS region data source
├── main.tf          # REST API, resources, methods, integrations, CORS, deployment, stage
├── outputs.tf       # API name, ID, execution ARN, invoke URL, stage name
└── variables.tf     # API name, stage name, Lambda ARN, CORS origins, tags
```
