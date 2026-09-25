# iam-role

Reusable IAM role with support for managed policy attachments and inline policies.

## What It Does

1. Creates an IAM role with a configurable assume role policy, description, and path
2. Attaches managed IAM policies from a list of ARNs
3. Creates inline IAM policies from a map of policy documents
4. Optionally sets a permissions boundary (`permissions_boundary_arn`)

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
| [aws_iam_role.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.inline_policies](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.managed_policies](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| assume\_role\_policy | The assume role policy document | `string` | n/a | yes |
| role\_name | Name of the IAM role | `string` | n/a | yes |
| description | Description of the IAM role | `string` | `null` | no |
| inline\_policies | Map of inline policy names to policy documents | `map(string)` | `{}` | no |
| managed\_policy\_arns | List of managed policy ARNs to attach to the role | `list(string)` | `[]` | no |
| max\_session\_duration | Maximum session duration in seconds (3600-43200). Default is AWS default of 3600 (1 hour). Increase for long-running CodeBuild jobs. | `number` | `3600` | no |
| path | Path for the IAM role | `string` | `"/"` | no |
| permissions\_boundary\_arn | ARN of the permissions boundary policy for the role (stack-backend-setup output workload\_boundary\_arn). The CI/CD CodeBuild role can only create or change roles that carry it. | `string` | `null` | no |
| tags | Tags to apply to the role | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| role\_arn | The ARN of the IAM role |
| role\_id | The ID of the IAM role |
| role\_name | The name of the IAM role |
<!-- END_TF_DOCS -->

## File Structure

```
modules/terraform-aws-iam/
|-- main.tf          # IAM role, managed policy attachments, inline policies
|-- outputs.tf       # Role ARN, name, ID
|-- README.md        # Module documentation
`-- variables.tf     # Role name, assume role policy, description, path, policies, tags
```
