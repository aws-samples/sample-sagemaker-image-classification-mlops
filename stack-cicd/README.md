# stack-cicd

Optional CI/CD pipeline for the sample: CodePipeline, CodeBuild projects, baseline model creation, and a GitHub source connection through AWS CodeConnections.

![CI/CD deployment](../docs/diagrams/mlops-cicd.svg)

## What It Does

1. Creates an S3 bucket for CodePipeline artifacts
2. Creates an AWS CodeConnections connection (Terraform resource `aws_codestarconnections_connection`) to your GitHub repository
3. Creates 4 CodeBuild projects (baseline model creation, training deploy, script upload, inference deploy)
4. Deploys a CodePipeline with 5 stages: Source, Training-Deploy, BaselineModelCreation, Script-Upload, Inference-Deploy, with an optional manual approval before Inference-Deploy
5. Creates a CodePipeline role with S3, CodeConnections and CodeBuild permissions, and an SNS topic for approval notifications (`approval_notification_emails`)
6. Creates a CodeBuild role scoped to project-prefixed resources. It can only create or change IAM roles that carry the workload permissions boundary from `stack-backend-setup`, can only attach an allowlist of managed policies, and cannot modify the CI/CD roles or the boundary itself

The Terraform CodeBuild projects install a pinned Terraform release, verify it against HashiCorp's `SHA256SUMS`, run `terraform plan -out=tfplan`, and apply that saved plan.

## Pipeline stages

| Stage | What it does |
| --- | --- |
| Source | Pulls `github_branch` of your repository through the connection |
| Training-Deploy | Applies `stack-training` |
| BaselineModelCreation | On the first run, registers a placeholder baseline (a toy model that cannot classify images) as `PendingManualApproval` and prints its ARN; later runs do nothing |
| Script-Upload | Uploads the pipeline scripts and the ImageNet weights to the scripts bucket |
| Inference-Deploy | Waits for the manual approval action (`require_manual_approval`, default `true`), builds the Lambda layer, and applies `stack-inference` with the newest Approved package in the group |

Nothing is approved automatically. Inference-Deploy fails with `no Approved model package` until a person approves one package, so on the first run approve the baseline before you approve the pipeline action:

```bash
aws sagemaker update-model-package --model-package-arn <arn from the BaselineModelCreation log> \
  --model-approval-status Approved
```

After that, approve trained packages in the Model Registry; the auto-deploy Lambda in `stack-inference` rolls each approval onto the endpoint.

## Prerequisites

1. `stack-backend-setup` applied, and `backend.hcl` written for this stack (`make backend-config`)
2. Your own copy (fork) of this repository on GitHub
3. `github_owner`, `github_repo` and `state_bucket_name` set in `terraform.tfvars`. They have no defaults, and the placeholders are rejected

## Usage

```bash
make backend-config      # once, after bootstrap
make deploy-cicd         # or: cd stack-cicd && terraform init -backend-config=backend.hcl && terraform plan -out=tfplan && terraform apply tfplan
```

### Complete the GitHub connection

Terraform creates the connection in `PENDING` state; the pipeline cannot pull source until you finish the handshake once:

