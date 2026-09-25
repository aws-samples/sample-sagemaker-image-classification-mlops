# api-gateway

REST API Gateway with Lambda proxy integration, CORS support, and binary media types for image uploads.

## What It Does

1. Creates an API Gateway REST API with binary media type support (JPEG, PNG, octet-stream)
2. Creates `/predict` resource with POST method and Lambda proxy integration
3. Creates `/results/{id}` resource with GET method and Lambda proxy integration
4. Configures CORS for one allowed origin (`cors_allowed_origin`), including gateway responses so 403/429 reach the browser
5. Requires an API key (`require_api_key`, default `true`) attached to a usage plan with per-key throttle and quota
6. Associates a regional AWS WAF web ACL (`enable_waf`, default `true`): AWS managed common rule set (body size rule set to count, because `/predict` carries a base64 image), known-bad-inputs rule set and a per-IP rate-based rule; WAF logs go to CloudWatch with `x-api-key` redacted
7. Deploys the API to a named stage with access logs, X-Ray and stage throttling; the deployment is re-created when methods or integrations change

The API key meters and limits callers, but it ships in the static frontend, so it is not authentication. To authenticate users set `authorization_type = "AWS_IAM"` (SigV4, `execute-api:Invoke`) or `authorization_type = "COGNITO_USER_POOLS"` with `cognito_user_pool_arns`.

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
| [aws_api_gateway_account.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_account) | resource |
| [aws_api_gateway_api_key.frontend](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_api_key) | resource |
| [aws_api_gateway_authorizer.cognito](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_authorizer) | resource |
| [aws_api_gateway_deployment.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_deployment) | resource |
| [aws_api_gateway_gateway_response.cors](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_gateway_response) | resource |
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
| [aws_api_gateway_usage_plan_key.frontend](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_usage_plan_key) | resource |
| [aws_cloudwatch_log_group.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_group.waf](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_iam_role.apigw_cloudwatch](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.apigw_cloudwatch](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_wafv2_web_acl.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/wafv2_web_acl) | resource |
| [aws_wafv2_web_acl_association.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/wafv2_web_acl_association) | resource |
| [aws_wafv2_web_acl_logging_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/wafv2_web_acl_logging_configuration) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| api\_name | Name of the API Gateway | `string` | n/a | yes |
| cors\_allowed\_origin | Origin returned in Access-Control-Allow-Origin, for example https://d111111abcdef8.cloudfront.net. Only this origin can call the API from a browser. | `string` | n/a | yes |
| lambda\_function\_arn | ARN of the Lambda function to integrate with | `string` | n/a | yes |
| stage\_name | Stage name for API Gateway deployment | `string` | n/a | yes |
| authorization\_type | Method authorization for POST /predict and GET /results/{id}.<br/>"NONE" (default) relies on the API key, usage plan and WAF only: the key<br/>meters callers but is public once it ships in the static frontend.<br/>To authenticate users instead:<br/>  - "AWS\_IAM": callers sign requests with SigV4; grant execute-api:Invoke<br/>    on this API's execution ARN to the calling role (for a browser, use<br/>    Cognito identity pool credentials).<br/>  - "COGNITO\_USER\_POOLS": set cognito\_user\_pool\_arns; callers send the user<br/>    pool ID token in the Authorization header.<br/>Both can be combined with require\_api\_key. | `string` | `"NONE"` | no |
| cognito\_user\_pool\_arns | Cognito user pool ARNs for the COGNITO\_USER\_POOLS authorizer. Required when authorization\_type = "COGNITO\_USER\_POOLS". | `list(string)` | `[]` | no |
| create\_usage\_plan | Create the usage plan even when require\_api\_key = false. The plan is always created when an API key is required. | `bool` | `true` | no |
| enable\_access\_logging | Create a CloudWatch Logs destination for API Gateway access logs and wire up the IAM role + account settings required to write to it. | `bool` | `true` | no |
| enable\_waf | Associate a regional AWS WAF web ACL with the stage: AWS managed common and known-bad-inputs rule sets plus a per-IP rate-based rule. WAF logs go to a CloudWatch log group with the x-api-key header redacted. | `bool` | `true` | no |
| enable\_xray\_tracing | Enable AWS X-Ray tracing on the API Gateway stage. Lets you see end-to-end latency from API GW through Lambda to SageMaker. | `bool` | `true` | no |
| log\_kms\_key\_arn | Optional KMS key ARN for encrypting the access log group | `string` | `null` | no |
| log\_retention\_days | Retention in days for the API Gateway access log group | `number` | `90` | no |
| permissions\_boundary\_arn | ARN of the permissions boundary attached to the IAM roles this module creates. null leaves them unbounded. | `string` | `null` | no |
| require\_api\_key | Require the x-api-key header on POST /predict and GET /results/{id}. Creates one API key attached to the usage plan (the usage plan is created whenever this is true). The key is output as api\_key\_value (sensitive). | `bool` | `true` | no |
| tags | Tags to apply to resources | `map(string)` | `{}` | no |
| throttling\_burst\_limit | Stage-wide throttling burst limit (max concurrent requests in a short burst) | `number` | `50` | no |
| throttling\_rate\_limit | Stage-wide throttling rate limit (requests per second across all methods) | `number` | `20` | no |
| usage\_plan\_burst\_limit | Per-key burst limit | `number` | `20` | no |
| usage\_plan\_quota\_limit | Per-key quota - maximum requests in the usage\_plan\_quota\_period | `number` | `10000` | no |
| usage\_plan\_quota\_period | Quota period for usage plan - DAY / WEEK / MONTH | `string` | `"MONTH"` | no |
| usage\_plan\_rate\_limit | Per-key rate limit (requests per second) | `number` | `10` | no |
| waf\_rate\_limit | Requests per client IP in any 5-minute window before the WAF rate-based rule blocks that IP. | `number` | `300` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| access\_log\_group\_name | CloudWatch log group for stage access logs (null when access logging is off) |
| api\_id | ID of the API Gateway |
| api\_key\_id | ID of the frontend API key (null when require\_api\_key = false) |
| api\_key\_value | Value of the frontend API key (empty when require\_api\_key = false). Sent as the x-api-key header. |
| api\_name | Name of the API Gateway |
| execution\_arn | Execution ARN of the API Gateway |
| invoke\_url | Invoke URL of the API Gateway |
| stage\_name | Stage name of the deployment |
| web\_acl\_arn | ARN of the WAF web ACL associated with the stage (null when enable\_waf = false) |
<!-- END_TF_DOCS -->

## File Structure

```
modules/terraform-aws-api-gateway/
|-- data.tf          # Region and partition data sources
|-- main.tf          # REST API, methods, integrations, CORS, deployment, stage, usage plan, API key, WAF
|-- outputs.tf       # API name, ID, execution ARN, invoke URL, stage, API key, web ACL, log group
`-- variables.tf     # API name, stage, Lambda ARN, auth, API key, WAF, CORS origin, throttling, tags
```
