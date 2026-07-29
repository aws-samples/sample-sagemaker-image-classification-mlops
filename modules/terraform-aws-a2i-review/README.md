# terraform-aws-a2i-review

Amazon Augmented AI (A2I) human-review loop. Routes low-confidence inference
results to a private workforce of reviewers and writes their decisions back to
S3 as ground truth for the next retraining cycle (Part 4 human-in-the-loop).

## What It Does

1. Creates a SageMaker Human Task UI from a Liquid HTML template.
2. Creates a Flow Definition wired to a private workteam (gated on `workteam_arn`;
   the workforce is a one-time per-account Cognito setup outside this module).
3. Writes reviewer decisions to the configured S3 output path.

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
| [aws_sagemaker_flow_definition.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sagemaker_flow_definition) | resource |
| [aws_sagemaker_human_task_ui.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sagemaker_human_task_ui) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| execution\_role\_arn | IAM role ARN A2I assumes to read the task UI and write results to S3. | `string` | n/a | yes |
| name\_prefix | Prefix for the A2I human-task UI and flow-definition names. | `string` | n/a | yes |
| output\_s3\_uri | S3 URI where A2I writes human-review results (the radiologist decision becomes ground truth for the next retraining cycle). | `string` | n/a | yes |
| tags | Tags to apply to all resources. | `map(string)` | `{}` | no |
| task\_availability\_lifetime\_in\_seconds | How long a task stays available to workers before it expires. | `number` | `86400` | no |
| task\_count | Number of distinct workers who review each flagged case (1-3). | `number` | `1` | no |
| task\_description | Short description shown to the reviewer. | `string` | `"The model was not confident. Confirm whether the image is benign or malignant."` | no |
| task\_title | Title shown to the reviewer in the worker portal. | `string` | `"Review a low-confidence breast histopathology prediction"` | no |
| workteam\_arn | ARN of the SageMaker workteam (private workforce) that reviews flagged cases. A2I cannot create a flow definition without a workteam, and a private workforce is created once per account via Cognito (outside this module). Leave empty to skip creating the flow definition (UI is still created). | `string` | `""` | no |

## Outputs

| Name | Description |
|------|-------------|
| flow\_definition\_arn | ARN of the A2I flow definition the inference handler targets with start\_human\_loop. Empty when no workteam\_arn was supplied. |
| human\_task\_ui\_arn | ARN of the A2I human task UI. |
<!-- END_TF_DOCS -->
