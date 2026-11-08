# stack-inference

Serving and monitoring for the image classification sample: the Amazon SageMaker AI endpoint, the inference API behind AWS WAF, the Amazon CloudFront web UI, approval-driven auto-deployment, and the scheduled drift and fairness jobs that can trigger retraining.

## What It Does

1. Builds the patched inference image (one AWS CodeBuild run at first apply, then weekly) in a tag-immutable Amazon Elastic Container Registry (Amazon ECR) repository and pins it by digest
2. Creates the SageMaker model, endpoint configuration and **endpoint**, all Terraform-managed: blue/green deployment with canary traffic shifting (`traffic_routing_type`, 10% of the new fleet first by default, two instances) and auto-rollback alarms, data capture of model output, and target-tracking auto-scaling (or a serverless variant with `use_serverless_inference = true`)
3. Creates the inference AWS Lambda function with a Pillow/NumPy layer, built at apply time by `ops-scripts/build_lambda_layer.sh` when `lambda-layers/pillow-numpy-layer.zip` is missing
4. Creates an Amazon API Gateway REST API with `POST /predict` and `GET /results/{id}`, an API key and usage plan, stage throttling, and a regional AWS WAF web ACL; with `api_authorization_type = "COGNITO_USER_POOLS"` also an Amazon Cognito user pool and app client, and a Cognito authorizer on both methods
5. Hosts the static web UI in a private Amazon S3 bucket behind CloudFront; the page calls API Gateway directly with the API key
6. Creates the auto-deploy Lambda: when a package in the group changes to `Approved`, it creates a model and endpoint configuration and updates the endpoint with the same canary policy and rollback alarms (the endpoint module's `deployment_config_json`)
7. Schedules two Processing jobs with Amazon EventBridge Scheduler: PSI drift hourly and Fairlearn fairness daily, each with an Amazon CloudWatch alarm. Both run in the training VPC (an Amazon VPC that `stack-training` creates) when `stack-training` has one (its `job_vpc_config` output)
8. Creates an Amazon EventBridge rule that starts the training pipeline with `RetrainingReason=drift_detected` when either alarm fires
9. Creates the Amazon SNS alerts topic (encrypted with the project AWS KMS key from `stack-training`, so CloudWatch alarms can deliver to it), API and endpoint alarms, a composite health alarm, a CloudWatch dashboard and a weekly endpoint refresh (same canary policy). Log groups keep `log_retention_days` (365 by default)
10. Creates an Amazon Bedrock guardrail when `enable_bedrock_hybrid_inference = true` (the Lambda calls Bedrock only with a guardrail configured), and the optional Amazon Augmented AI (Amazon A2I) review flow when `enable_human_review = true` (off by default; A2I is in maintenance mode). The flow writes its output encrypted with the project KMS key, which the A2I module takes as an input
11. With `test_traffic_enabled = true` (off by default), creates an hourly synthetic test traffic Lambda and schedule for test deployments (see [Test traffic](#test-traffic))

## How the endpoint is managed

Terraform creates and owns the endpoint. It starts on the package in `model_package_arn`, which must be the versioned ARN of an **Approved** package. The auto-deploy Lambda later changes only the endpoint's `endpoint_config_name`, which Terraform ignores, so re-applies do not roll the endpoint back.

On a first deployment the group holds only the placeholder baseline that `make seed-baseline` (or the CI/CD BaselineModelCreation stage) registers as `PendingManualApproval`. Nothing approves it automatically: approve it once, then deploy:

```bash
aws sagemaker update-model-package --model-package-arn <arn> --model-approval-status Approved
make deploy-inference
```

`make deploy-inference` and the CI/CD Inference-Deploy stage both deploy the newest Approved package in the group and stop with an error when there is none. Set `TF_VAR_model_package_arn` to pin a version.

## Explanations

A `POST /predict` body with `"explain": true` also returns a Grad-CAM heatmap
and region Shapley values for the prediction (contract and method in the root
README, [Explanations in the response](../README.md#explanations-in-the-response)).
The Lambda forwards the flag to the endpoint with the caps from
`explanation_max_evaluations` and `explanation_time_budget_ms`; callers cannot
raise them. The endpoint computes both in TensorFlow Serving from signatures
exported with each member model, so the explain path needs no extra packages
in the serving image. `enable_request_explanations = false` turns the option
off. Requests without the field are unchanged.

When the response carries a Grad-CAM grid, the Lambda also measures how much of
the heatmap sits on the image border and adds two fields:
`"border_attention_fraction"` (share of the Grad-CAM mass in the outer
`gradcam_border_band` of each side, 10 percent by default) and
`"attention_on_border"` (true when that share is above
`gradcam_border_threshold`, 0.5 by default). A flagged prediction relied on
image edges, capture artefacts or padding rather than the subject; treat it
like a low-confidence one. With a 14x14 grid and the default band, the border is the
outermost ring of cells (about 27 percent of the image), so a heatmap spread
evenly over the image scores about 0.27.

## Access control

The API requires the `x-api-key` header (`api_require_api_key`). The key is injected into the web UI, so it meters and limits callers but does not authenticate them. WAF (`api_enable_waf`) applies the AWS managed common and known-bad-inputs rule sets and a per-IP rate limit (`api_waf_rate_limit`). Both stay on in every authorization mode. See [SECURITY.md](../SECURITY.md).

| `api_authorization_type` | Who can call the API |
| --- | --- |
| `NONE` (default, API key mode) | Anyone with the API key. The static web UI works only in this mode. |
| `COGNITO_USER_POOLS` | Application users signed in to Amazon Cognito, plus the API key. API Gateway rejects a request without a valid ID token (401) before the Lambda or the endpoint runs. |
| `AWS_IAM` | Callers that sign with SigV4 and hold `execute-api:Invoke` on the API, plus the API key. |

### Cognito mode

Set `api_authorization_type = "COGNITO_USER_POOLS"` and apply. The stack creates a user pool (`cognito.tf`) and an app client without a secret; set `api_cognito_user_pool_arns` instead to use pools you already run. The pool has no self sign-up (administrators create users), signs users in with their email address, requires 12-character passwords with upper case, lower case, digits and symbols, and offers authenticator-app MFA (`cognito_mfa_configuration`: `OPTIONAL` by default, or `ON`). Threat protection (`cognito_threat_protection_mode`) is `OFF` by default; `AUDIT` or `ENFORCED` moves the pool to the Plus feature plan, billed per monthly active user. Deletion protection (`cognito_deletion_protection`) is off so `terraform destroy` removes the pool; turn it on once the pool holds real users. User pool data is encrypted at rest with an AWS owned key.

The static web UI has no sign-in flow yet, so it stops working in this mode. Call the API with an ID token instead:

```bash
POOL_ID="$(terraform -chdir=stack-inference output -raw cognito_user_pool_id)"
CLIENT_ID="$(terraform -chdir=stack-inference output -raw cognito_app_client_id)"
API_URL="$(terraform -chdir=stack-inference output -raw api_gateway_url)"
API_KEY="$(terraform -chdir=stack-inference output -raw api_key_value)"

# Create a user (no invitation email) and give it a permanent password.
aws cognito-idp admin-create-user --user-pool-id "$POOL_ID" --username reviewer@example.com \
  --user-attributes Name=email,Value=reviewer@example.com Name=email_verified,Value=true \
  --message-action SUPPRESS
printf 'Password: '; read -rs PASSWORD; echo
aws cognito-idp admin-set-user-password --user-pool-id "$POOL_ID" --username reviewer@example.com \
  --password "$PASSWORD" --permanent

# Sign in (operator credentials; a browser app uses SRP) and call the API.
ID_TOKEN="$(aws cognito-idp admin-initiate-auth --user-pool-id "$POOL_ID" --client-id "$CLIENT_ID" \
  --auth-flow ADMIN_USER_PASSWORD_AUTH \
  --auth-parameters "USERNAME=reviewer@example.com,PASSWORD=$PASSWORD" \
  --query AuthenticationResult.IdToken --output text)"
curl -sS -X POST "$API_URL/predict" -H "Authorization: $ID_TOKEN" -H "x-api-key: $API_KEY" \
  -H "Content-Type: application/json" -d "{\"image\": \"$(base64 < sample.png | tr -d '\n')\"}"
```

ID tokens last 60 minutes and refresh tokens 12 hours. With `cognito_mfa_configuration = "ON"`, or once a user has turned on MFA, `admin-initiate-auth` returns an `MFA_SETUP` or `SOFTWARE_TOKEN_MFA` challenge instead of tokens; answer it with `admin-respond-to-auth-challenge`.

## Monitoring inputs

- The drift job compares captured scores with a baseline at `s3://<monitoring-bucket>/monitoring/baselines/output-only/statistics.json` (a `{"scores": [...]}` document). The auto-deploy Lambda writes it after each rollout from the deployed package's `predictions.json` (the ensemble's test scores, next to `model.tar.gz`); the placeholder baseline has none. Without a baseline, or with fewer than `drift_detector_min_samples` captured predictions, the job publishes nothing.
- The fairness job joins capture on `InferenceId` with ground-truth labels under `fairness_ground_truth_prefix` (`ground-truth/`). The sample does not populate that prefix, so the job publishes nothing until someone does.
- Both jobs need data capture and are skipped for serverless endpoints.
- When `stack-training` has a job VPC (the training VPC, or its `vpc_config`), both jobs run in it (`local.scheduled_job_network_config` in `monitoring.tf`): they reach Amazon S3 through its gateway endpoint and publish metrics through its CloudWatch metrics interface endpoint (`training_vpc_monitoring_endpoint` in `stack-training`), and the fairness job installs Fairlearn from the wheelhouse in the scripts bucket. Network isolation stays off because the scripts call S3 and CloudWatch themselves.

## Test traffic

An idle test endpoint never gets the `drift_detector_min_samples` (30) captured predictions the drift job needs in its window, so monitoring is never exercised. `test_traffic.tf` adds optional synthetic traffic for test deployments only; never turn it on for an endpoint that serves real users.

- `test_traffic_enabled` (default `false`) creates the `<project_name>-test-traffic` Lambda (`test-traffic/test_traffic.py`) and an EventBridge Scheduler schedule, `rate(1 hour)` with a 60-minute flexible time window, so each run starts at a random point within the hour. No retries.
- `test_traffic_end_date` (RFC 3339 UTC, for example `2026-11-28T00:00:00Z`) is required when it is on; the schedule stops after that time.
- Each run picks 1 to `test_traffic_max_requests` (default 5, at most 20) random `.jpg`, `.jpeg` or `.png` images from any class folder under `training_data_path` (default `images/`) in the raw-data bucket of `stack-training`, waits a random 0 to 20 seconds between them, and invokes the inference Lambda directly with an API Gateway proxy-shaped `POST /predict` event, so the requests do not pass API Gateway, WAF, the API key or Cognito. `test_traffic_explain_rate` (default 0.1) is the share that ask for explanations, which are CPU heavy on the endpoint.
- Its role can only list and read `training_data_path` in the raw-data bucket, decrypt with the project key and invoke the inference function.

The predictions land in data capture like real ones. If they move the score distribution past `drift_threshold` (0.2 by default, 0.1 in the shipped `terraform.tfvars`), the drift alarm fires and the retrain rule starts a training pipeline execution (`RetrainingReason=drift_detected`), which runs the full set of training and Processing jobs and is billed like any other run. Keep the end date close to the end of your test, and stop any execution you do not want.

## Prerequisites

1. `stack-training` deployed; this stack reads its outputs through `terraform_remote_state` (`training/terraform.tfstate` in the state bucket named by `state_bucket_name`)
2. `backend.hcl` written (`make backend-config`)
3. An Approved package in the model package group (`make deploy-inference` resolves the newest one; `TF_VAR_model_package_arn` overrides it)
4. AWS CLI v2 (the first patched image build runs through `local-exec`), and bash, zip and uv or pip for the layer build
5. Amazon Bedrock access to `bedrock_model_id` if `enable_bedrock_hybrid_inference = true` (it is `true` in the shipped `terraform.tfvars`)

## Usage

From the repository root:

```bash
make layer                                            # builds the layer zip from the pinned Pillow and NumPy
make deploy-inference                                 # newest Approved package; TF_VAR_model_package_arn pins one

terraform -chdir=stack-inference output -raw api_gateway_url
terraform -chdir=stack-inference output -raw api_key_value
terraform -chdir=stack-inference output -raw frontend_cloudfront_url
```

`make deploy-inference` passes `state_bucket_name`, `state_bucket_region` and `permissions_boundary_arn` from the bootstrap outputs as `TF_VAR_*`.

## Destroy

`force_destroy_buckets` defaults to `true`, so `terraform destroy` empties and deletes the frontend bucket; set it to `false` to keep the bucket when it is not empty. The Cognito user pool is deleted with the stack unless `cognito_deletion_protection = true`.

The endpoint configurations and models that the auto-deploy and refresher Lambdas create are not in Terraform state. Run `./ops-scripts/cleanup_all.sh` first (or `make destroy`, which runs it with `--destroy` and destroys every stack in order), then destroy this stack before `stack-training`, because it reads that stack's state. Leave `TF_VAR_model_package_arn` unset: the cleanup has deleted the model packages, and a set value makes the destroy read the package it names. Full order: [Cleanup](../README.md#cleanup) in the root README.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | ~> 1.15 |
| aws | ~> 6.54 |
| awscc | ~> 1.0 |
| random | ~> 3.8 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | ~> 6.54 |
| random | ~> 3.8 |
| terraform | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_bedrock_guardrail.hybrid](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrock_guardrail) | resource |
| [aws_bedrock_guardrail_version.hybrid](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrock_guardrail_version) | resource |
| [aws_cloudwatch_dashboard.inference_dashboard](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_dashboard) | resource |
| [aws_cloudwatch_event_rule.drift_retrain](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_rule.weekly_endpoint_refresh](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_target.drift_retrain_pipeline](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_event_target.weekly_endpoint_refresh](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_metric_alarm.fairness_disparity](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.prediction_drift_psi](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.scheduler_dlq_visible](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cognito_user_pool.app_users](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cognito_user_pool) | resource |
| [aws_cognito_user_pool_client.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cognito_user_pool_client) | resource |
| [aws_iam_role.drift_job_scheduler](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.drift_retrain](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.fairness_job_scheduler](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.test_traffic_scheduler](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.drift_job_scheduler](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.drift_retrain](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.fairness_job_scheduler](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.test_traffic_scheduler](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_lambda_layer_version.pillow](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_layer_version) | resource |
| [aws_lambda_permission.api_gateway_invoke](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_lambda_permission.eventbridge_invoke_refresher](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_scheduler_schedule.drift_job](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/scheduler_schedule) | resource |
| [aws_scheduler_schedule.fairness_job](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/scheduler_schedule) | resource |
| [aws_scheduler_schedule.test_traffic](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/scheduler_schedule) | resource |
| [aws_sqs_queue.scheduler_dlq](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue) | resource |
| [aws_sqs_queue_policy.scheduler_dlq](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue_policy) | resource |
| [random_id.frontend_suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |
| [terraform_data.pillow_layer_build](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| aws\_region | AWS region | `string` | n/a | yes |
| environment | Environment name | `string` | n/a | yes |
| permissions\_boundary\_arn | ARN of the permissions boundary attached to every IAM role this stack creates (stack-backend-setup output workload\_boundary\_arn). Required: make and the CI/CD stages pass it as TF\_VAR\_permissions\_boundary\_arn. | `string` | n/a | yes |
| project\_name | Name of the project. Prefixes every resource name. | `string` | n/a | yes |
| state\_bucket\_name | Name of the Terraform state bucket (stack-backend-setup output state\_bucket\_id). The inference stack reads the training stack's outputs from it. | `string` | n/a | yes |
| alert\_email | Email address for alerts | `string` | `""` | no |
| api\_authorization\_type | Authorization on POST /predict and GET /results/{id}. The API key, usage<br/>plan and WAF apply in every mode.<br/>  - "NONE" (default, API key mode): the key is visible to anyone who<br/>    loads the frontend, so it limits and meters callers but does not<br/>    authenticate them. The static frontend works in this mode only.<br/>  - "COGNITO\_USER\_POOLS": Amazon Cognito authenticates application<br/>    users. The stack creates a user pool and app client<br/>    (unless api\_cognito\_user\_pool\_arns names existing pools); callers send<br/>    the user's ID token in the Authorization header. The static frontend<br/>    has no sign-in flow yet.<br/>  - "AWS\_IAM": callers sign with SigV4 and need execute-api:Invoke on the<br/>    API (browsers get credentials from a Cognito identity pool). | `string` | `"NONE"` | no |
| api\_cognito\_user\_pool\_arns | Existing Cognito user pool ARNs for the API authorizer when api\_authorization\_type = "COGNITO\_USER\_POOLS". Empty (default) creates a user pool in this stack. | `list(string)` | `[]` | no |
| api\_enable\_waf | Associate a regional AWS WAF web ACL (AWS managed common rule set + per-IP rate-based rule) with the API stage. | `bool` | `true` | no |
| api\_require\_api\_key | Require the x-api-key header on the API. The key is created with a usage plan and injected into the static frontend's config. | `bool` | `true` | no |
| api\_stage\_name | API Gateway stage name | `string` | `"prod"` | no |
| api\_throttling\_burst\_limit | API Gateway stage-wide burst limit - max concurrent requests. | `number` | `50` | no |
| api\_throttling\_rate\_limit | API Gateway stage-wide throttle - requests per second. Low default (20) protects a demo endpoint from bill-inflation attacks. | `number` | `20` | no |
| api\_waf\_rate\_limit | Requests per client IP in any 5-minute window before the WAF rate-based rule blocks that IP. | `number` | `300` | no |
| bedrock\_confidence\_threshold | Predictions with confidence below this route to Bedrock for additional reasoning. 0.70 per the blog. | `number` | `0.7` | no |
| bedrock\_guardrail\_image\_filters | Also run the guardrail's HATE, INSULTS, SEXUAL and VIOLENCE filters on the image sent to the foundation model. The Bedrock image content filter is generally available in us-east-1, us-west-2, eu-central-1 and ap-northeast-1 and in preview in some other Regions; set false in a Region without it. | `bool` | `true` | no |
| bedrock\_model\_id | Bedrock model id (inference profile) used for low-confidence hybrid reasoning. Nova Pro is multimodal and accepts the base64 image. See https://docs.aws.amazon.com/nova/latest/userguide/modalities-image-examples.html | `string` | `"us.amazon.nova-pro-v1:0"` | no |
| canary\_size\_percent | Percentage of the new fleet that takes traffic during the canary step (1-50). Capacity comes in whole instances, so with 2 instances the canary is 1 instance, half the fleet. | `number` | `10` | no |
| cognito\_deletion\_protection | Turn on deletion protection for the stack's Cognito user pool. Off by default so terraform destroy removes the pool with the stack; turn it on when the pool holds real users. | `bool` | `false` | no |
| cognito\_mfa\_configuration | MFA for the stack's Cognito user pool: OPTIONAL (default; users can add an authenticator app) or ON (every user sets up an authenticator app at first sign-in). | `string` | `"OPTIONAL"` | no |
| cognito\_threat\_protection\_mode | Cognito threat protection (compromised credentials, adaptive authentication) for the stack's user pool: OFF (default, Essentials feature plan), AUDIT or ENFORCED. AUDIT and ENFORCED switch the pool to the Plus feature plan, which is billed per monthly active user. | `string` | `"OFF"` | no |
| data\_capture\_input | Also capture request payloads. Off by default: drift and fairness monitoring read model output only, and Input capture stores every uploaded image. | `bool` | `false` | no |
| data\_capture\_sampling\_percentage | Percentage of endpoint invocations written to data capture (0-100). Applies to the Terraform-managed and auto-deployed endpoint configs. | `number` | `100` | no |
| deployment\_max\_timeout | Maximum deployment time in seconds (600-28800). Must exceed the traffic shift waits plus termination\_wait\_seconds. | `number` | `3600` | no |
| dlc\_ecr\_registry | ECR registry hostname for the AWS Deep Learning Containers. Defaults to commercial-region canonical DLC registry. Override for GovCloud/CN: see https://github.com/aws/deep-learning-containers/blob/master/available_images.md | `string` | `""` | no |
| dlc\_source\_repository | DLC repository name to pull and patch (e.g. tensorflow-inference, pytorch-inference) | `string` | `"tensorflow-inference"` | no |
| drift\_alarm\_period | Evaluation period (seconds) for the drift alarm. Should be >= the monitoring schedule interval (hourly = 3600) so each scheduled monitor run produces one data point. | `number` | `3600` | no |
| drift\_detector\_lookback\_hours | How many hours of captured predictions the drift detector compares against the baseline on each run. | `number` | `24` | no |
| drift\_detector\_min\_samples | Minimum captured predictions required before the detector publishes a PSI. Below this it publishes nothing, so quiet periods cannot raise a false drift alarm. | `number` | `30` | no |
| drift\_detector\_schedule\_expression | Schedule on which the drift Processing job runs. Should be no more frequent than the lookback window is long. | `string` | `"rate(1 hour)"` | no |
| drift\_job\_instance\_type | Instance type for the scheduled drift Processing job. The job is IO-bound over a few thousand small JSON records, so the smallest general-purpose type is sufficient. | `string` | `"ml.t3.medium"` | no |
| drift\_job\_max\_runtime | MaxRuntimeInSeconds for the drift Processing job. Caps cost if a capture prefix grows unexpectedly large. | `number` | `900` | no |
| drift\_threshold | Population Stability Index on the prediction-score distribution above which the drift alarm fires and retraining is triggered. | `number` | `0.2` | no |
| enable\_bedrock\_hybrid\_inference | When true, the inference Lambda routes low-confidence predictions to an Amazon Bedrock foundation model for additional reasoning and a natural-language explanation (Part 3 hybrid inference). Adds bedrock:InvokeModel to the Lambda role. | `bool` | `false` | no |
| enable\_drift\_job | Enable the scheduled drift Processing job (Part 3). EventBridge Scheduler starts a SageMaker Processing job that reads endpoint data-capture output from S3, computes a Population Stability Index against the training baseline, and publishes it to CloudWatch, where the drift alarm and the EventBridge retrain rule consume it. Requires data capture, so it is skipped for serverless endpoints. | `bool` | `true` | no |
| enable\_fairness\_job | Enable the scheduled fairness Processing job. EventBridge Scheduler starts a SageMaker Processing job that joins endpoint data capture with the confirmed labels you upload, computes demographic parity and equalized odds per subgroup with Fairlearn, and publishes the largest disparity to CloudWatch beside the drift metric. The alarm feeds the same retrain rule. Requires data capture, so it is skipped for serverless endpoints. | `bool` | `true` | no |
| enable\_human\_review | Opt in to Amazon A2I human review: create the review flow and let the inference Lambda route low-confidence predictions to a reviewer queue. Amazon A2I is in maintenance mode (no longer open to new customers), so this is off by default and only works in accounts that already use A2I. Requires review\_workteam\_arn for the flow definition. | `bool` | `false` | no |
| enable\_request\_explanations | Allow POST /predict callers to ask for explanations (Part 4) with "explain": true (Grad-CAM heatmap and region Shapley values, computed on the endpoint). Requests without the field are unaffected either way. When false, a request that asks gets "explanations": {"status": "disabled"}. | `bool` | `true` | no |
| endpoint\_initial\_instance\_count | Instances in the endpoint's production variant, for the Terraform-created and auto-deployed endpoint configs. 2 by default because canary and linear traffic shifting cannot split a single instance; use 1 only with traffic\_routing\_type = ALL\_AT\_ONCE. | `number` | `2` | no |
| endpoint\_instance\_type | Instance type for SageMaker endpoint | `string` | `"ml.m5.xlarge"` | no |
| endpoint\_max\_capacity | Maximum number of instances for auto-scaling | `number` | `3` | no |
| endpoint\_min\_capacity | Minimum number of instances for auto-scaling. 2 by default because canary and linear traffic shifting cannot split a single instance. | `number` | `2` | no |
| endpoint\_network\_isolation | Run the endpoint's inference container with network isolation (no outbound network). The auto-deploy Lambda creates its models the same way. | `bool` | `true` | no |
| explanation\_max\_evaluations | Cap on masked-image ensemble evaluations for the region Shapley estimate in one explained request. 17 is one permutation of the 4x4 regions, 32 an antithetic pair, 64 two pairs. | `number` | `32` | no |
| explanation\_time\_budget\_ms | Time budget for the explain path on the endpoint, in milliseconds. Region Shapley skips permutations that would overrun it (the first always runs). Keep it well under API Gateway's 29 s integration timeout. | `number` | `5000` | no |
| fairness\_alarm\_period | Evaluation period (seconds) for the fairness alarm. Should be >= the fairness schedule interval (daily = 86400) so each scheduled run produces one data point. | `number` | `86400` | no |
| fairness\_disparity\_threshold | Disparity above which the fairness alarm fires and retraining is triggered. Bounds the larger of demographic-parity difference and equalized-odds difference on live traffic. Mirrors var.fairness\_gate.max\_disparity in stack-training so the deployed model is held to the same bar it was registered under. | `number` | `0.1` | no |
| fairness\_ground\_truth\_prefix | Prefix in the monitoring bucket where confirmed labels are uploaded as JSON Lines: {"request\_id": ..., "label": 0\|1, "group": "<subgroup>"}. Predictions with no matching label are skipped, never guessed. | `string` | `"ground-truth"` | no |
| fairness\_job\_instance\_type | Instance type for the scheduled fairness Processing job. The job is IO-bound over a few thousand small JSON records, so the smallest general-purpose type is sufficient. | `string` | `"ml.t3.medium"` | no |
| fairness\_job\_lookback\_hours | How many hours of captured predictions and confirmed outcomes the fairness job scores on each run. Wider than the drift window (a week by default) because ground truth lags the prediction it confirms. | `number` | `168` | no |
| fairness\_job\_max\_runtime | MaxRuntimeInSeconds for the fairness Processing job. Caps cost if the capture or ground-truth prefix grows unexpectedly large. | `number` | `900` | no |
| fairness\_job\_min\_samples | Minimum prediction/outcome pairs required before the fairness job publishes a disparity. Below this it publishes nothing, so a thin join cannot raise a false fairness alarm. | `number` | `50` | no |
| fairness\_job\_schedule\_expression | Schedule on which the fairness Processing job runs. Daily by default: confirmed labels usually arrive slowly, so a tighter schedule would mostly re-score the same records. | `string` | `"rate(1 day)"` | no |
| force\_destroy\_buckets | Let terraform destroy delete this stack's frontend bucket with its objects and versions. True by default so the stack tears down in one step; set false to keep the bucket when it is not empty. | `bool` | `true` | no |
| gradcam\_border\_band | Width of the image border band, as a fraction of each side, for the Grad-CAM border check. An explained prediction whose heatmap puts more than gradcam\_border\_threshold of its mass in this band is returned with "attention\_on\_border": true. | `number` | `0.1` | no |
| gradcam\_border\_threshold | Share of the Grad-CAM mass in the border band (gradcam\_border\_band) above which an explained prediction is flagged with "attention\_on\_border": true. | `number` | `0.5` | no |
| inference\_lambda\_reserved\_concurrency | Reserved concurrent executions for the inference API Lambda. Caps blast-radius of a traffic spike on /predict and prevents starvation of other functions in the account. -1 = unreserved (account default). | `number` | `50` | no |
| lambda\_memory\_size | Lambda function memory size in MB | `number` | `1024` | no |
| lambda\_timeout | Lambda function timeout in seconds | `number` | `300` | no |
| linear\_step\_percent | Percentage of the new fleet turned on per LINEAR step (10-50). | `number` | `20` | no |
| log\_retention\_days | CloudWatch log retention in days | `number` | `365` | no |
| max\_image\_bytes | Max size of a base64-encoded image accepted by the /predict endpoint. Images above this size return HTTP 413 without invoking SageMaker. Default 5 MB is generous for 224x224 images. | `number` | `5242880` | no |
| model\_package\_arn | Versioned ARN of the Approved model package the endpoint starts with (arn:aws:sagemaker:<region>:<account>:model-package/<group>/<version>). Seed and approve a baseline first (CI/CD baseline-model stage or stack-cicd/scripts/create\_baseline\_model.py). Later approvals are rolled out by the auto-deploy Lambda. | `string` | `""` | no |
| monitoring\_job\_image\_tag | Tag of the AWS-managed scikit-learn Processing image used to run the scheduled drift and fairness scripts. Must carry a numpy/pandas/scikit-learn stack that already satisfies Fairlearn, otherwise pip upgrades numpy at job start and the container's pre-compiled scikit-learn fails with a binary-incompatibility ValueError. The 1.2-1 image is too old on both counts (pandas 1.1.3). | `string` | `"1.4-2-cpu-py3"` | no |
| patched\_image\_scan\_block\_severity | Scan gate of the weekly patched image build: an image with an Amazon ECR scan finding at or above this severity is deleted and the build fails, so the endpoint keeps the last image that passed (an alarm notifies alert\_email). CRITICAL (default), HIGH, MEDIUM, LOW, or NONE to turn the gate off. | `string` | `"CRITICAL"` | no |
| patched\_image\_source\_tag | DLC source tag to base the patched inference image on. Use the floating major.minor tag (no -v1.X suffix) to auto-pick up the latest AWS patch version, and move to a newer major.minor when AWS stops publishing patches for this one (the 2.19 Ubuntu tag stopped on 2026-03-10). | `string` | `"2.20-cpu-py312-amzn2023-sagemaker"` | no |
| review\_workteam\_arn | ARN of the SageMaker private workteam that reviews flagged cases. The private workforce is a one-time per-account Cognito setup outside this codebase. Empty = task UI is created but no flow definition (no review queue). | `string` | `""` | no |
| serverless\_max\_concurrency | Maximum concurrent invocations per serverless variant (1-200). | `number` | `10` | no |
| serverless\_memory\_size\_mb | Memory (MB) per serverless inference worker. Valid values: 1024, 2048, 3072, 4096, 5120, 6144. | `number` | `3072` | no |
| state\_bucket\_region | Region of the Terraform state bucket (stack-backend-setup output state\_bucket\_region). If empty, aws\_region is used. | `string` | `""` | no |
| target\_concurrent\_requests\_per\_model | Target concurrent in-flight requests per model container. Uses the SageMaker high-resolution metric (10s granularity) for sub-minute scale-out. | `number` | `5` | no |
| termination\_wait\_seconds | Seconds to wait after the new fleet takes all traffic before the old fleet is terminated (0-3600) | `number` | `120` | no |
| test\_traffic\_enabled | Send synthetic test traffic (test\_traffic.tf): once an hour at a random minute, 1 to test\_traffic\_max\_requests images from the raw-data bucket go to the inference function, so the drift and fairness jobs have predictions to measure. Test deployments only. | `bool` | `false` | no |
| test\_traffic\_end\_date | UTC time (RFC 3339, e.g. 2026-11-28T00:00:00Z) after which the test traffic schedule stops. Required when test\_traffic\_enabled = true. | `string` | `null` | no |
| test\_traffic\_explain\_rate | Share of test traffic requests that ask for explanations (Grad-CAM and region Shapley); explanations are CPU heavy on the endpoint. | `number` | `0.1` | no |
| test\_traffic\_max\_requests | Most predictions one test traffic run sends; each run picks 1 to this many at random. | `number` | `5` | no |
| traffic\_routing\_type | Blue/green traffic shifting for endpoint updates, including approval-driven and weekly-refresh rollouts: CANARY (canary\_size\_percent of the new fleet first, then the rest), LINEAR (linear\_step\_percent per step) or ALL\_AT\_ONCE. CANARY and LINEAR need endpoint\_initial\_instance\_count and endpoint\_min\_capacity of at least 2. Serverless endpoints always use ALL\_AT\_ONCE. | `string` | `"CANARY"` | no |
| traffic\_shift\_wait\_interval | Baking period in seconds after each traffic shift step while the rollback alarms watch the new fleet (0-3600). The alarms need about 3 minutes to fire (2 one-minute periods plus CloudWatch delay), so keep it above that. | `number` | `300` | no |
| use\_serverless\_inference | Opt-in flag to deploy the endpoint as a SageMaker Serverless Inference<br/>variant instead of an always-on instance. Recommended for low-traffic<br/>demo/blog endpoints: scales to zero when idle and can cut the monthly<br/>bill from ~$340 (two instances) to ~$5-10. Updates then shift all<br/>traffic at once (no canary). Not recommended when drift-detection data<br/>capture or strict p50 latency matter - see the sagemaker-endpoint<br/>module README for the full tradeoff list. | `bool` | `false` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| api\_gateway\_url | API Gateway URL for inference |
| api\_key\_id | ID of the API key the frontend sends. Read the value with: terraform output -raw api\_key\_value |
| api\_key\_value | Value of the API key for the x-api-key header (sensitive) |
| api\_web\_acl\_arn | ARN of the WAF web ACL on the API stage |
| auto\_deployment\_eventbridge\_rule | Name of the EventBridge rule for auto-deployment |
| auto\_deployment\_lambda\_arn | ARN of the auto-deployment Lambda function |
| cognito\_app\_client\_id | ID of the Cognito app client that signs users in for the API (null when the stack creates no user pool) |
| cognito\_user\_pool\_id | ID of the stack's Cognito user pool for application users (null unless api\_authorization\_type = "COGNITO\_USER\_POOLS" and no existing pool is given) |
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
|-- cognito.tf                  # Cognito user pool and app client (COGNITO_USER_POOLS mode)
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
|-- outputs.tf                  # API URL and key, Cognito IDs, frontend URL, endpoint, alarms, Lambda names
|-- providers.tf                # AWS and AWS Cloud Control providers
|-- static-frontend/
|   |-- index.html.tpl          # Web UI page
|   |-- app.js.tpl              # Web UI script (API URL and key injected)
|   `-- app.css                 # Web UI styles
|-- terraform.tfvars            # Values for this environment
|-- test-traffic/               # Synthetic test traffic Lambda source (test_traffic.py)
|-- test_traffic.tf             # Optional hourly test traffic: Lambda, role, schedule
|-- variables.tf                # Input variables
`-- versions.tf                 # Terraform and provider version constraints
```
