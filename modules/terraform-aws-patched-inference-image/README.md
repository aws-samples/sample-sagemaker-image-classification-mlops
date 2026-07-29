# terraform-aws-patched-inference-image

Builds and maintains a CVE-patched inference container image. Pulls the AWS Deep
Learning Container, applies OS + Python security patches, pushes to a private
KMS-encrypted ECR repo, and (optionally) generates a CycloneDX SBOM.

## What It Does

1. Creates a private, KMS-encrypted ECR repository (scan-on-push, last-10
   lifecycle policy).
2. Runs a CodeBuild project that patches the source DLC and pushes `:latest` +
   a date tag.
3. Bootstraps the first build at apply time via a `null_resource` (so the image
   exists before the endpoint needs it) and re-runs when the build recipe
   changes.
4. Schedules a monthly rebuild via EventBridge to keep patches current.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| terraform | ~> 1.15 |
| aws | ~> 6.0 |
| null | ~> 3.0 |

## Providers

| Name | Version |
|------|---------|
| aws | ~> 6.0 |
| null | ~> 3.0 |

## Resources

| Name | Type |
|------|------|
| [aws_cloudwatch_event_rule.monthly_rebuild](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_target.monthly_rebuild](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_codebuild_project.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/codebuild_project) | resource |
| [aws_ecr_lifecycle_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_lifecycle_policy) | resource |
| [aws_ecr_repository.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_repository) | resource |
| [aws_iam_role.codebuild](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.events_codebuild](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.codebuild](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.events_codebuild](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [null_resource.build_on_create](https://registry.terraform.io/providers/hashicorp/null/latest/docs/resources/resource) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| aws\_account\_id | AWS account ID that owns the target ECR repository | `string` | n/a | yes |
| aws\_region | AWS region (used at buildspec runtime for ECR login) | `string` | n/a | yes |
| kms\_key\_arn | KMS key used to encrypt the ECR repository contents | `string` | n/a | yes |
| project\_name | Project identifier used to prefix resource names | `string` | n/a | yes |
| repository\_name | Name of the private ECR repository that will hold the patched image | `string` | n/a | yes |
| source\_registry | ECR registry hostname for the source DLC (e.g. 763104351884.dkr.ecr.us-east-1.amazonaws.com) | `string` | n/a | yes |
| source\_repository | DLC repository name (e.g. tensorflow-inference) | `string` | n/a | yes |
| source\_tag | Source DLC image tag to base the patched image on | `string` | n/a | yes |
| build\_image\_on\_create | Trigger one CodeBuild run at apply time (and wait) so the patched :latest image exists before the first model approval/auto-deploy. Requires AWS CLI on the Terraform runner. Set false in CI where the image is built by a separate stage. | `bool` | `true` | no |
| sbom\_bucket | S3 bucket (name only, not ARN) where Syft-generated CycloneDX SBOM files are written after each build. Leave empty to disable SBOM generation. Generated files land at s3://<bucket>/sboms/<date-tag>.cdx.json. | `string` | `""` | no |
| sbom\_bucket\_arn | ARN of the SBOM bucket (required when sbom\_bucket is set). Separate from sbom\_bucket so the IAM policy can reference the full ARN without string interpolation at apply time. | `string` | `""` | no |
| tags | Tags applied to every resource | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| codebuild\_project\_arn | ARN of the CodeBuild project |
| codebuild\_project\_name | Name of the CodeBuild project that builds the patched image |
| latest\_image\_uri | ECR repository URI tagged `:latest` |
| repository\_arn | ARN of the ECR repository |
| repository\_url | ECR repository URL for the patched image (push target) |
<!-- END_TF_DOCS -->
