# stack-training

SageMaker ML pipeline infrastructure for medical image classification - data validation, preprocessing, multi-model training, evaluation, ensemble creation, and conditional model registration.

## What It Does

1. Creates a KMS key with rotation for S3 bucket encryption
2. Creates 6 S3 buckets (raw data, processed data, scripts, model artifacts, inference results, monitoring)
3. Creates a SageMaker execution IAM role with S3, KMS, ECR, CloudWatch, and MLflow permissions
4. Deploys a SageMaker Model Package Group for model versioning and registry
5. Deploys an MLflow Tracking Server for experiment tracking
6. Creates a SageMaker Pipeline with 9 steps: validation, preprocessing, multi-model training, evaluation, ensemble, conditional registration
7. Configures EventBridge auto-trigger to start the pipeline when new data is uploaded to S3
8. Creates an EventBridge IAM role for SageMaker pipeline invocation
9. Deploys CloudWatch monitoring with dashboards, log groups, and custom metrics via the cloudwatch module

## Prerequisites

1. **AWS CLI** configured with appropriate credentials
2. **Terraform >= 1.15** installed
3. The **S3 backend bucket** must exist for Terraform state storage
4. ML scripts must be uploaded to the scripts bucket after apply (via `script_uploader.sh`)
5. Training data must be uploaded to the raw data bucket after apply (via `data_uploader.sh`)

## Usage

