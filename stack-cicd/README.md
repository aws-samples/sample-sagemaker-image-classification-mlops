# stack-cicd

CI/CD pipeline for automated MLOps deployment - CodePipeline, CodeBuild projects, baseline model creation, and GitHub integration.

## What It Does

1. Creates an S3 bucket for CodePipeline artifacts
2. Creates a CodeStar connection for GitHub repository integration
3. Creates 4 CodeBuild projects via module (baseline model creation, training deploy, script upload, inference deploy)
4. Deploys a CodePipeline with 5 stages: Source, Training-Deploy, BaselineModelCreation, Script-Upload, Inference-Deploy
5. Creates a CodePipeline IAM role with S3, CodeStar, and CodeBuild permissions
6. Creates a CodeBuild IAM role with broad AWS service permissions for infrastructure deployment

## Prerequisites

1. **stack-training** must be deployed first - the pipeline deploys training and inference infrastructure
2. A **GitHub repository** with the project source code
3. The **CodeStar connection** must be manually approved in the AWS Console after `terraform apply`
4. The **S3 backend bucket** must exist for Terraform state storage

## Usage

```bash
cd stack-cicd

# Initialize with S3 backend
terraform init

# Review the plan
terraform plan

# Apply
terraform apply
```

After apply, approve the CodeStar connection in the AWS Console under Developer Tools > Settings > Connections.

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
| [aws_codepipeline.pipeline](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/codepipeline) | resource |
| [aws_codestarconnections_connection.github](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/codestarconnections_connection) | resource |
| [aws_sns_topic.pipeline_approvals](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic) | resource |
| [aws_sns_topic_subscription.pipeline_approvals_email](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_subscription) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| approval\_notification\_emails | Email addresses to notify when the pipeline pauses at the manual approval gate. Subscribers must confirm the SNS subscription after the first apply. | `list(string)` | `[]` | no |
| aws\_region | AWS region | `string` | `"us-east-1"` | no |
| dlc\_account\_id | AWS account ID that hosts the Deep Learning Containers ECR registry | `string` | `"763104351884"` | no |
| environment | Environment name | `string` | `"dev"` | no |
| github\_branch | GitHub branch to track | `string` | `"main"` | no |
| github\_owner | GitHub repository owner | `string` | `"xsagarx-aws"` | no |
| github\_repo | GitHub repository name | `string` | `"Medical_Image_Classification"` | no |
| inference\_image\_tag | DLC tensorflow-inference tag. Use the floating major.minor tag (no -v1.X suffix) to auto-pick up AWS patches. | `string` | `"2.19.0-cpu-py312-ubuntu22.04-sagemaker"` | no |
| model\_package\_group\_name | Name of the SageMaker Model Package Group | `string` | `"medical-image-classification-model-package-group"` | no |
| project\_name | Name of the project | `string` | `"medical-image-classification"` | no |
| require\_manual\_approval | Insert a manual approval action before the Inference-Deploy stage. Strongly recommended for medical ML: a human must review the model card + drift metrics before a new model reaches prod. | `bool` | `true` | no |

## Outputs

| Name | Description |
|------|-------------|
| artifacts\_bucket | S3 bucket for pipeline artifacts |
| codebuild\_projects | CodeBuild project names |
| codepipeline\_arn | ARN of the CodePipeline |
| codepipeline\_name | Name of the CodePipeline |
| github\_connection\_arn | CodeStar connection ARN for GitHub |
| github\_connection\_status | CodeStar connection status |
<!-- END_TF_DOCS -->

## File Structure

```
stack-cicd/
├── backend.tf                                  # S3 backend configuration for Terraform state
├── codebuild/                                  # CodeBuild buildspec files
│   ├── baseline-model-buildspec.yml            # Buildspec for baseline model creation
│   ├── inference-deploy-buildspec.yml          # Buildspec for inference infrastructure deployment
│   ├── script-upload-buildspec.yml             # Buildspec for ML script upload to S3
│   └── training-deploy-buildspec.yml           # Buildspec for training infrastructure deployment
├── data.tf                                     # Local values for common tags
├── main.tf                                     # S3 bucket, CodeStar, CodeBuild projects, CodePipeline, IAM roles
├── outputs.tf                                  # All output values (pipeline, artifacts, CodeBuild, GitHub)
├── scripts/                                    # Helper scripts
│   ├── create_baseline_model.py                # Creates baseline model in SageMaker Model Registry
│   └── verify_baseline_model.py                # Verifies baseline model exists and is approved
├── terraform.tfvars                            # Variable values for this environment
├── upload_source.sh                            # Script to upload source code to S3
├── variables.tf                                # All input variables
└── versions.tf                                 # Terraform and provider version constraints
```
