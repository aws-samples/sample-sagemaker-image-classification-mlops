# stack-inference

Serving and monitoring for the image classification sample: the SageMaker endpoint, the inference API behind AWS WAF, the CloudFront web UI, approval-driven auto-deployment, and the scheduled drift and fairness jobs that can trigger retraining.

## What It Does

1. Builds the patched inference image (one CodeBuild run at first apply, then monthly) in a tag-immutable ECR repository and pins it by digest
2. Creates the SageMaker model, endpoint configuration and **endpoint**, all Terraform-managed: blue/green deployment with auto-rollback alarms, data capture of model output, and target-tracking auto-scaling (or a serverless variant with `use_serverless_inference = true`)
3. Creates the inference Lambda with a Pillow/NumPy layer, built at apply time by `ops-scripts/build_lambda_layer.sh` when `lambda-layers/pillow-numpy-layer.zip` is missing
4. Creates an API Gateway REST API with `POST /predict` and `GET /results/{id}`, an API key and usage plan, stage throttling, and a regional AWS WAF web ACL
5. Hosts the static web UI in a private S3 bucket behind CloudFront; the page calls API Gateway directly with the API key
6. Creates the auto-deploy Lambda: when a package in the group changes to `Approved`, it creates a model and endpoint configuration and updates the endpoint (blue/green, with rollback)
7. Schedules two Processing jobs with EventBridge Scheduler: PSI drift hourly and Fairlearn fairness daily, each with a CloudWatch alarm
8. Creates an EventBridge rule that starts the training pipeline with `RetrainingReason=drift_detected` when either alarm fires
9. Creates SNS alerts, API and endpoint alarms, a composite health alarm, a CloudWatch dashboard and a weekly endpoint refresh
10. Creates a Bedrock guardrail when `enable_bedrock_hybrid_inference = true`, and the optional A2I review flow when `enable_human_review = true` (off by default; A2I is in maintenance mode)

## How the endpoint is managed

Terraform creates and owns the endpoint. It starts on the package in `model_package_arn`, which must be the versioned ARN of an **Approved** package. The auto-deploy Lambda later changes only the endpoint's `endpoint_config_name`, which Terraform ignores, so re-applies do not roll the endpoint back.

On a first deployment the group holds only the placeholder baseline that `make seed-baseline` (or the CI/CD BaselineModelCreation stage) registers as `PendingManualApproval`. Nothing approves it automatically: approve it once, then deploy:

```bash
aws sagemaker update-model-package --model-package-arn <arn> --model-approval-status Approved
make deploy-inference
```

`make deploy-inference` and the CI/CD Inference-Deploy stage both deploy the newest Approved package in the group and stop with an error when there is none. Set `TF_VAR_model_package_arn` to pin a version.

## Access control

The API requires the `x-api-key` header (`api_require_api_key`). The key is injected into the web UI, so it meters and limits callers but does not authenticate them. For authentication set `api_authorization_type` to `AWS_IAM` or `COGNITO_USER_POOLS`. WAF (`api_enable_waf`) applies the AWS managed common and known-bad-inputs rule sets and a per-IP rate limit (`api_waf_rate_limit`). See [SECURITY.md](../SECURITY.md).

## Monitoring inputs

- The drift job compares captured scores with a baseline at `s3://<monitoring-bucket>/monitoring/baselines/output-only/statistics.json` (a `{"scores": [...]}` document). The auto-deploy Lambda writes it after each rollout from the deployed package's `predictions.json` (the ensemble's test scores, next to `model.tar.gz`); the placeholder baseline has none. Without a baseline, or with fewer than `drift_detector_min_samples` captured predictions, the job publishes nothing.
- The fairness job joins capture on `InferenceId` with confirmed outcomes under `fairness_ground_truth_prefix` (`ground-truth/`). The sample does not populate that prefix, so the job publishes nothing until someone does.
- Both jobs need data capture and are skipped for serverless endpoints.

## Prerequisites

1. `stack-training` deployed; this stack reads its outputs through `terraform_remote_state` (`training/terraform.tfstate` in the state bucket named by `state_bucket_name`)
2. `backend.hcl` written (`make backend-config`)
3. An Approved package in the model package group (`make deploy-inference` resolves the newest one; `TF_VAR_model_package_arn` overrides it)
4. AWS CLI v2 (the first patched image build runs through `local-exec`), and bash, zip and uv or pip for the layer build
5. Amazon Bedrock access to `bedrock_model_id` if `enable_bedrock_hybrid_inference = true` (it is `true` in the shipped `terraform.tfvars`)