1. Open the console: Developer Tools > Settings > Connections, and select `<project_name>-github`
2. Choose **Update pending connection** and sign in to GitHub
3. Install the AWS Connector for GitHub app on the organization or user that owns your fork (you can limit it to that one repository), then choose **Connect**
4. Check that `terraform output github_connection_status` shows `AVAILABLE`, then choose **Release change** on the pipeline (or push to `github_branch`)

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
| [aws_codepipeline.pipeline](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/codepipeline) | resource |
| [aws_codestarconnections_connection.github](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/codestarconnections_connection) | resource |
| [aws_iam_policy.codebuild](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role_policy_attachment.codebuild](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_sns_topic.pipeline_approvals](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic) | resource |
| [aws_sns_topic_subscription.pipeline_approvals_email](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_subscription) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| github\_owner | GitHub organization or user that owns your copy of this repository | `string` | n/a | yes |
| github\_repo | Name of your copy of this repository on GitHub | `string` | n/a | yes |
| state\_bucket\_name | Name of the Terraform state bucket (stack-backend-setup output state\_bucket\_id). CodeBuild uses it to initialise the training and inference backends. | `string` | n/a | yes |
| approval\_notification\_emails | Email addresses to notify when the pipeline pauses at the manual approval gate. Subscribers must confirm the SNS subscription after the first apply. | `list(string)` | `[]` | no |
| aws\_region | AWS region | `string` | `"us-east-1"` | no |
| dlc\_account\_id | AWS account ID that hosts the Deep Learning Containers ECR registry | `string` | `"763104351884"` | no |
| environment | Environment name | `string` | `"dev"` | no |
| github\_branch | GitHub branch to track | `string` | `"main"` | no |
| inference\_image\_tag | DLC tensorflow-inference tag. Use the floating major.minor tag (no -v1.X suffix) to auto-pick up AWS patches. | `string` | `"2.19.0-cpu-py312-ubuntu22.04-sagemaker"` | no |
| model\_package\_group\_name | Name of the SageMaker Model Package Group (stack-training output model\_package\_group\_name). If empty, <project\_name>-model-package-group is used. | `string` | `""` | no |
| project\_name | Name of the project | `string` | `"medical-image-classification"` | no |
| require\_manual\_approval | Insert a manual approval action before the Inference-Deploy stage. Strongly recommended for medical ML: a human must review the model card + drift metrics before a new model reaches prod. | `bool` | `true` | no |
| state\_bucket\_region | Region of the state bucket. If empty, aws\_region is used. | `string` | `""` | no |
| state\_kms\_key\_alias | Alias of the state encryption KMS key, including the alias/ prefix (stack-backend-setup output kms\_key\_alias). If empty, alias/<project\_name>-terraform-state is used. | `string` | `""` | no |
| workload\_boundary\_name | Name of the permissions boundary policy created by stack-backend-setup. If empty, <project\_name>-workload-boundary is used. | `string` | `""` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| artifacts\_bucket | S3 bucket for pipeline artifacts |
| codebuild\_projects | CodeBuild project names |
| codepipeline\_arn | ARN of the CodePipeline |
| codepipeline\_name | Name of the CodePipeline |
| github\_connection\_arn | ARN of the AWS CodeConnections connection to GitHub |
| github\_connection\_status | Status of the AWS CodeConnections connection to GitHub (PENDING until the handshake is completed in the console) |
<!-- END_TF_DOCS -->

## File Structure

```
stack-cicd/
|-- backend.tf                           # Partial S3 backend (bucket, region, KMS key come from backend.hcl)
|-- backend.hcl.example                  # Template for backend.hcl
|-- codebuild/                           # CodeBuild buildspec files
|   |-- baseline-model-buildspec.yml     # Baseline model creation
|   |-- inference-deploy-buildspec.yml   # Inference infrastructure deployment
|   |-- script-upload-buildspec.yml      # ML script upload to S3
|   `-- training-deploy-buildspec.yml    # Training infrastructure deployment
|-- data.tf                              # Locals, state KMS alias and permissions boundary lookups
|-- main.tf                              # S3 bucket, GitHub connection, CodeBuild projects, CodePipeline, IAM roles
|-- outputs.tf                           # Pipeline, artifacts, CodeBuild, GitHub outputs
|-- providers.tf                         # AWS provider with default_tags
|-- scripts/                             # Helper scripts
|   |-- create_baseline_model.py         # Creates baseline model in SageMaker Model Registry
|   `-- verify_baseline_model.py         # Checks the group has an Approved package
|-- terraform.tfvars                     # Variable values for this environment
|-- upload_source.sh                     # Uploads source code to S3
|-- variables.tf                         # Input variables
`-- versions.tf                          # Terraform and provider version constraints
```
