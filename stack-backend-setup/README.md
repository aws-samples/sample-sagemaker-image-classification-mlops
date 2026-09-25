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
3. Creates the `<project_name>-workload-boundary` IAM permissions boundary. Every role the training and inference stacks create carries it, and the CI/CD CodeBuild role can only create or change roles that do
4. Emits `backend_hcl`, the contents of `backend.hcl` for the consumer stacks

The consumer stacks (`stack-training`, `stack-inference`, `stack-cicd`) use a partial S3 backend with `use_lockfile = true` (S3 native state locking, Terraform 1.11+); the bucket, region and KMS key come from `backend.hcl`. **No DynamoDB table is needed.**

## Usage

From the repository root:

```bash
make bootstrap        # terraform init, plan -out, apply in this folder
make backend-config   # writes stack-*/backend.hcl from the outputs
```

Or by hand: `terraform output -raw backend_hcl > ../stack-training/backend.hcl` (and the same for `stack-inference` and `stack-cicd`), then `terraform init -backend-config=backend.hcl` in each stack. See `backend.hcl.example` in each stack for the format.

`force_destroy` defaults to `false`: the bucket holds every other stack's state. Destroy this stack last, after the others, and empty the bucket first.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | ~> 1.15 |
| aws | ~> 6.0 |
| random | ~> 3.8 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | ~> 6.0 |
| random | ~> 3.8 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_iam_policy.workload_boundary](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [random_id.suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| aws\_region | AWS region where the state bucket and KMS key are created | `string` | n/a | yes |
| environment | Deployment environment | `string` | n/a | yes |
| project\_name | Name of the project, used as prefix for the state bucket and KMS alias | `string` | n/a | yes |
| bucket\_name | Name of the S3 bucket for Terraform remote state. If empty, a name is generated from project\_name and a random suffix. | `string` | `""` | no |
| force\_destroy | Allow Terraform to delete the state bucket even if it contains objects. Set to true only in dev. | `bool` | `false` | no |
| kms\_key\_administrators | IAM ARNs allowed to administer the state encryption KMS key. Defaults to the caller's account root. | `list(string)` | `[]` | no |
| kms\_key\_alias | Alias name (without the alias/ prefix) for the state encryption KMS key. If empty, <project\_name>-terraform-state is used. | `string` | `""` | no |
| kms\_key\_deletion\_window\_days | Waiting period (days) before the KMS key is deleted after destroy. 7-30. | `number` | `30` | no |
| noncurrent\_version\_retention\_days | Days to retain non-current state file versions before permanent deletion | `number` | `90` | no |
| tags | Additional tags to apply to all resources | `map(string)` | `{}` | no |
| workload\_boundary\_name | Name of the IAM permissions boundary policy attached to every workload role. If empty, <project\_name>-workload-boundary is used. | `string` | `""` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| backend\_hcl | Contents for backend.hcl in stack-training, stack-inference and stack-cicd (`make backend-config` writes it for you) |
| kms\_key\_alias | Alias of the state encryption KMS key (usable as the backend kms\_key\_id) |
| kms\_key\_arn | ARN of the KMS key used to encrypt state |
| kms\_key\_id | ID of the KMS key used to encrypt state |
| state\_bucket\_arn | ARN of the state bucket |
| state\_bucket\_id | Name of the S3 bucket holding Terraform remote state |
| state\_bucket\_region | AWS region of the state bucket |
| workload\_boundary\_arn | ARN of the permissions boundary that every training and inference role must carry |
<!-- END_TF_DOCS -->

## File Structure

```
stack-backend-setup/
|-- main.tf           # KMS key, S3 bucket, workload permissions boundary
|-- variables.tf      # All input variables
|-- outputs.tf        # Outputs including backend_hcl
|-- providers.tf      # AWS provider with default_tags
|-- versions.tf       # Version constraints (local state, no backend block)
|-- terraform.tfvars  # Environment values
`-- README.md         # This file
```
