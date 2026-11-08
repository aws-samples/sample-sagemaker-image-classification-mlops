# terraform-aws-patched-inference-image

Builds and maintains a CVE-patched inference container image. Pulls the AWS Deep
Learning Container, applies OS + Python security patches, pushes to a private
AWS KMS encrypted Amazon Elastic Container Registry (Amazon ECR) repository,
and (optionally) generates a CycloneDX SBOM.

## What It Does

1. Creates a private, KMS-encrypted, tag-immutable ECR repository
   (scan-on-push, last-10 lifecycle policy).
2. Runs an AWS CodeBuild project that patches the source DLC and pushes one dated
   tag (`YYYYMMDD-HHMMSS`) per build. Its ECR permissions are scoped to the
   source DLC repository and this repository. Its log group is created by the
   module with the KMS key and `log_retention_days`.
3. Gates every pushed image on its Amazon ECR scan (`scan-gate.sh`): the build
   waits for a completed scan (starting a basic scan where the registry does
   not scan on push) and deletes the image, failing the build, when a finding
   is at or above `scan_block_severity` (`CRITICAL` by default, `NONE` turns
   the gate off). The Python packages the build upgrades are not pinned, so
   this gate is what keeps a vulnerable upgrade from being pinned: neither an
   apply nor the weekly endpoint refresh ever sees a rejected image, and the
   endpoint stays on the last image that passed. A failed build sets off the
   `<project>-patched-image-build-failed` alarm (`alarm_actions`). Basic
   scanning covers operating system packages; Amazon Inspector enhanced
   scanning also covers Python packages, and then the build role needs
   `inspector2:ListFindings` (it is in the role's policy and must also be
   allowed by its permissions boundary).
4. Bootstraps the first build at apply time via a `null_resource` (so the image
   exists before the endpoint needs it) and re-runs when the build recipe
   changes. If the first image fails the scan gate, the apply fails; set
   `scan_block_severity` to accept it.
5. Schedules a weekly rebuild via Amazon EventBridge (`rebuild_schedule_expression`) to keep patches current.
6. Outputs the newest image pinned by digest (`image_uri`). Consumers deploy
   that digest; re-apply after a rebuild so the next deployment uses it.

## What Runs In The Image

The image is the Amazon SageMaker AI TensorFlow Serving DLC. It serves every
`<name>_model/1` SavedModel in the ensemble `model.tar.gz` and runs the
package's `code/inference.py` (`handler()`) in front of them; `SAGEMAKER_PROGRAM`
is not used by this container. The handler combines the member scores and, for
requests with `"explain": true`, calls the `gradcam` and `region_scores`
signatures that `scripts/ensemble/explain_export.py` adds to each SavedModel.
Gradients are part of those exported graphs, so TensorFlow Serving computes
them and the image needs no TensorFlow Python, `shap` or other extra package.
The patch step leaves the TensorFlow stack untouched, which keeps that true.

The registered package sets `SAGEMAKER_GUNICORN_TIMEOUT_SECONDS=60` (the
container default is 30) and `SAGEMAKER_GUNICORN_WORKERS=2`, so one explained
request does not hold up plain predictions on the same instance.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | ~> 1.15 |
| aws | ~> 6.0 |
| null | ~> 3.0 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | ~> 6.0 |
| null | ~> 3.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_event_rule.monthly_rebuild](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_target.monthly_rebuild](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_log_group.build](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_metric_alarm.build_failed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
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
| ---- | ----------- | ---- | ------- | :------: |
| aws\_account\_id | AWS account ID that owns the target ECR repository | `string` | n/a | yes |
| aws\_region | AWS region (used at buildspec runtime for ECR login) | `string` | n/a | yes |
| kms\_key\_arn | KMS key used to encrypt the ECR repository contents | `string` | n/a | yes |
| project\_name | Project identifier used to prefix resource names | `string` | n/a | yes |
| repository\_name | Name of the private ECR repository that will hold the patched image | `string` | n/a | yes |
| source\_registry | ECR registry hostname for the source DLC (e.g. 763104351884.dkr.ecr.us-east-1.amazonaws.com) | `string` | n/a | yes |
| source\_repository | DLC repository name (e.g. tensorflow-inference) | `string` | n/a | yes |
| source\_tag | Source DLC image tag to base the patched image on | `string` | n/a | yes |
| alarm\_actions | Actions (for example an SNS topic ARN) for the alarm on a failed image build. | `list(string)` | `[]` | no |
| build\_image\_on\_create | Trigger one CodeBuild run at apply time (and wait) so a patched image exists before the endpoint and auto-deploy Lambda pin its digest. Requires AWS CLI on the Terraform runner. When false, an image must already be in the repository (built by a separate stage) or the apply fails reading it. | `bool` | `true` | no |
| log\_retention\_days | Retention of the build's CloudWatch log group, in days. | `number` | `365` | no |
| permissions\_boundary\_arn | ARN of the permissions boundary attached to the IAM roles this module creates. null leaves them unbounded. | `string` | `null` | no |
| rebuild\_schedule\_expression | EventBridge schedule for rebuilding the patched image. Weekly by default (Saturdays 05:00 UTC), the day before the stack's Sunday endpoint refresh rolls the newest image out. | `string` | `"cron(0 5 ? * SAT *)"` | no |
| sbom\_bucket | S3 bucket (name only, not ARN) where Syft-generated CycloneDX SBOM files are written after each build. Leave empty to disable SBOM generation. Generated files land at s3://<bucket>/sboms/<date-tag>.cdx.json. | `string` | `""` | no |
| sbom\_bucket\_arn | ARN of the SBOM bucket (required when sbom\_bucket is set). Separate from sbom\_bucket so the IAM policy can reference the full ARN without string interpolation at apply time. | `string` | `""` | no |
| scan\_block\_severity | Scan gate: a new image with an Amazon ECR scan finding at or above this severity is deleted and its build fails, so neither an apply nor the weekly endpoint refresh can pin it; the endpoint keeps the last image that passed. CRITICAL, HIGH, MEDIUM, LOW, or NONE to turn the gate off. With Amazon Inspector enhanced scanning the gate reads the findings through inspector2:ListFindings, which the build role holds. | `string` | `"CRITICAL"` | no |
| syft\_linux\_amd64\_sha256 | SHA-256 of syft\_<syft\_version>\_linux\_amd64.tar.gz from that release's checksums.txt. Null uses the checksum pinned for the default syft\_version; set it whenever you change syft\_version, or the build fails the checksum check. | `string` | `null` | no |
| syft\_version | Syft release (without the v) installed to generate the image SBOM. | `string` | `"1.56.0"` | no |
| tags | Tags applied to every resource | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| codebuild\_project\_arn | ARN of the CodeBuild project |
| codebuild\_project\_name | Name of the CodeBuild project that builds the patched image |
| image\_tag | Dated tag of the newest patched image (YYYYMMDD-HHMMSS) |
| image\_uri | Newest patched image pinned by digest (<repository\_url>@sha256:...) |
| repository\_arn | ARN of the ECR repository |
| repository\_url | ECR repository URL for the patched image (push target) |
<!-- END_TF_DOCS -->