## Usage

From the repository root:

```bash
make layer                                            # optional; apply builds the zip when missing
make deploy-inference                                 # newest Approved package; TF_VAR_model_package_arn pins one

terraform -chdir=stack-inference output -raw api_gateway_url
terraform -chdir=stack-inference output -raw api_key_value
terraform -chdir=stack-inference output -raw frontend_cloudfront_url
```

`make deploy-inference` passes `state_bucket_name`, `state_bucket_region` and `permissions_boundary_arn` from the bootstrap outputs as `TF_VAR_*`.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | ~> 1.15 |
| aws | ~> 6.0 |
| awscc | ~> 1.0 |
| random | ~> 3.8 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | ~> 6.0 |
| random | ~> 3.8 |
| terraform | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_bedrock_guardrail.hybrid](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrock_guardrail) | resource |
| [aws_cloudwatch_dashboard.inference_dashboard](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_dashboard) | resource |
| [aws_cloudwatch_event_rule.drift_retrain](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_rule.weekly_endpoint_refresh](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_target.drift_retrain_pipeline](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_event_target.weekly_endpoint_refresh](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_metric_alarm.fairness_disparity](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.prediction_drift_psi](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_iam_role.drift_job_scheduler](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.drift_retrain](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.fairness_job_scheduler](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.drift_job_scheduler](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.drift_retrain](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.fairness_job_scheduler](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_lambda_layer_version.pillow](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_layer_version) | resource |
| [aws_lambda_permission.api_gateway_invoke](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_lambda_permission.eventbridge_invoke_refresher](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_scheduler_schedule.drift_job](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/scheduler_schedule) | resource |
| [aws_scheduler_schedule.fairness_job](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/scheduler_schedule) | resource |
| [random_id.frontend_suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |
| [terraform_data.pillow_layer_build](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| aws\_region | AWS region | `string` | n/a | yes |
| environment | Environment name | `string` | n/a | yes |
| project\_name | Name of the project. Prefixes every resource name. | `string` | n/a | yes |
| state\_bucket\_name | Name of the Terraform state bucket (stack-backend-setup output state\_bucket\_id). The inference stack reads the training stack's outputs from it. | `string` | n/a | yes |
| alert\_email | Email address for alerts | `string` | `""` | no |
| api\_authorization\_type | Authorization on POST /predict and GET /results/{id}. "NONE" (default)<br/>relies on the API key, usage plan and WAF; the key is visible to anyone who<br/>loads the frontend, so it limits and meters callers but does not<br/>authenticate them. To authenticate:<br/>  - "AWS\_IAM": callers sign with SigV4 and need execute-api:Invoke on the<br/>    API (browsers get credentials from a Cognito identity pool).<br/>  - "COGNITO\_USER\_POOLS": set api\_cognito\_user\_pool\_arns; callers send the<br/>    user pool ID token in the Authorization header. The static frontend<br/>    would need a sign-in flow added. | `string` | `"NONE"` | no |
| api\_cognito\_user\_pool\_arns | Cognito user pool ARNs for the API authorizer when api\_authorization\_type = "COGNITO\_USER\_POOLS". | `list(string)` | `[]` | no |
| api\_enable\_waf | Associate a regional AWS WAF web ACL (AWS managed common rule set + per-IP rate-based rule) with the API stage. | `bool` | `true` | no |
| api\_require\_api\_key | Require the x-api-key header on the API. The key is created with a usage plan and injected into the static frontend's config. | `bool` | `true` | no |
| api\_stage\_name | API Gateway stage name | `string` | `"prod"` | no |
| api\_throttling\_burst\_limit | API Gateway stage-wide burst limit - max concurrent requests. | `number` | `50` | no |
| api\_throttling\_rate\_limit | API Gateway stage-wide throttle - requests per second. Low default (20) protects a demo endpoint from bill-inflation attacks. | `number` | `20` | no |
| api\_waf\_rate\_limit | Requests per client IP in any 5-minute window before the WAF rate-based rule blocks that IP. | `number` | `300` | no |
| bedrock\_confidence\_threshold | Predictions with confidence below this route to Bedrock for additional reasoning. 0.70 per the blog. | `number` | `0.7` | no |
| bedrock\_model\_id | Bedrock model id (inference profile) used for low-confidence hybrid reasoning. Nova Pro is multimodal and accepts the base64 image. See https://docs.aws.amazon.com/nova/latest/userguide/modalities-image-examples.html | `string` | `"us.amazon.nova-pro-v1:0"` | no |
| data\_capture\_input | Also capture request payloads. Off by default: drift and fairness monitoring read model output only, and Input capture stores every uploaded image. | `bool` | `false` | no |
| data\_capture\_sampling\_percentage | Percentage of endpoint invocations written to data capture (0-100). Applies to the Terraform-managed and auto-deployed endpoint configs. | `number` | `100` | no |
| deployment\_max\_timeout | Maximum deployment timeout in seconds (600-14400) | `number` | `3600` | no |
| dlc\_ecr\_registry | ECR registry hostname for the AWS Deep Learning Containers. Defaults to commercial-region canonical DLC registry. Override for GovCloud/CN: see https://github.com/aws/deep-learning-containers/blob/master/available_images.md | `string` | `""` | no |
| dlc\_source\_repository | DLC repository name to pull and patch (e.g. tensorflow-inference, pytorch-inference) | `string` | `"tensorflow-inference"` | no |
| drift\_alarm\_period | Evaluation period (seconds) for the drift alarm. Should be >= the monitoring schedule interval (hourly = 3600) so each scheduled monitor run produces one data point. | `number` | `3600` | no |
| drift\_detector\_lookback\_hours | How many hours of captured predictions the drift detector compares against the baseline on each run. | `number` | `24` | no |
| drift\_detector\_min\_samples | Minimum captured predictions required before the detector publishes a PSI. Below this it publishes nothing, so quiet periods cannot raise a false drift alarm. | `number` | `30` | no |
| drift\_detector\_schedule\_expression | Schedule on which the drift Processing job runs. Should be no more frequent than the lookback window is long. | `string` | `"rate(1 hour)"` | no |
| drift\_job\_instance\_type | Instance type for the scheduled drift Processing job. The job is IO-bound over a few thousand small JSON records, so the smallest general-purpose type is sufficient. | `string` | `"ml.t3.medium"` | no |
| drift\_job\_max\_runtime | MaxRuntimeInSeconds for the drift Processing job. Caps cost if a capture prefix grows unexpectedly large. | `number` | `900` | no |
| drift\_threshold | Population Stability Index on the prediction-score distribution above which the drift alarm fires and retraining is triggered. | `number` | `0.2` | no |
| enable\_async\_explainability | When true, the inference response includes a pointer to where the asynchronous Grad-CAM/SHAP explainability artifact is written (Part 4). The artifact itself is produced by an async job; the API Lambda cannot run Grad-CAM inline (no TF runtime / conv-layer access in the served ensemble). | `bool` | `false` | no |
| enable\_bedrock\_hybrid\_inference | When true, the inference Lambda routes low-confidence predictions to an Amazon Bedrock foundation model for additional reasoning and a natural-language explanation (Part 3 hybrid inference). Adds bedrock:InvokeModel to the Lambda role. | `bool` | `false` | no |
| enable\_drift\_job | Enable the scheduled drift Processing job (Part 3). EventBridge Scheduler starts a SageMaker Processing job that reads endpoint data-capture output from S3, computes a Population Stability Index against the training baseline, and publishes it to CloudWatch, where the drift alarm and the EventBridge retrain rule consume it. Requires data capture, so it is skipped for serverless endpoints. | `bool` | `true` | no |
| enable\_fairness\_job | Enable the scheduled fairness Processing job (Part 4). EventBridge Scheduler starts a SageMaker Processing job that joins endpoint data capture with the confirmed diagnostic outcomes clinicians upload, computes demographic parity and equalized odds per subgroup with Fairlearn, and publishes the largest disparity to CloudWatch beside the drift metric. The alarm feeds the same retrain rule. Requires data capture, so it is skipped for serverless endpoints. | `bool` | `true` | no |
| enable\_human\_review | Opt in to Amazon A2I human review: create the review flow and let the inference Lambda route low-confidence predictions to a reviewer queue. Amazon A2I is in maintenance mode (no longer open to new customers), so this is off by default and only works in accounts that already use A2I. Requires review\_workteam\_arn for the flow definition. | `bool` | `false` | no |
| endpoint\_initial\_instance\_count | Initial number of instances for SageMaker endpoint | `number` | `1` | no |
| endpoint\_instance\_type | Instance type for SageMaker endpoint | `string` | `"ml.m5.xlarge"` | no |
| endpoint\_max\_capacity | Maximum number of instances for auto-scaling | `number` | `3` | no |
| endpoint\_min\_capacity | Minimum number of instances for auto-scaling | `number` | `1` | no |
| fairness\_alarm\_period | Evaluation period (seconds) for the fairness alarm. Should be >= the fairness schedule interval (daily = 86400) so each scheduled run produces one data point. | `number` | `86400` | no |
| fairness\_disparity\_threshold | Disparity above which the fairness alarm fires and retraining is triggered. Bounds the larger of demographic-parity difference and equalized-odds difference on live traffic. Mirrors var.fairness\_gate.max\_disparity in stack-training so the deployed model is held to the same bar it was registered under. | `number` | `0.1` | no |
| fairness\_ground\_truth\_prefix | Prefix in the monitoring bucket where confirmed diagnostic outcomes are uploaded as JSON Lines: {"request\_id": ..., "label": 0\|1, "group": "<subgroup>"}. Predictions with no matching label are skipped, never guessed. | `string` | `"ground-truth"` | no |
| fairness\_job\_instance\_type | Instance type for the scheduled fairness Processing job. The job is IO-bound over a few thousand small JSON records, so the smallest general-purpose type is sufficient. | `string` | `"ml.t3.medium"` | no |
| fairness\_job\_lookback\_hours | How many hours of captured predictions and confirmed outcomes the fairness job scores on each run. Wider than the drift window (a week by default) because ground truth lags the prediction it confirms. | `number` | `168` | no |
| fairness\_job\_max\_runtime | MaxRuntimeInSeconds for the fairness Processing job. Caps cost if the capture or ground-truth prefix grows unexpectedly large. | `number` | `900` | no |
| fairness\_job\_min\_samples | Minimum prediction/outcome pairs required before the fairness job publishes a disparity. Below this it publishes nothing, so a thin join cannot raise a false fairness alarm. | `number` | `50` | no |
| fairness\_job\_schedule\_expression | Schedule on which the fairness Processing job runs. Daily by default: confirmed outcomes arrive on a clinical cadence, so a tighter schedule would mostly re-score the same records. | `string` | `"rate(1 day)"` | no |
| inference\_lambda\_reserved\_concurrency | Reserved concurrent executions for the inference API Lambda. Caps blast-radius of a traffic spike on /predict and prevents starvation of other functions in the account. -1 = unreserved (account default). | `number` | `50` | no |
| lambda\_memory\_size | Lambda function memory size in MB | `number` | `1024` | no |
| lambda\_timeout | Lambda function timeout in seconds | `number` | `300` | no |
| log\_retention\_days | CloudWatch log retention in days | `number` | `14` | no |
| max\_image\_bytes | Max size of a base64-encoded image accepted by the /predict endpoint. Images above this size return HTTP 413 without invoking SageMaker. Default 5 MB is generous for 224x224 histopathology. | `number` | `5242880` | no |
| model\_package\_arn | Versioned ARN of the Approved model package the endpoint starts with (arn:aws:sagemaker:<region>:<account>:model-package/<group>/<version>). Seed and approve a baseline first (CI/CD baseline-model stage or stack-cicd/scripts/create\_baseline\_model.py). Later approvals are rolled out by the auto-deploy Lambda. | `string` | `""` | no |
| monitoring\_job\_image\_tag | Tag of the AWS-managed scikit-learn Processing image used to run the scheduled drift and fairness scripts. Must carry a numpy/pandas/scikit-learn stack that already satisfies Fairlearn, otherwise pip upgrades numpy at job start and the container's pre-compiled scikit-learn fails with a binary-incompatibility ValueError. The 1.2-1 image is too old on both counts (pandas 1.1.3). | `string` | `"1.4-2-cpu-py3"` | no |
| patched\_image\_source\_tag | DLC source tag to base the patched inference image on. Use the floating major.minor tag (no -v1.X suffix) to auto-pick up the latest AWS patch version. | `string` | `"2.19.0-cpu-py312-ubuntu22.04-sagemaker"` | no |
| permissions\_boundary\_arn | ARN of the permissions boundary attached to every IAM role this stack creates (stack-backend-setup output workload\_boundary\_arn). Required when CI/CD CodeBuild applies the stack; null leaves the roles unbounded. | `string` | `null` | no |
| review\_workteam\_arn | ARN of the SageMaker private workteam that reviews flagged cases. The private workforce is a one-time per-account Cognito setup outside this codebase. Empty = task UI is created but no flow definition (no review queue). | `string` | `""` | no |
| serverless\_max\_concurrency | Maximum concurrent invocations per serverless variant (1-200). | `number` | `10` | no |
| serverless\_memory\_size\_mb | Memory (MB) per serverless inference worker. Valid values: 1024, 2048, 3072, 4096, 5120, 6144. | `number` | `3072` | no |
| state\_bucket\_region | Region of the Terraform state bucket (stack-backend-setup output state\_bucket\_region). If empty, aws\_region is used. | `string` | `""` | no |
| target\_concurrent\_requests\_per\_model | Target concurrent in-flight requests per model container. Uses the SageMaker high-resolution metric (10s granularity) for sub-minute scale-out. | `number` | `5` | no |
| termination\_wait\_seconds | Seconds to wait after deployment before terminating old fleet | `number` | `120` | no |
| use\_serverless\_inference | Opt-in flag to deploy the endpoint as a SageMaker Serverless Inference<br/>variant instead of an always-on instance. Recommended for low-traffic<br/>demo/blog endpoints: scales to zero when idle and can cut the monthly<br/>bill from ~$170 to ~$5-10. Not recommended when drift-detection data<br/>capture or strict p50 latency matter - see the sagemaker-endpoint<br/>module README for the full tradeoff list. | `bool` | `false` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| api\_gateway\_url | API Gateway URL for inference |
| api\_key\_id | ID of the API key the frontend sends. Read the value with: terraform output -raw api\_key\_value |
| api\_key\_value | Value of the API key for the x-api-key header (sensitive) |
| api\_web\_acl\_arn | ARN of the WAF web ACL on the API stage |
| auto\_deployment\_eventbridge\_rule | Name of the EventBridge rule for auto-deployment |
| auto\_deployment\_lambda\_arn | ARN of the auto-deployment Lambda function |
| dashboard\_url | CloudWatch inference dashboard URL |
| endpoint\_arn | ARN of the SageMaker endpoint |
| endpoint\_error\_rate\_alarm\_arn | ARN of the CloudWatch alarm for endpoint error rate |
| endpoint\_error\_rate\_alarm\_name | Name of the CloudWatch alarm for endpoint error rate (used for auto-rollback) |
| endpoint\_latency\_alarm\_arn | ARN of the CloudWatch alarm for endpoint latency |
| endpoint\_latency\_alarm\_name | Name of the CloudWatch alarm for endpoint latency (used for auto-rollback) |
| endpoint\_name | Name of the SageMaker endpoint |
| frontend\_cloudfront\_distribution\_id | CloudFront distribution ID for cache invalidation |
| frontend\_cloudfront\_url | CloudFront URL for frontend |
| frontend\_s3\_bucket | S3 bucket name for frontend |
| inference\_bucket\_name | S3 bucket name for inference data |
| lambda\_function\_names | Lambda function names |
| log\_groups | CloudWatch log group names |
| serving\_image\_uri | Patched inference image, pinned by digest, used by the endpoint and the auto-deploy Lambda |
| sns\_topic\_arn | SNS topic ARN for alerts |
<!-- END_TF_DOCS -->

## File Structure

```
stack-inference/
|-- backend.tf                  # Partial S3 backend (values come from backend.hcl)
|-- backend.hcl.example         # Template for backend.hcl
|-- checks.tf                   # CloudFront distribution health check
|-- data.tf                     # Remote state, images, Lambda layer build, locals, dashboard, alarms
|-- deploy-frontend.sh          # Invalidates the CloudFront cache after an apply
|-- lambda/                     # Lambda source
|   |-- inference_handler.py    # POST /predict and GET /results/{id}
|   |-- endpoint_refresher.py   # Weekly endpoint refresh
|   |-- mlops_common/           # Copy of scripts/mlops_common (scripts/sync_mlops_common.sh)
|   `-- requirements.txt
|-- lambda-layers/              # Pillow/NumPy layer (zip built by ops-scripts/build_lambda_layer.sh)
|   `-- requirements.txt
|-- main.tf                     # Endpoint, Lambdas, API Gateway, IAM, patched image, auto-deploy, frontend
|-- monitoring.tf               # Drift and fairness schedules and alarms, retrain rule, A2I, Bedrock guardrail
|-- outputs.tf                  # API URL and key, frontend URL, endpoint, alarms, Lambda names
|-- providers.tf                # AWS and AWS Cloud Control providers
|-- static-frontend/
|   `-- index.html.tpl          # Web UI template (API URL and key injected)
|-- terraform.tfvars            # Values for this environment
|-- variables.tf                # Input variables
`-- versions.tf                 # Terraform and provider version constraints
```
