# stack-backend-setup

Bootstrap stack that provisions the shared S3 backend for all other Terraform stacks in this repo. Uses **local state** (chicken-and-egg: this stack can't store its state in the bucket it creates).

## What It Does

1. Creates a KMS key (with rotation) and alias `alias/<project_name>-terraform-state` for encrypting Terraform state at rest
2. Creates an S3 bucket named `<project_name>-tfstate-<random-suffix>` (or a supplied name) with:
   - Versioning enabled (required for safe state)
   - SSE-KMS with the bucket key on
   - `BucketOwnerEnforced` ACLs
   - Public access fully blocked
   - Deny-insecure-transport and require-latest-TLS bucket policies
   - Lifecycle rule to expire non-current versions after N days
3. Emits a copy-paste `backend {}` block snippet for the consumer stacks

The consumer stacks (`stack-training`, `stack-inference`, `stack-cicd`) point their own backends at this bucket with `use_lockfile = true` (S3 native state locking, Terraform 1.11+). **No DynamoDB table is needed.**

## Usage

First-time bootstrap:

```bash
cd stack-backend-setup
terraform init
terraform apply
# Note the state_bucket_id output
```

Then, in each of `stack-training/backend.tf`, `stack-inference/backend.tf`, and `stack-cicd/backend.tf`, set the `bucket` attribute to the output value and run:

```bash
cd <stack>
terraform init -migrate-state   # on first setup, or when the bucket changes
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| terraform | ~> 1.15 |
| aws | ~> 6.0 |
| random | ~> 3.8 |

## Providers

| Name | Version |
|------|---------|
| random | ~> 3.8 |

## Resources

| Name | Type |
|------|------|
| [random_id.suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| aws\_region | AWS region where the state bucket and KMS key are created | `string` | n/a | yes |
| environment | Deployment environment | `string` | n/a | yes |
| project\_name | Name of the project, used as prefix for the state bucket and KMS alias | `string` | n/a | yes |
| bucket\_name | Name of the S3 bucket for Terraform remote state. If empty, a name is generated from project\_name and a random suffix. | `string` | `""` | no |
| force\_destroy | Allow Terraform to delete the state bucket even if it contains objects. Set to true only in dev. | `bool` | `false` | no |
| kms\_key\_administrators | IAM ARNs allowed to administer the state encryption KMS key. Defaults to the caller's account root. | `list(string)` | `[]` | no |
| kms\_key\_deletion\_window\_days | Waiting period (days) before the KMS key is deleted after destroy. 7-30. | `number` | `30` | no |
| noncurrent\_version\_retention\_days | Days to retain non-current state file versions before permanent deletion | `number` | `90` | no |
| tags | Additional tags to apply to all resources | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| backend\_block\_example | Copy-paste this backend block into each consumer root (update `key` per root) |
| kms\_key\_alias | Alias of the state encryption KMS key (usable in backend `kms_key_id`) |
| kms\_key\_arn | ARN of the KMS key used to encrypt state |
| kms\_key\_id | ID of the KMS key used to encrypt state |
| state\_bucket\_arn | ARN of the state bucket |
| state\_bucket\_id | Name of the S3 bucket holding Terraform remote state |
| state\_bucket\_region | AWS region of the state bucket |
<!-- END_TF_DOCS -->

## File Structure

```
stack-backend-setup/
├── main.tf           # KMS key + S3 bucket via terraform-aws-modules/*
├── variables.tf      # All input variables
├── outputs.tf        # Outputs including backend_block_example
├── providers.tf      # AWS provider with default_tags
├── versions.tf       # Version constraints (local state, no backend block)
├── terraform.tfvars  # Environment values
└── README.md         # This file
```