```bash
cd stack-training

# Initialize with S3 backend
terraform init

# Review the plan
terraform plan

# Apply
terraform apply

# Upload ML scripts to S3
cd ../scripts && ./script_uploader.sh

# Upload training data
./data_uploader.sh ../data/batch1
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| terraform | ~> 1.15 |
| archive | ~> 2.7 |
| aws | ~> 6.0 |
| random | ~> 3.8 |

## Providers

| Name | Version |
|------|---------|
| aws | ~> 6.0 |
| random | ~> 3.8 |

## Resources

| Name | Type |
|------|------|
| [aws_budgets_budget.monthly](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/budgets_budget) | resource |
| [aws_cloudtrail.audit](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudtrail) | resource |
| [aws_cloudwatch_event_rule.new_data_uploaded](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_target.pipeline_trigger](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_log_group.cloudtrail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_iam_role.cloudtrail_cwl](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.eventbridge_sagemaker_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.cloudtrail_cwl](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.eventbridge_sagemaker_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_s3_bucket_policy.cloudtrail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_sagemaker_mlflow_tracking_server.mlflow](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sagemaker_mlflow_tracking_server) | resource |
| [aws_sagemaker_model_card.medical_image](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sagemaker_model_card) | resource |
| [aws_sagemaker_model_package_group.medical_image_models](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sagemaker_model_package_group) | resource |
| [aws_sagemaker_pipeline.medical_image_pipeline](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sagemaker_pipeline) | resource |
| [aws_sns_topic.cloudtrail_notifications](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic) | resource |
| [aws_sns_topic_policy.cloudtrail_notifications](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_policy) | resource |
| [random_id.bucket_suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |
| [random_id.cloudtrail_suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |
| [random_id.sbom_suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| aws\_region | AWS region | `string` | n/a | yes |
| environment | Environment name | `string` | n/a | yes |
| models | Configuration for all training models | <pre>map(object({<br/>    script_name     = string<br/>    tar_file        = string<br/>    step_name       = string<br/>    hyperparameters = map(string)<br/>    volume_size     = number<br/>    instance_count  = number<br/>    max_runtime     = number<br/>    instance_type   = string<br/>    enable_cache    = bool<br/>    cache_expiry    = string<br/>  }))</pre> | n/a | yes |
| pipeline\_steps | Configuration for pipeline processing steps | <pre>map(object({<br/>    instance_type  = string<br/>    instance_count = number<br/>    volume_size    = number<br/>    script_name    = string<br/>    step_name      = string<br/>    step_type      = string<br/>    enable_cache   = bool<br/>    cache_expiry   = string<br/>  }))</pre> | n/a | yes |
| project\_name | Name of the project | `string` | n/a | yes |
| bucket\_defaults | Default configuration for S3 buckets | <pre>object({<br/>    force_destroy       = bool<br/>    enable_versioning   = bool<br/>    block_public_access = bool<br/>  })</pre> | <pre>{<br/>  "block_public_access": true,<br/>  "enable_versioning": true,<br/>  "force_destroy": true<br/>}</pre> | no |
| budget\_alert\_emails | Email addresses that receive AWS Budgets alerts at 80% actual and 100% forecasted thresholds. | `list(string)` | `[]` | no |
| clinical\_quality\_gate | Clinical quality gate the ensemble must clear before it can be registered. Recall is highest because a missed malignant case (false negative) is the costly error. Must mirror CLINICAL\_QUALITY\_THRESHOLDS in scripts/evaluation/model\_evaluator.py and scripts/ensemble/ensemble\_creator.py. | <pre>object({<br/>    accuracy  = number<br/>    recall    = number<br/>    precision = number<br/>    auc_roc   = number<br/>  })</pre> | <pre>{<br/>  "accuracy": 0.85,<br/>  "auc_roc": 0.9,<br/>  "precision": 0.8,<br/>  "recall": 0.95<br/>}</pre> | no |
| cloudtrail\_retention\_days | Days to retain CloudTrail logs in S3 before lifecycle deletion. HIPAA requires 6 years of audit retention - typically achieved by shipping to a SIEM, not keeping everything in S3. | `number` | `400` | no |
| code\_commit\_sha | Git commit SHA that produced this model, recorded on the model package for audit lineage. Pass from CI; defaults to 'local'. | `string` | `"local"` | no |
| dashboard\_config | Dashboard configuration JSON | `string` | `""` | no |
| dashboard\_name | CloudWatch dashboard name | `string` | `null` | no |
| data\_config | Data processing configuration | <pre>object({<br/>    content_type     = string<br/>    compression_type = string<br/>    s3_data_type     = string<br/>    s3_input_mode    = string<br/>    s3_upload_mode   = string<br/>  })</pre> | <pre>{<br/>  "compression_type": "None",<br/>  "content_type": "application/x-image",<br/>  "s3_data_type": "S3Prefix",<br/>  "s3_input_mode": "File",<br/>  "s3_upload_mode": "EndOfJob"<br/>}</pre> | no |
| dataset\_version | Dataset version identifier (e.g. DVC hash dataset-v2.3-sha256:...) recorded on the registered model package for audit lineage. Pass from CI; defaults to 'unversioned'. | `string` | `"unversioned"` | no |
| debugger\_rule\_image | Region-specific SageMaker Debugger rule-evaluator image. us-east-1 default; see https://docs.aws.amazon.com/sagemaker/latest/dg/debugger-docker-images-rules.html | `string` | `"503895931360.dkr.ecr.us-east-1.amazonaws.com/sagemaker-debugger-rules:latest"` | no |
| enable\_auto\_trigger | Enable auto-trigger of pipeline on new data upload | `bool` | `true` | no |
| enable\_cloudtrail | Create an account-wide CloudTrail with log-file integrity validation. Required for medical ML audit trails. | `bool` | `true` | no |
| enable\_cloudtrail\_sns | Attach an SNS delivery-notification topic to the CloudTrail. Off by default: CloudTrail cannot publish to a topic encrypted with the AWS-managed alias/aws/sns key, so enabling this requires a CMK whose policy grants the CloudTrail service principal. The trail and S3/CloudWatch delivery work without it. | `bool` | `false` | no |
| enable\_debugger | Attach SageMaker Debugger built-in rules (Overfit, LossNotDecreasing) to the training steps (Part 2). Off by default; managed MLflow plus CloudWatch covers the same need. | `bool` | `false` | no |
| enable\_experiments | Associate each training step with a SageMaker Experiment trial component via ExperimentConfig (Part 2). | `bool` | `true` | no |
| enable\_kms\_key\_rotation | Enable KMS key rotation | `bool` | `true` | no |
| enable\_managed\_spot\_training | Use EC2 Spot for all training steps. Requires checkpoint support in trainers. | `bool` | `true` | no |
| enable\_model\_card | Create a SageMaker Model Card documenting intended use, risk rating, and clinical context for the model package group (Part 2/4). | `bool` | `true` | no |
| enable\_network\_isolation | Enable network isolation for SageMaker training and processing jobs | `bool` | `false` | no |
| enable\_sbom\_bucket | Create a dedicated S3 bucket to receive Syft-generated CycloneDX SBOMs from the patched-image CodeBuild. Low monthly cost; safe to leave on even if you don't wire the patched image yet. | `bool` | `true` | no |
| enable\_training\_monitoring | Enable training monitoring | `bool` | `true` | no |
| fairness\_gate | Fairness gate the ensemble must clear before registration (Part 4). max\_disparity bounds the larger of demographic-parity difference and equal-opportunity difference, computed by scripts/bias/compute\_bias.py with Fairlearn. Must mirror DEFAULT\_THRESHOLD in that script. sensitive\_feature is reported in the bias report; the public datasets used here carry no demographic metadata, so magnification is an honest subgroup proxy - supply a real attribute for clinical use. | <pre>object({<br/>    max_disparity     = number<br/>    sensitive_feature = string<br/>  })</pre> | <pre>{<br/>  "max_disparity": 0.1,<br/>  "sensitive_feature": "magnification"<br/>}</pre> | no |
| kms\_deletion\_window\_days | KMS key deletion window (days) | `number` | `7` | no |
| log\_group\_names | Log group names for metric filters | `map(string)` | `{}` | no |
| log\_groups | Map of log groups to create | <pre>map(object({<br/>    name = string<br/>  }))</pre> | `{}` | no |
| log\_retention\_days | CloudWatch log retention days | `number` | `30` | no |
| metric\_namespaces | Metric namespaces for CloudWatch metrics | `map(string)` | `{}` | no |
| min\_images\_per\_class | Minimum images required per class (benign/malignant) for the validation step to pass. Production default is 100; lower it for small test datasets. | `number` | `100` | no |
| model\_card\_risk\_rating | Risk rating recorded on the Model Card. High for clinical decision-support models. | `string` | `"High"` | no |
| monthly\_budget\_usd | Monthly spending budget in USD (project-scoped via tag filter). Set to 0 to disable the AWS Budgets resource entirely. | `number` | `200` | no |
| pipeline\_max\_parallel\_steps | Max concurrent steps a pipeline execution can run. Lets the three model trainers run in parallel. | `number` | `4` | no |
| preprocessing\_target\_size | Target square resolution (pixels) the preprocessing job resizes every image to before training. 512 preserves fine diagnostic features like microcalcifications; the trainers downsample to their own input\_size from there. | `number` | `512` | no |
| retraining\_reason | Reason for retraining (manual, data\_upload, drift\_detected) | `string` | `"manual"` | no |
| sagemaker\_images | SageMaker container image configurations | <pre>object({<br/>    sklearn_tag              = string<br/>    tensorflow_gpu_tag       = string<br/>    tensorflow_cpu_tag       = string<br/>    tensorflow_inference_tag = string<br/>  })</pre> | <pre>{<br/>  "sklearn_tag": "1.4-2-cpu-py3",<br/>  "tensorflow_cpu_tag": "2.19.0-cpu-py312-ubuntu22.04-sagemaker",<br/>  "tensorflow_gpu_tag": "2.19.0-gpu-py312-cu125-ubuntu22.04-sagemaker",<br/>  "tensorflow_inference_tag": "2.19.0-cpu-py312-ubuntu22.04-sagemaker"<br/>}</pre> | no |
| sbom\_retention\_days | How long SBOM JSON files are kept before S3 expires them. | `number` | `730` | no |
| spot\_max\_wait\_buffer\_seconds | Extra wait time (seconds) SageMaker holds for Spot capacity on top of MaxRuntime | `number` | `1800` | no |
| training\_data\_path | Training data S3 path | `string` | `"medical_image_data/"` | no |
| training\_input\_mode | SageMaker training input mode | `string` | `"FastFile"` | no |
| training\_keep\_alive\_seconds | KeepAlivePeriodInSeconds for warm pools. Set to 0 to disable. | `number` | `1800` | no |

## Outputs

| Name | Description |
|------|-------------|
| auto\_trigger\_eventbridge\_rule | Name of the EventBridge rule for auto-triggering pipeline |
| endpoint\_name | Name of the SageMaker endpoint |
| inference\_results\_bucket | Name of the inference results S3 bucket |
| kms\_key\_arn | ARN of the KMS key |
| kms\_key\_id | ID of the KMS key |
| mlflow\_tracking\_server\_arn | ARN of the MLflow tracking server |
| mlflow\_tracking\_server\_url | URL of the MLflow tracking server |
| model\_artifacts\_bucket | Name of the model artifacts S3 bucket |
| model\_package\_group\_name | Name of the model package group |
| monitoring\_bucket | Name of the monitoring S3 bucket |
| pipeline\_log\_groups | Pipeline step log group names |
| processed\_data\_bucket | Name of the processed data S3 bucket |
| raw\_data\_bucket | Name of the raw data S3 bucket |
| sagemaker\_execution\_role\_arn | ARN of the SageMaker execution role |
| sagemaker\_image\_uris | SageMaker Docker image URIs fetched dynamically from AWS |
| sagemaker\_pipeline\_arn | ARN of the SageMaker pipeline |
| sagemaker\_pipeline\_name | Name of the SageMaker pipeline |
| sbom\_bucket | Name of the SBOM S3 bucket. Null when enable\_sbom\_bucket = false. |
| sbom\_bucket\_arn | ARN of the SBOM S3 bucket. Null when enable\_sbom\_bucket = false. |
| scripts\_bucket | Name of the scripts S3 bucket |
| training\_dashboard\_url | Training monitoring dashboard URL |
| training\_log\_groups | Training metrics log group names |
<!-- END_TF_DOCS -->

## File Structure

```
stack-training/
├── auto_trigger.tf         # EventBridge rule, target, and IAM for auto-triggering pipeline on S3 upload
├── backend.tf              # S3 backend configuration for Terraform state
├── data.tf                 # SageMaker ECR image data sources, locals for tags, paths, and metrics
├── main.tf                 # KMS, S3 buckets, IAM role, model registry, MLflow, SageMaker pipeline
├── monitor.tf              # CloudWatch monitoring module for training dashboards and metrics
├── outputs.tf              # All output values (buckets, pipeline, IAM, KMS, MLflow, EventBridge)
├── terraform.tfvars        # Variable values for this environment
├── terraform.tfvars.example # Example variable values
├── variables.tf            # All input variables
└── versions.tf             # Terraform and provider version constraints
```
