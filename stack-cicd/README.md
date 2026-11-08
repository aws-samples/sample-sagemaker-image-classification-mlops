# stack-cicd

Optional CI/CD pipeline for the sample: AWS CodePipeline, AWS CodeBuild projects, baseline model creation, and a GitHub source connection through AWS CodeConnections.

![CI/CD deployment: a push to GitHub starts AWS CodePipeline through an AWS CodeConnections source connection; AWS CodeBuild stages deploy training, register the baseline in the Amazon SageMaker Model Registry, upload scripts to the Amazon S3 scripts bucket and, after a manual approval, deploy inference](../docs/diagrams/mlops-cicd.svg)

## What It Does

1. Creates an Amazon S3 bucket for CodePipeline artifacts
2. Creates an AWS CodeConnections connection (Terraform resource `aws_codestarconnections_connection`) to your GitHub repository
3. Creates 4 CodeBuild projects (baseline model creation, training deploy, script upload, inference deploy)
4. Deploys a CodePipeline with 5 stages: Source, Training-Deploy, BaselineModelCreation, Script-Upload, Inference-Deploy, with an optional manual approval before Inference-Deploy
5. Creates a CodePipeline role with S3, CodeConnections and CodeBuild permissions, and an Amazon SNS topic for approval notifications (`approval_notification_emails`)
6. Creates a CodeBuild role scoped to project-prefixed resources. It can only create or change AWS Identity and Access Management (IAM) roles that carry the workload permissions boundary from `stack-backend-setup`, can only attach an allowlist of managed policies, and cannot modify the CI/CD roles or the boundary itself
7. Creates a log group per CodeBuild project, `/aws/codebuild/<project-name>`, kept `log_retention_days` (default 365) and encrypted with the state key

The Terraform CodeBuild projects install a pinned Terraform release, verify it against HashiCorp's `SHA256SUMS`, run `terraform plan -out=tfplan`, and apply that saved plan.

## CodeBuild role limits

- **Terraform state.** The role can list the state bucket, read and write the `training/` and `inference/` state and delete their lock files. It cannot change the bucket's versioning, policy, encryption, lifecycle or public access settings, delete the bucket, delete object versions or state files, or write this stack's own `cicd/` state. On the state key it gets only the encrypt and decrypt calls: it cannot change the key policy, disable the key or its rotation, schedule its deletion, create grants, retag it or move its alias.
- **Tag-scoped keys and distributions.** AWS KMS keys and Amazon CloudFront distributions have generated IDs, so the role manages the ones tagged `Project = <project_name>`. It can create them only with that tag and the four default tag keys (`Project`, `Environment`, `ManagedBy`, `Purpose`), tag a key or distribution only while it has no `Project` tag (one it is creating) or already has this project's, and never set `Project` to another value. A key or distribution in the account with no `Project` tag at all can still be tagged into the project, and CloudFront origin access controls and response headers policies support no tag or name condition, so the role can change every one of them in the account: deploy into a dedicated account.
- **Deploy projects.** The role cannot start, retry or reconfigure the four deploy projects it runs as; only CodePipeline starts them. The workload permissions boundary denies every workload role all CodeBuild access to them.
- **Release path.** Every push to `github_branch` runs the stages with this role. Protect that branch: see [Protect the release branch](#protect-the-release-branch).

## Protect the release branch

Training-Deploy applies `stack-training` (IAM roles, the KMS key, CloudTrail) on every push to `github_branch` with no approval; the manual approval covers only Inference-Deploy. Anyone who can push to that branch therefore acts with the CodeBuild role. Before you connect the pipeline:

1. Turn on branch protection (a ruleset) for `github_branch` in your GitHub repository: require a pull request with at least one approving review from someone other than the author, dismiss stale approvals when new commits are pushed, and block force pushes and deletion.
2. Limit who can push or merge to the branch to the people who may deploy to the account, and do not allow bypassing the rules.
3. Limit the AWS Connector for GitHub app to this one repository.
4. If you need a human check before IAM and KMS changes, add a manual approval action before Training-Deploy in `main.tf`.

## Pipeline stages

| Stage | What it does |
| --- | --- |
| Source | Pulls `github_branch` of your repository through the connection |
| Training-Deploy | Applies `stack-training` |
| BaselineModelCreation | On the first run, registers a placeholder baseline (a toy model that cannot classify images) as `PendingManualApproval` and prints its ARN; later runs do nothing |
| Script-Upload | Uploads the pipeline scripts and the processing steps' wheelhouses to the scripts bucket |
| Inference-Deploy | Waits for the manual approval action (`require_manual_approval`, default `true`), builds the AWS Lambda layer, and applies `stack-inference` with the newest Approved package in the group |

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

### Upgrading an existing deployment

- The CodeBuild log groups are encrypted with the state key, whose policy admits CloudWatch Logs for `/aws/codebuild/<project_name>-*` log groups. Apply `stack-backend-setup` first (`make bootstrap`), then this stack.
- If builds already ran, CodeBuild created those log groups itself, and the apply fails with `ResourceAlreadyExistsException`. Import each one, then apply again: `terraform import 'module.codebuild_training_deploy.aws_cloudwatch_log_group.this[0]' /aws/codebuild/<project_name>-training-deploy` (and the same for `codebuild_baseline_model`, `codebuild_script_upload` and `codebuild_inference_deploy`). The next apply sets the retention and the key.

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
| force\_destroy\_buckets | Let terraform destroy delete the CodePipeline artifacts bucket with its objects and versions (build artifacts only). True by default so the stack tears down in one step. | `bool` | `true` | no |
| github\_branch | GitHub branch to track | `string` | `"main"` | no |
| inference\_image\_tag | DLC tensorflow-inference tag. Use the floating major.minor tag (no -v1.X suffix) to auto-pick up AWS patches, and keep it equal to sagemaker\_images.tensorflow\_inference\_tag in stack-training. | `string` | `"2.20-cpu-py312-amzn2023-sagemaker"` | no |
| log\_retention\_days | Days the CodeBuild log groups keep the build logs. They are encrypted with the state key, whose policy (stack-backend-setup) admits CloudWatch Logs for /aws/codebuild/<project\_name>-* log groups. | `number` | `365` | no |
| model\_package\_group\_name | Name of the SageMaker Model Package Group (stack-training output model\_package\_group\_name). If empty, <project\_name>-model-package-group is used. | `string` | `""` | no |
| project\_name | Name of the project | `string` | `"image-classification"` | no |
| require\_manual\_approval | Insert a manual approval action before the Inference-Deploy stage, so a person reviews the model card and drift metrics before a new model reaches the endpoint. | `bool` | `true` | no |
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
