# codebuild-project

Reusable AWS CodeBuild project with configurable environment, source, and artifact settings.

## What It Does

1. Creates a CodeBuild project with configurable build timeout and service role
2. Configures the build environment (compute type, Docker image, environment variables)
3. Configures source and artifact settings (defaults to CodePipeline integration)

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
| [aws_codebuild_project.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/codebuild_project) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| buildspec\_path | Path to the buildspec file | `string` | n/a | yes |
| name | Name of the CodeBuild project | `string` | n/a | yes |
| service\_role\_arn | ARN of the IAM role for CodeBuild | `string` | n/a | yes |
| artifacts\_type | Type of build output artifacts | `string` | `"CODEPIPELINE"` | no |
| build\_image | Docker image for the build environment. Default is the latest AL2023-based curated CodeBuild image. | `string` | `"aws/codebuild/amazonlinux-x86_64-standard:5.0"` | no |
| build\_timeout | Build timeout in minutes | `number` | `60` | no |
| compute\_type | Compute type for the build environment | `string` | `"BUILD_GENERAL1_MEDIUM"` | no |
| description | Description of the CodeBuild project | `string` | `null` | no |
| encryption\_key\_arn | KMS CMK ARN used to encrypt the CodeBuild output/cache. Null = AWS-managed alias/aws/s3 (still encrypted, just not customer-managed). Recommended for production to keep key access within the project's KMS policy. | `string` | `null` | no |
| environment\_type | Type of build environment | `string` | `"LINUX_CONTAINER"` | no |
| environment\_variables | Environment variables for the build | <pre>list(object({<br/>    name  = string<br/>    value = string<br/>  }))</pre> | `[]` | no |
| image\_pull\_credentials\_type | Type of credentials for pulling the build image | `string` | `"CODEBUILD"` | no |
| log\_group\_name | CloudWatch Logs group that CodeBuild writes to. Null = CodeBuild auto-creates `/aws/codebuild/<project-name>` with no KMS encryption. | `string` | `null` | no |
| log\_stream\_name | CloudWatch Logs stream name prefix. Null = default (build ID). | `string` | `null` | no |
| source\_type | Type of source provider | `string` | `"CODEPIPELINE"` | no |
| tags | Tags to apply to the CodeBuild project | `map(string)` | `{}` | no |
| vpc\_config | Optional VPC configuration - enables CodeBuild to reach private resources (RDS, internal APIs, private artifact repos). Leave null for public-internet builds. | <pre>object({<br/>    vpc_id             = string<br/>    subnets            = list(string)<br/>    security_group_ids = list(string)<br/>  })</pre> | `null` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| project\_arn | ARN of the CodeBuild project |
| project\_id | ID of the CodeBuild project |
| project\_name | Name of the CodeBuild project |
<!-- END_TF_DOCS -->

## File Structure

```
modules/terraform-aws-codebuild/
|-- main.tf          # CodeBuild project resource with dynamic environment variables
|-- outputs.tf       # Project name, ARN, ID
`-- variables.tf     # Project name, IAM role, build config, environment, source, tags
```
