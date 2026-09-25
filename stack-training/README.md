# stack-training

SageMaker training infrastructure for the image classification sample: data and model buckets, the SageMaker pipeline (validation, preprocessing, three trainers, evaluation, ensemble, fairness check, clinical quality gate, registration), the Model Registry, a Model Card and cost controls.

## What It Does

1. Creates a KMS key with rotation for the stack's buckets, logs and SageMaker jobs
2. Creates 6 S3 buckets (raw data, processed data, scripts, model artifacts, inference results, monitoring), plus an SBOM bucket when `enable_sbom_bucket = true` (default) and a CloudTrail bucket when `enable_cloudtrail = true` (default `false`). `force_destroy` is `false` on all of them
3. Creates the SageMaker execution role (carrying the workload permissions boundary when `permissions_boundary_arn` is set)
4. Creates the Model Package Group and, with `enable_model_card = true` (default), a Model Card
5. Creates the SageMaker pipeline from `pipeline.json.tftpl`: 9 top-level steps (ValidateDataset, PreprocessData, three training steps, EvaluateAllModels, CreateEnsembleModel, BiasCheck, and the Condition step), whose branches are RegisterEnsembleModel or Fail
6. Creates an EventBridge rule that starts the pipeline with `RetrainingReason=data_upload` when the `.batch_complete` marker is written to the raw data bucket
7. Creates CloudWatch log groups, metric filters and a training dashboard, and an AWS Budgets budget (`monthly_budget_usd`, default 200)
8. Optionally creates a managed MLflow tracking server (`enable_mlflow`, default `false`) and a multi-region CloudTrail trail (`enable_cloudtrail`, default `false`)

## Pipeline behaviour

- **Patient-grouped split.** Preprocessing resizes images to `preprocessing_target_size` (512) and splits train, validation and test by BreakHis patient id, so one patient's images never cross splits.
- **Thresholds tuned on validation.** Evaluation and the ensemble tune their decision thresholds on the validation split; the clinical gate is scored on the test split at that threshold.
- **Fairness gate on the ensemble.** BiasCheck runs Fairlearn over the ensemble's own test predictions at its tuned threshold, per `fairness_gate.sensitive_feature` (magnification). Fewer than two subgroups is "not evaluable" and fails the gate unless `allow_not_evaluable = true` (default false; meant for small demo datasets).
- **Gate.** The Condition step requires `clinical_quality_gate` (accuracy 0.85, recall 0.95, precision 0.80, AUC 0.90) and `fairness_gate.max_disparity` (0.10). A pass registers the ensemble as `PendingManualApproval`; a miss ends in the Fail step.
- **Per-execution artifacts.** Evaluation, ensemble and bias outputs go to `<prefix>/<pipeline-execution-id>/` in the model artifacts bucket, and the registered package's `ModelDataUrl` points at that execution's `model.tar.gz`.
- **Lineage.** `RetrainingReason`, `DatasetVersion` and `CodeCommitSha` are pipeline parameters recorded on the model package. The Terraform variables only set their defaults; the upload rule passes `data_upload` and the drift rule in `stack-inference` passes `drift_detected`.
- **Network isolation.** `enable_network_isolation = true` (default) runs the training jobs without outbound network access; they read ImageNet weights from `s3://<scripts-bucket>/pretrained-weights/`. Processing jobs are not isolated because they install packages at start-up. `vpc_config` optionally places the jobs in your subnets.
- **Instance types.** The shipped `terraform.tfvars` trains on `ml.c5.2xlarge` (CPU) with 2 epochs, sized for a smoke test. Instance types starting `ml.g` or `ml.p` use the GPU training image; they need a SageMaker training quota.

## Prerequisites

1. `stack-backend-setup` applied and `backend.hcl` written (`make backend-config`)
2. Terraform `~> 1.15` and AWS CLI v2
3. After apply: the scripts uploaded (`make upload-scripts`), the ImageNet weights uploaded when network isolation is on, and training data uploaded with `scripts/data_uploader.sh`
4. `training_data_path` set to the prefix the uploader writes to (`medical_image_data/`, the shipped value), and `auto_trigger_marker_key` to the marker it writes (`medical_image_data/.batch_complete`)

## Usage

From the repository root:

```bash
make deploy-training     # terraform init -backend-config=backend.hcl, plan -out, apply
make upload-scripts      # pipeline scripts to the scripts bucket

# Network isolation (default): upload ImageNet weights once (no-op when isolation is off)
make weights

# Upload a dataset (breast_benign/ and breast_malignant/ folders); the marker starts the pipeline
./scripts/data_uploader.sh data/breakhis
```

