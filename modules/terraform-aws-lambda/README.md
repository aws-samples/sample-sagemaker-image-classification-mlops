# lambda-function

Reusable Lambda function module with automatic source code packaging, configurable permissions, and layer support.

## What It Does

1. Packages a source directory into a ZIP archive for Lambda deployment
2. Creates a Lambda function with configurable runtime, handler, timeout, memory, and layers
3. Optionally configures environment variables via a dynamic block
4. Optionally creates Lambda resource-based permissions for invoking services

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
| [aws_cloudwatch_log_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_lambda_function.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_lambda_permission.permissions](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| execution\_role\_arn | Lambda execution role ARN | `string` | n/a | yes |
| function\_name | Lambda function name | `string` | n/a | yes |
| handler | Lambda function handler | `string` | n/a | yes |
| source\_dir | Path to Lambda source code directory | `string` | n/a | yes |
| dead\_letter\_target\_arn | ARN of an SQS queue or SNS topic that receives failed async invocation events after Lambda exhausts its retry policy. Null = no DLQ (synchronous/API GW invocations don't need one). | `string` | `null` | no |
| description | Description of the Lambda function | `string` | `null` | no |
| enable\_xray\_tracing | Enable Active X-Ray tracing on the Lambda function. Recommended for production - gives end-to-end latency visibility across API GW → Lambda → downstream AWS services. | `bool` | `true` | no |
| env\_kms\_key\_arn | KMS CMK ARN used to encrypt Lambda environment variables. Null = AWS-managed key (still encrypted at rest). | `string` | `null` | no |
| environment\_variables | Environment variables for Lambda | `map(string)` | `null` | no |
| layers | List of Lambda Layer ARNs | `list(string)` | `[]` | no |
| log\_kms\_key\_arn | KMS key ARN to encrypt the Lambda log group (optional) | `string` | `null` | no |
| log\_retention\_days | CloudWatch log retention in days for the Lambda log group | `number` | `14` | no |
| memory\_size | Lambda memory size in MB | `number` | `512` | no |
| permissions | Lambda permissions | <pre>map(object({<br/>    statement_id = string<br/>    action       = string<br/>    principal    = string<br/>    source_arn   = string<br/>  }))</pre> | `{}` | no |
| reserved\_concurrent\_executions | Reserved concurrency cap for this function. -1 = use account-default unreserved concurrency. Set to a positive integer to (a) cap max concurrent executions (cost control) or (b) reserve capacity (protect critical functions). | `number` | `-1` | no |
| runtime | Lambda runtime | `string` | `"python3.13"` | no |
| tags | Resource tags | `map(string)` | `{}` | no |
| timeout | Lambda timeout in seconds | `number` | `300` | no |

## Outputs

| Name | Description |
|------|-------------|
| function\_arn | Lambda function ARN |
| function\_name | Lambda function name |
| invoke\_arn | Lambda function invoke ARN |
| log\_group\_arn | ARN of the Lambda CloudWatch log group |
| log\_group\_name | Name of the Lambda CloudWatch log group |
<!-- END_TF_DOCS -->

## File Structure

```
modules/terraform-aws-lambda/
├── main.tf          # Archive data source, Lambda function, Lambda permissions
├── outputs.tf       # Function name, ARN, invoke ARN
└── variables.tf     # Source dir, function config, permissions, layers, tags
```
