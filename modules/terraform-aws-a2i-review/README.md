# terraform-aws-a2i-review

Amazon Augmented AI (Amazon A2I) human-review loop. Routes low-confidence
inference results to a private workforce of human reviewers and writes their
decisions back to Amazon S3, encrypted with the AWS KMS key you pass in, as
ground truth for the next retraining cycle (Part 4 human-in-the-loop).

Amazon A2I is in maintenance mode: it is no longer open to new customers, and
existing customers can keep using it. `stack-inference` calls this module only
when `enable_human_review = true` (default `false`).

## What It Does

1. Creates an Amazon SageMaker AI Human Task UI from a Liquid HTML template.
2. Creates a Flow Definition wired to a private workteam (gated on `workteam_arn`;
   the workforce is a one-time per-account Amazon Cognito setup outside this module).
3. Writes reviewer decisions to the configured S3 output path, encrypted with
   the AWS KMS key passed to the module (the project key in `stack-inference`).

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
| [aws_sagemaker_flow_definition.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sagemaker_flow_definition) | resource |
| [aws_sagemaker_human_task_ui.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sagemaker_human_task_ui) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| execution\_role\_arn | IAM role ARN A2I assumes to read the task UI and write results to S3. | `string` | n/a | yes |
| kms\_key\_arn | KMS key ARN that encrypts the human-review output A2I writes to S3. | `string` | n/a | yes |
| name\_prefix | Prefix for the A2I human-task UI and flow-definition names. Amazon A2I is in maintenance mode (no longer open to new customers): call this module only behind an opt-in flag that defaults to false. | `string` | n/a | yes |
| output\_s3\_uri | S3 URI where A2I writes human-review results (the reviewer's label becomes ground truth for the next retraining cycle). | `string` | n/a | yes |
| class\_labels | Classes the reviewer chooses from in the task UI. | `list(string)` | <pre>[<br/>  "negative",<br/>  "positive"<br/>]</pre> | no |
| tags | Tags to apply to all resources. | `map(string)` | `{}` | no |
| task\_availability\_lifetime\_in\_seconds | How long a task stays available to workers before it expires. | `number` | `86400` | no |
| task\_count | Number of distinct workers who review each flagged case (1-3). | `number` | `1` | no |
| task\_description | Short description shown to the reviewer. | `string` | `"The model was not confident. Select the correct class for the image."` | no |
| task\_title | Title shown to the reviewer in the worker portal. | `string` | `"Review a low-confidence image prediction"` | no |
| workteam\_arn | ARN of the SageMaker workteam (private workforce) that reviews flagged cases. A2I cannot create a flow definition without a workteam, and a private workforce is created once per account via Cognito (outside this module). Leave empty to skip creating the flow definition (UI is still created). | `string` | `""` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| flow\_definition\_arn | ARN of the A2I flow definition the inference handler targets with start\_human\_loop. Empty when no workteam\_arn was supplied. |
| human\_task\_ui\_arn | ARN of the A2I human task UI. |
<!-- END_TF_DOCS -->