`make deploy-training` passes `state_bucket_name`, `state_bucket_region` and `permissions_boundary_arn` from the bootstrap outputs as `TF_VAR_*`.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | ~> 1.15 |
| archive | ~> 2.7 |
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
| ---- | ----------- | ---- | ------- | :------: |
| aws\_region | AWS region | `string` | n/a | yes |
| environment | Environment name | `string` | n/a | yes |
| models | Configuration for all training models | <pre>map(object({<br/>    script_name     = string<br/>    tar_file        = string<br/>    step_name       = string<br/>    hyperparameters = map(string)<br/>    volume_size     = number<br/>    instance_count  = number<br/>    max_runtime     = number<br/>    instance_type   = string<br/>    enable_cache    = bool<br/>    cache_expiry    = string<br/>  }))</pre> | n/a | yes |
| pipeline\_steps | Configuration for pipeline processing steps | <pre>map(object({<br/>    instance_type  = string<br/>    instance_count = number<br/>    volume_size    = number<br/>    script_name    = string<br/>    step_name      = string<br/>    step_type      = string<br/>    enable_cache   = bool<br/>    cache_expiry   = string<br/>  }))</pre> | n/a | yes |
| project\_name | Name of the project, used as the prefix of every resource name. Lowercase letters, digits and hyphens. Together with environment it is capped so the longest derived name (the inference-results bucket) stays within the 63-character S3 limit. | `string` | n/a | yes |
| allow\_not\_evaluable | Let the fairness gate pass when the test split has fewer than two subgroups of fairness\_gate.sensitive\_feature, so disparity cannot be measured (status not\_evaluable). Default false fails the pipeline instead; set true only for small demo datasets. | `bool` | `false` | no |
| auto\_trigger\_marker\_key | Object key prefix in the raw-data bucket whose creation starts the pipeline. scripts/data\_uploader.sh writes this marker after a batch upload completes. | `string` | `"medical_image_data/.batch_complete"` | no |
| bucket\_defaults | Default configuration for S3 buckets | <pre>object({<br/>    force_destroy       = bool<br/>    enable_versioning   = bool<br/>    block_public_access = bool<br/>  })</pre> | <pre>{<br/>  "block_public_access": true,<br/>  "enable_versioning": true,<br/>  "force_destroy": false<br/>}</pre> | no |
| budget\_alert\_emails | Email addresses that receive AWS Budgets alerts at 80% actual and 100% forecasted thresholds. | `list(string)` | `[]` | no |
| budget\_start\_date | Start of the AWS Budgets period, in the format YYYY-MM-DD\_HH:MM (UTC). | `string` | `"2026-01-01_00:00"` | no |
| clinical\_quality\_gate | Clinical quality gate the ensemble must clear before it can be registered. Recall is highest because a missed malignant case (false negative) is the costly error. Must mirror CLINICAL\_QUALITY\_THRESHOLDS in scripts/evaluation/model\_evaluator.py and scripts/ensemble/ensemble\_creator.py. | <pre>object({<br/>    accuracy  = number<br/>    recall    = number<br/>    precision = number<br/>    auc_roc   = number<br/>  })</pre> | <pre>{<br/>  "accuracy": 0.85,<br/>  "auc_roc": 0.9,<br/>  "precision": 0.8,<br/>  "recall": 0.95<br/>}</pre> | no |
| cloudtrail\_retention\_days | Days to retain CloudTrail logs in S3 before lifecycle deletion. HIPAA requires 6 years of audit retention - typically achieved by shipping to a SIEM, not keeping everything in S3. | `number` | `400` | no |
| code\_commit\_sha | Default of the CodeCommitSha pipeline parameter: the Git commit that produced the model, recorded on the model package for audit lineage. Override per execution from CI. | `string` | `"local"` | no |
| dashboard\_config | Dashboard configuration JSON | `string` | `""` | no |
| dashboard\_name | CloudWatch dashboard name | `string` | `null` | no |
| data\_config | Data processing configuration | <pre>object({<br/>    content_type     = string<br/>    compression_type = string<br/>    s3_data_type     = string<br/>    s3_input_mode    = string<br/>    s3_upload_mode   = string<br/>  })</pre> | <pre>{<br/>  "compression_type": "None",<br/>  "content_type": "application/x-image",<br/>  "s3_data_type": "S3Prefix",<br/>  "s3_input_mode": "File",<br/>  "s3_upload_mode": "EndOfJob"<br/>}</pre> | no |
| dataset\_version | Default of the DatasetVersion pipeline parameter (for example a DVC hash such as dataset-v2.3-sha256:...), recorded on the registered model package for audit lineage. Override per execution from CI. | `string` | `"unversioned"` | no |
| debugger\_rule\_image | Region-specific SageMaker Debugger rule-evaluator image. us-east-1 default; see https://docs.aws.amazon.com/sagemaker/latest/dg/debugger-docker-images-rules.html | `string` | `"503895931360.dkr.ecr.us-east-1.amazonaws.com/sagemaker-debugger-rules:latest"` | no |
| enable\_auto\_trigger | Enable auto-trigger of pipeline on new data upload | `bool` | `true` | no |
| enable\_cloudtrail | Create a multi-region CloudTrail trail with log-file integrity validation for this account. Leave false when an organization trail already records this account's API activity. | `bool` | `false` | no |
| enable\_cloudtrail\_sns | Attach an SNS delivery-notification topic to the CloudTrail. Off by default. The topic is encrypted with the project CMK, whose key policy then grants the CloudTrail service principal (CloudTrail cannot publish to a topic on the AWS-managed alias/aws/sns key). The trail and S3/CloudWatch delivery work without it. | `bool` | `false` | no |
| enable\_debugger | Attach SageMaker Debugger built-in rules (Overfit, LossNotDecreasing) to the training steps (Part 2). Off by default; the CloudWatch training metrics (and MLflow when enable\_mlflow = true) cover the same need. | `bool` | `false` | no |
| enable\_experiments | Associate each training step with a SageMaker Experiment trial component via ExperimentConfig (Part 2). | `bool` | `true` | no |
| enable\_kms\_key\_rotation | Enable KMS key rotation | `bool` | `true` | no |
| enable\_managed\_spot\_training | Use EC2 Spot for all training steps. Requires checkpoint support in trainers. | `bool` | `true` | no |
| enable\_mlflow | Create a managed SageMaker MLflow tracking server (Small) for experiment tracking. Off by default because it is billed for every hour it runs. | `bool` | `false` | no |
| enable\_model\_card | Create a SageMaker Model Card documenting intended use, risk rating, and clinical context for the model package group (Part 2/4). | `bool` | `true` | no |
| enable\_network\_isolation | Run the training jobs with network isolation (no outbound network access from the training container). The trainers then read ImageNet weights from s3://<scripts-bucket>/pretrained-weights/, so run scripts/download\_pretrained\_weights.py once before the first pipeline execution. Processing jobs are not isolated because they install Python dependencies at start-up. | `bool` | `true` | no |
| enable\_sbom\_bucket | Create a dedicated S3 bucket to receive Syft-generated CycloneDX SBOMs from the patched-image CodeBuild. Low monthly cost; safe to leave on even if you don't wire the patched image yet. | `bool` | `true` | no |
| enable\_training\_monitoring | Enable training monitoring | `bool` | `true` | no |
| fairness\_gate | Fairness gate the ensemble must clear before registration (Part 4). max\_disparity bounds the larger of demographic-parity difference and equalized-odds difference, computed by scripts/bias/compute\_bias.py with Fairlearn. Must mirror DEFAULT\_THRESHOLD in that script. sensitive\_feature is reported in the bias report; the public datasets used here carry no demographic metadata, so magnification is an honest subgroup proxy - supply a real attribute for clinical use. | <pre>object({<br/>    max_disparity     = number<br/>    sensitive_feature = string<br/>  })</pre> | <pre>{<br/>  "max_disparity": 0.1,<br/>  "sensitive_feature": "magnification"<br/>}</pre> | no |
| kms\_deletion\_window\_days | KMS key deletion window (days) | `number` | `7` | no |
| log\_group\_names | Log group names for metric filters | `map(string)` | `{}` | no |
| log\_groups | Map of log groups to create | <pre>map(object({<br/>    name = string<br/>  }))</pre> | `{}` | no |
| log\_retention\_days | CloudWatch log retention days | `number` | `30` | no |
| metric\_namespaces | Metric namespaces for CloudWatch metrics | `map(string)` | `{}` | no |
| min\_images\_per\_class | Minimum images required per class (benign/malignant) for the validation step to pass. Production default is 100; lower it for small test datasets. | `number` | `100` | no |
| model\_card\_risk\_rating | Risk rating recorded on the Model Card. High for clinical decision-support models. | `string` | `"High"` | no |
| monthly\_budget\_usd | Monthly spending budget in USD (project-scoped via tag filter). Set to 0 to disable the AWS Budgets resource entirely. | `number` | `200` | no |
| permissions\_boundary\_arn | ARN of the permissions boundary attached to every IAM role this stack creates (stack-backend-setup output workload\_boundary\_arn). Required when CI/CD CodeBuild applies the stack; null leaves the roles unbounded. | `string` | `null` | no |
| pipeline\_max\_parallel\_steps | Max concurrent steps a pipeline execution can run. Lets the three model trainers run in parallel. | `number` | `4` | no |
| preprocessing\_target\_size | Target square resolution (pixels) the preprocessing job resizes every image to before training. 512 preserves fine diagnostic features like microcalcifications; the trainers downsample to their own input\_size from there. | `number` | `512` | no |
| retraining\_reason | Default of the RetrainingReason pipeline parameter (manual, data\_upload, drift\_detected), recorded on the registered model package. The upload trigger passes data\_upload and the drift alarm passes drift\_detected per execution. | `string` | `"manual"` | no |
| sagemaker\_images | SageMaker container image configurations | <pre>object({<br/>    tensorflow_gpu_tag       = string<br/>    tensorflow_cpu_tag       = string<br/>    tensorflow_inference_tag = string<br/>  })</pre> | <pre>{<br/>  "tensorflow_cpu_tag": "2.19.0-cpu-py312-ubuntu22.04-sagemaker",<br/>  "tensorflow_gpu_tag": "2.19.0-gpu-py312-cu125-ubuntu22.04-sagemaker",<br/>  "tensorflow_inference_tag": "2.19.0-cpu-py312-ubuntu22.04-sagemaker"<br/>}</pre> | no |
| sbom\_retention\_days | How long SBOM JSON files are kept before S3 expires them. | `number` | `730` | no |
| spot\_max\_wait\_buffer\_seconds | Extra wait time (seconds) SageMaker holds for Spot capacity on top of MaxRuntime | `number` | `1800` | no |
| training\_data\_path | Training data S3 path | `string` | `"medical_image_data/"` | no |
| training\_input\_mode | SageMaker training input mode | `string` | `"FastFile"` | no |
| training\_keep\_alive\_seconds | KeepAlivePeriodInSeconds for warm pools. Set to 0 to disable. | `number` | `1800` | no |
| vpc\_config | Optional VPC for the training and processing jobs. Null runs them in the SageMaker service network. The subnets need a route to Amazon S3 (gateway endpoint), SageMaker API, CloudWatch Logs and ECR (interface endpoints or NAT); processing jobs also pip install packages, which needs a route to PyPI or a mirror. | <pre>object({<br/>    subnet_ids         = list(string)<br/>    security_group_ids = list(string)<br/>  })</pre> | `null` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| auto\_trigger\_eventbridge\_rule | Name of the EventBridge rule for auto-triggering pipeline |
| endpoint\_name | Name of the SageMaker endpoint |
| inference\_results\_bucket | Name of the inference results S3 bucket |
| kms\_key\_arn | ARN of the KMS key |
| kms\_key\_id | ID of the KMS key |
| mlflow\_tracking\_server\_arn | ARN of the MLflow tracking server. Null when enable\_mlflow = false. |
| mlflow\_tracking\_server\_url | URL of the MLflow tracking server. Null when enable\_mlflow = false. |
| model\_artifacts\_bucket | Name of the model artifacts S3 bucket |
| model\_package\_group\_name | Name of the model package group |
| monitoring\_bucket | Name of the monitoring S3 bucket |
| network\_isolation\_enabled | Whether the training jobs run with network isolation. When true, the ImageNet weights must be in s3://<scripts-bucket>/pretrained-weights/ (make weights). |
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
|-- auto_trigger.tf           # EventBridge rule, target and role that start the pipeline on upload
|-- backend.tf                # Partial S3 backend (values come from backend.hcl)
|-- backend.hcl.example       # Template for backend.hcl
|-- cloudtrail_budgets.tf     # Optional CloudTrail trail and bucket, AWS Budgets budget
|-- data.tf                   # Caller identity and SageMaker prebuilt image lookups
|-- main.tf                   # KMS, S3 buckets, execution role, registry, Model Card, MLflow, pipeline
|-- monitor.tf                # CloudWatch log groups, metric filters and training dashboard
|-- outputs.tf                # Buckets, pipeline, registry, IAM, KMS, MLflow, SBOM outputs
|-- pipeline.json.tftpl       # SageMaker pipeline definition (rendered by templatefile)
|-- providers.tf              # AWS provider with default_tags
|-- sbom.tf                   # SBOM bucket for the patched inference image builds
|-- terraform.tfvars          # Values for this environment
|-- terraform.tfvars.example  # Annotated example values
|-- variables.tf              # Input variables
`-- versions.tf               # Terraform and provider version constraints
```
