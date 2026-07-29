# kms

KMS key with key policy for IAM and CloudWatch Logs, optional alias, and automatic key rotation.

## What It Does

1. Creates a KMS key with a key policy granting full access to the account root and CloudWatch Logs service
2. Enables automatic key rotation by default
3. Optionally creates a KMS alias for the key

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
| [aws_kms_alias.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| description | Description of the KMS key | `string` | n/a | yes |
| alias\_name | Alias name for the KMS key (optional) | `string` | `null` | no |
| deletion\_window\_days | Number of days to wait before deleting KMS key | `number` | `7` | no |
| enable\_cloudtrail\_grant | Add a key-policy statement allowing the CloudTrail service principal to GenerateDataKey/DescribeKey. Required when this CMK encrypts a CloudTrail trail, otherwise CreateTrail fails with InsufficientEncryptionPolicyException. | `bool` | `false` | no |
| enable\_key\_rotation | Enable automatic rotation of KMS key | `bool` | `true` | no |
| key\_administrators | IAM ARNs allowed to administer the KMS key (schedule deletion, rotate, manage policy). When empty, the AWS account root gets default admin rights. | `list(string)` | `[]` | no |
| tags | Tags to apply to the KMS key | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| alias\_arn | The Amazon Resource Name (ARN) of the key alias |
| key\_arn | The Amazon Resource Name (ARN) of the key |
| key\_id | The globally unique identifier for the key |
<!-- END_TF_DOCS -->

## File Structure

```
modules/terraform-aws-kms/
├── main.tf          # KMS key with key policy, optional alias, data sources for account/region
├── outputs.tf       # Key ID, key ARN, alias ARN
├── README.md        # Module documentation
└── variables.tf     # Description, deletion window, key rotation, alias name, tags
```
