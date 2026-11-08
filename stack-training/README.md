# stack-training

Amazon SageMaker AI training infrastructure for the image classification sample: data and model Amazon S3 buckets, the Amazon SageMaker Pipelines pipeline (validation, preprocessing, three trainers, evaluation, ensemble, fairness check, quality gate, registration), the SageMaker Model Registry, a Model Card and cost controls.

## What It Does

1. Creates an AWS Key Management Service (AWS KMS) key with rotation for the stack's buckets, logs and SageMaker jobs
2. Creates 6 S3 buckets (raw data, processed data, scripts, model artifacts, inference results, monitoring), plus an SBOM bucket when `enable_sbom_bucket = true` (default) and an AWS CloudTrail bucket when `enable_cloudtrail = true` (default). The inference results bucket expires stored predictions and uploaded images, and their noncurrent versions, after `inference_results_retention_days` (default 30). `bucket_defaults.force_destroy` defaults to `true` on all of them, so `terraform destroy` empties and deletes them (see [Destroy](#destroy))
3. Creates two AWS Identity and Access Management (IAM) roles for SageMaker, both carrying the workload permissions boundary from the required `permissions_boundary_arn` (see [SageMaker roles](#sagemaker-roles))
4. Creates the Model Package Group and, with `enable_model_card = true` (default), a Model Card
5. Creates the SageMaker pipeline from `pipeline.json.tftpl`: 9 top-level steps (ValidateDataset, PreprocessData, three training steps, EvaluateAllModels, CreateEnsembleModel, BiasCheck, and the Condition step), whose branches are RegisterEnsembleModel or Fail, plus one optional step that is off by default: TrainSimpleCnnBaseline (`baseline_cnn`)
6. With `training_vpc_enabled = true` (default), creates the private Amazon Virtual Private Cloud (Amazon VPC) every Processing and Training job of the pipeline and the scheduled drift and fairness jobs of `stack-inference` run in (see [Training VPC](#training-vpc))
7. Creates an Amazon EventBridge rule that starts the pipeline with `RetrainingReason=data_upload` when the `.batch_complete` marker is written to the raw data bucket
8. With `enable_upload_quarantine = true` (default), creates the upload quarantine AWS Lambda function (see [Upload quarantine](#upload-quarantine))
9. Creates Amazon CloudWatch log groups (kept `log_retention_days`, default 365), metric filters and a training dashboard, and an AWS Budgets budget (`monthly_budget_usd`, default 200)
10. With `enable_cloudtrail = true` (default), creates a multi-region CloudTrail trail (see [Audit trail](#audit-trail))
11. Optionally creates a managed MLflow tracking server (`enable_mlflow`, default `false`)

## Training VPC

Every Processing and Training job of the pipeline runs in a VPC that `network.tf` creates (`training_vpc_enabled`, default `true`). The scheduled drift and fairness Processing jobs of `stack-inference` run in it too: that stack reads the `job_vpc_config` output from this stack's state. The VPC has:

- two private subnets in two Availability Zones (`training_vpc_cidr`, default `10.42.0.0/24`, split in two), with no internet gateway and no NAT gateway, so the jobs have no internet access;
- an Amazon S3 gateway endpoint on the subnets' route table, whose policy allows only the six project buckets;
- an Amazon CloudWatch metrics (`com.amazonaws.<region>.monitoring`) interface endpoint in both subnets with private DNS (`training_vpc_monitoring_endpoint`, default `true`), so the drift and fairness jobs can publish their metrics with PutMetricData. Its own security group admits HTTPS only from the jobs' security group. Interface endpoints are billed per Availability Zone hour, here two AZs, whether or not a job runs;
- a security group for the jobs with no inbound rule except from itself (the instances of one multi-instance job, which SageMaker asks for) and outbound rules for HTTPS to the S3 prefix list, HTTPS to the CloudWatch metrics endpoint (when it exists) and traffic to itself;
- the VPC's default security group managed with no rules, and VPC flow logs (`training_vpc_flow_logs`, default `true`) to `/aws/vpc/<project_name>-training/flow-logs`, encrypted with the project key and kept `log_retention_days`.

SageMaker pulls the container images and ships the job logs itself, so the subnets need no route to Amazon ECR or CloudWatch Logs. The training jobs keep network isolation on (`enable_network_isolation`). Every Processing and Training job of the pipeline turns on inter-container traffic encryption, which the jobs' security group allows (it admits all traffic between its members, including UDP 500 and ESP, protocol 50). The processing steps that install Python packages (validation, preprocessing, BiasCheck, and the scheduled fairness job) install them from the wheelhouses `scripts/script_uploader.sh` builds and uploads to `<step>/wheels/` in the scripts bucket, because PyPI is out of reach; `make upload-scripts` therefore needs `pip` and PyPI access on the machine that runs it. Both SageMaker roles get the Amazon Elastic Compute Cloud (Amazon EC2) network-interface actions SageMaker needs for VPC jobs on `Resource "*"`: the SageMaker documentation says not to scope them, or the job-creation checks fail.

`vpc_config` places the jobs in subnets of your own instead (it takes precedence); its security groups must allow UDP 500 and ESP (protocol 50) between their members for the inter-container traffic encryption of multi-instance jobs. `training_vpc_enabled = false` with no `vpc_config` runs them in the SageMaker service network, as before. The `job_vpc_config` output gives the subnets and security group in use.

## SageMaker roles

- **Job role** (`<project_name>-sagemaker-job-role`): the role of every Processing and Training step of the pipeline. It reads the scripts, raw data, processed data and model artifacts buckets, and writes only the job outputs: `executions/` in the processed data bucket, and `models/`, `checkpoints/`, `evaluation/`, `ensemble/`, `bias/`, `debug-output/` and `baselines/` in the model artifacts bucket (it deletes only spot-training checkpoints). It cannot write the scripts or the raw data, calls no SageMaker API and pulls only the training images. With `backbone_weights_s3_uri` it also reads every object under that URI, and with `enable_mlflow` it logs to the tracking server and writes `mlflow-artifacts/`.
- **Execution role** (`<project_name>-sagemaker-execution-role`): the pipeline role, which starts, watches and stops the jobs, passes them the job role and registers the model package; and, in `stack-inference`, the role of the endpoint model, the scheduled drift and fairness jobs and the Amazon Augmented AI (Amazon A2I) flow, plus the MLflow tracking server here. It reads the scripts, model artifacts, inference results and monitoring buckets, writes only the monitoring bucket (data capture, fairness reports, A2I output) and, with MLflow, `mlflow-artifacts/`, and pulls the serving images and the scheduled jobs' scikit-learn image.
- Neither role can approve a model package (`sagemaker:UpdateModelPackage`), deploy or change an endpoint, or change scaling and alarms. People approve packages with their own credentials, and the auto-deploy and endpoint refresher Lambda functions in `stack-inference` have their own roles.

## Audit trail

`enable_cloudtrail = true` (default) creates a multi-region trail with log-file validation, encrypted with the project key, delivered to its own bucket (`cloudtrail_retention_days`, 400) and to the CloudWatch log group `/aws/cloudtrail/<project_name>`. Advanced event selectors record:

- all management events in the account;
- S3 data events (object-level calls such as GetObject and PutObject) on the six project buckets and the SBOM bucket, but not on the trail's own bucket;
- Lambda data events (Invoke) on functions named `<project_name>-*` in `aws_region`, which covers the upload quarantine Lambda here and the inference, endpoint refresher, auto-deploy and (when enabled) test traffic Lambdas of `stack-inference`.

Data events are billed per event: a training run reads every image several times, so expect up to a few hundred thousand S3 data events per pipeline execution (about USD 0.10 per 100,000). In an account that an organization trail already records, set `enable_cloudtrail = false` and add these data event selectors to that trail instead.

## Upload quarantine

An EventBridge rule on the raw-data bucket's Object Created events under `training_data_path` invokes a Lambda once per uploaded object. EventBridge is the same event source the pipeline trigger uses: S3 allows one notification configuration per bucket, and the bucket's sends everything to EventBridge. The Lambda:

- keeps an object that has an allowed extension (`.jpg`, `.jpeg`, `.png`, the extensions validation and preprocessing read), opens with Pillow as the format that extension names (verified and fully decoded, so truncated files fail), and is at least `quarantine_min_image_size_px` (112, the validation step's hard minimum) on both sides;
- otherwise copies it to `<quarantine_prefix><original key>` (default `quarantine/`), writes `<quarantine_prefix><original key>.reason.json` with the reason, ETag, size and time, deletes the original, and adds 1 to the `QuarantinedImages` metric (namespace `<project_name>/DataQuality`, dimension `Bucket`);
- ignores the `.batch_complete` marker, keys outside `training_data_path` and anything already under `quarantine_prefix`.

`quarantine_prefix` must sit outside `training_data_path` (a variable validation checks it), so neither the pipeline trigger nor the validation and preprocessing inputs read quarantined files. The bucket is versioned, so the deleted original stays recoverable as a noncurrent version.

The function uses the `terraform-aws-lambda` module: KMS-encrypted environment and log group (`log_retention_days`), active AWS X-Ray tracing, an Amazon SQS dead-letter queue (TLS-only queue policy) encrypted with the project key plus a queue-depth alarm, reserved concurrency (`upload_quarantine_reserved_concurrency`, 10) and the workload permissions boundary. Its role can read and delete only under `training_data_path`, write only under `quarantine_prefix`, and publish metrics only to its namespace. Pillow comes from a layer built from the same zip and script as the inference Lambda's layer (`ops-scripts/build_lambda_layer.sh`, Pillow 13.0.0); `make layer` builds it, and the apply builds it on the first deploy and again whenever the build script changes, so a version bump always reaches the layer.

The checks run as files arrive, while the marker starts the pipeline as soon as the upload script writes it, so a large upload can start the pipeline before the Lambda has reached every file. The validation step checks every image again and fails the run on a bad one, so nothing unchecked reaches training. For a clean first run, wait for the Lambda to catch up (its CloudWatch `Invocations` metric flattens) before writing the marker, or rerun the pipeline.

## Pipeline behaviour

- **Excluded images.** ValidateDataset writes `exclusion_manifest.json` next to `validation_report.json`: every image that fails the blur, contrast and edge-density check is listed with its reason and metrics, logged as a warning and counted (`DataValidation_ExcludedCount`), and preprocessing leaves it out of all three splits. Unreadable and too-small images still fail the step. The per-class minimum and the class-balance check count only the images that remain.
- **Classes and positive class.** ValidateDataset expects exactly two class folders under `training_data_path` (default `images/`, so `s3://<raw-data-bucket>/images/<class>/<file>`); the folder name is the label. `positive_class` (passed to the steps as `POSITIVE_CLASS`) names the class that recall, the decision threshold and the endpoint's probability refer to; by default it is the second folder in alphabetical order. File names give the group id and an optional subgroup (`<group>__<name>.<ext>` or `<group>__<subgroup>__<name>.<ext>`). An optional `manifest.csv` at the data root (columns `file,label,group` plus attribute columns, `subgroup` among them) overrides both; validation fails when its `label` does not match the folder. See [Datasets and model weights](../README.md#datasets-and-model-weights).
- **Group-aware split, sharded.** Preprocessing resizes images to `preprocessing_target_size` (512) and splits train, validation and test by group id (the `manifest.csv` `group` column, else the `<group>__` file name prefix, else the image alone), so one group's images never cross splits. Each split also gets `classes.json` and its `manifest.csv`. It runs on `pipeline_steps.preprocessing.instance_count` instances (2 in `terraform.tfvars`) with the raw images spread over them (`ShardedByS3Key`). Every instance computes the split from ValidateDataset's `image_inventory.json` of all images, so the assignment is the same on all of them, and writes only the images it holds; the instances' uploads together form the splits. With more than one instance and no inventory the step fails rather than split on a partial view.
- **Per-execution data.** The validation report and the splits go to `executions/<pipeline-execution-id>/` in the processed-data bucket, so two runs never mix; S3 expires them after `processed_data_retention_days` (30). Deployments older than this layout keep stale `train/`, `validation/`, `test/` and `validation-reports/` prefixes that nothing reads; delete them by hand.
- **Thresholds tuned on validation.** Evaluation and the ensemble tune their decision thresholds on the validation split; the quality gate is scored on the test split at that threshold.
- **Fairness gate on the ensemble.** BiasCheck runs Fairlearn over the ensemble's own test predictions at its tuned threshold, per subgroup of `fairness_gate.sensitive_feature` (default `subgroup`, from the `<group>__<subgroup>__` file name or `manifest.csv`). When no image carries it the check is skipped: `bias_metrics.json` has status `skipped` and `max_disparity` 0.0, the step logs it, and the gate passes. With the column but fewer than two subgroups the result is "not evaluable" and fails the gate unless `allow_not_evaluable = true` (default false; meant for small demo datasets).
- **Gate.** The Condition step requires the `AccuracyThreshold`, `RecallThreshold`, `PrecisionThreshold` and `AucThreshold` pipeline parameters (defaults from `quality_gate`: 0.85, 0.95, 0.80, 0.90; recall is the recall of the positive class) and `fairness_gate.max_disparity` (0.10). A pass registers the ensemble as `PendingManualApproval`; a miss ends in the Fail step. Because the bars are parameters, an execution can raise or lower one without a code change, for example `aws sagemaker start-pipeline-execution --pipeline-name <name> --pipeline-parameters Name=RecallThreshold,Value=0.97`. The evaluation and ensemble steps receive the same values in `QUALITY_GATE` (the recall bar drives their threshold search), the gate report (`quality_gate` in `ensemble_results.json`) shows each value, bar and gap, and the registered package records the bars it cleared (`*_threshold` metadata).
- **Fairness metrics.** BiasCheck reports demographic parity, equalized odds and equal opportunity (true-positive-rate gap, from a Fairlearn `MetricFrame`); `max_disparity` stays the larger of the first two.
- **Per-execution artifacts.** Evaluation, ensemble and bias outputs go to `<prefix>/<pipeline-execution-id>/` in the model artifacts bucket, and the registered package's `ModelDataUrl` points at that execution's `model.tar.gz`.
- **Lineage.** `RetrainingReason`, `DatasetVersion` and `CodeCommitSha` are pipeline parameters recorded on the model package. The Terraform variables only set their defaults; the upload rule passes `data_upload` and the drift rule in `stack-inference` passes `drift_detected`.
- **Training from scratch, or from your own backbone weights.** VGG16, DenseNet121 and EfficientNetV2-M are built in Keras code without weights. By default each trains from random initialisation in one phase with every layer trainable. `backbone_weights_s3_uri` (default empty) points the training jobs at your own backbone weights: the pipeline adds a `weights` input channel (File mode) and sets `BACKBONE_WEIGHTS_S3_URI`, each trainer loads `<model>.weights.h5` (`vgg16`, `densenet121`, `efficientnet`, `simple_cnn`) or the single `.h5` file there, and the backbones then fine-tune in two phases (frozen, then the top layers unfrozen). Backbone files hold Keras weights for the architecture without its classification top; the `simple_cnn` file holds the whole model. A trainer fails with a clear error when the URI is set but the channel is missing, empty or ambiguous. The job role may read every object under the URI, and the permissions boundary must admit them too (`boundary_extra_s3_arns` in `stack-backend-setup`: the bucket ARN and `arn:aws:s3:::<bucket>/<key>*`). You are responsible for the license of any weights you bring.
- **Network isolation.** `enable_network_isolation = true` (default) runs the training jobs without outbound network access; optional weights arrive through the `weights` input channel. All jobs run in the [training VPC](#training-vpc).
- **Optional steps.** `baseline_cnn.enabled = true` adds TrainSimpleCnnBaseline: a small CNN trained from scratch on the same splits with the same loader, class weights and augmentation (flips, shifts, rotations, brightness and the `color_jitter_sigma` colour/intensity jitter), which also writes `test_metrics.json` (validation-tuned threshold, as the evaluation step does) into its artifact under `baselines/simple_cnn/`, for comparison with the three ensemble members. It is not an ensemble member and is never registered.
- **Instance types.** The shipped `terraform.tfvars` trains on `ml.c5.2xlarge` (CPU) with 2 epochs, sized for a smoke test. Instance types starting `ml.g` or `ml.p` use the GPU training image; they need a SageMaker training quota.

## Prerequisites

1. `stack-backend-setup` applied and `backend.hcl` written (`make backend-config`)
2. Terraform `~> 1.15` and AWS CLI v2
3. After apply: the scripts uploaded (`make upload-scripts`, which builds the wheelhouses and so needs `pip` and PyPI access on the machine that runs it), and training data uploaded with `scripts/data_uploader.sh`
4. `training_data_path` (default `images/`) set to the prefix the uploader writes to (`--prefix`, default `images`), and `auto_trigger_marker_key` to the marker it writes (`images/.batch_complete`)

## Usage

From the repository root:

```bash
make deploy-training     # terraform init -backend-config=backend.hcl, plan -out, apply
make upload-scripts      # pipeline scripts to the scripts bucket

# Upload your own labeled images (one folder per class, optional manifest.csv); the marker starts the pipeline
./scripts/data_uploader.sh data/my-images
```

`make deploy-training` passes `state_bucket_name`, `state_bucket_region` and `permissions_boundary_arn` from the bootstrap outputs as `TF_VAR_*`.

## Destroy

`bucket_defaults.force_destroy` defaults to `true`, so `terraform destroy` empties every bucket of this stack (raw data, processed data, scripts, model artifacts, inference results, monitoring, SBOM and the CloudTrail log bucket, all object versions included) and deletes it. That removes the training data, the model artifacts and the audit logs. To keep them, set `force_destroy = false` in `bucket_defaults` before destroying; the destroy then stops at the first non-empty bucket.

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
| terraform | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_budgets_budget.monthly](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/budgets_budget) | resource |
| [aws_cloudtrail.audit](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudtrail) | resource |
| [aws_cloudwatch_event_rule.new_data_uploaded](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_rule.upload_quarantine](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_target.pipeline_trigger](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_event_target.upload_quarantine](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_log_group.cloudtrail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_group.training_vpc_flow_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_metric_alarm.upload_quarantine_dlq](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_default_security_group.training](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/default_security_group) | resource |
| [aws_flow_log.training](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/flow_log) | resource |
| [aws_iam_role.cloudtrail_cwl](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.eventbridge_sagemaker_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.training_vpc_flow_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.cloudtrail_cwl](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.eventbridge_sagemaker_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.training_vpc_flow_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_lambda_layer_version.quarantine_pillow](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_layer_version) | resource |
| [aws_route_table.training](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table_association.training](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_s3_bucket_policy.cloudtrail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_sagemaker_mlflow_tracking_server.mlflow](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sagemaker_mlflow_tracking_server) | resource |
| [aws_sagemaker_model_card.image_model](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sagemaker_model_card) | resource |
| [aws_sagemaker_model_package_group.image_models](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sagemaker_model_package_group) | resource |
| [aws_sagemaker_pipeline.image_pipeline](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sagemaker_pipeline) | resource |
| [aws_security_group.monitoring_endpoint](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_security_group.training_jobs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_sns_topic.cloudtrail_notifications](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic) | resource |
| [aws_sns_topic_policy.cloudtrail_notifications](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_policy) | resource |
| [aws_sqs_queue.upload_quarantine_dlq](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue) | resource |
| [aws_sqs_queue_policy.upload_quarantine_dlq](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue_policy) | resource |
| [aws_subnet.training](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_vpc.training](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc) | resource |
| [aws_vpc_endpoint.monitoring](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint) | resource |
| [aws_vpc_endpoint.s3](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint) | resource |
| [aws_vpc_security_group_egress_rule.jobs_to_jobs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_egress_rule.jobs_to_monitoring_endpoint](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_egress_rule.jobs_to_s3](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.jobs_from_jobs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.monitoring_endpoint_from_jobs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [random_id.bucket_suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |
| [random_id.cloudtrail_suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |
| [random_id.sbom_suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |
| [terraform_data.quarantine_layer_build](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| aws\_region | AWS region | `string` | n/a | yes |
| environment | Environment name | `string` | n/a | yes |
| models | Configuration for all training models | <pre>map(object({<br/>    script_name     = string<br/>    tar_file        = string<br/>    step_name       = string<br/>    hyperparameters = map(string)<br/>    volume_size     = number<br/>    instance_count  = number<br/>    max_runtime     = number<br/>    instance_type   = string<br/>    enable_cache    = bool<br/>    cache_expiry    = string<br/>  }))</pre> | n/a | yes |
| permissions\_boundary\_arn | ARN of the permissions boundary attached to every IAM role this stack creates (stack-backend-setup output workload\_boundary\_arn). Required: make and the CI/CD stages pass it as TF\_VAR\_permissions\_boundary\_arn. | `string` | n/a | yes |
| pipeline\_steps | Configuration for pipeline processing steps | <pre>map(object({<br/>    instance_type  = string<br/>    instance_count = number<br/>    volume_size    = number<br/>    script_name    = string<br/>    step_name      = string<br/>    step_type      = string<br/>    enable_cache   = bool<br/>    cache_expiry   = string<br/>  }))</pre> | n/a | yes |
| project\_name | Name of the project, used as the prefix of every resource name. Lowercase letters, digits and hyphens. Together with environment it is capped so the longest derived name (the inference-results bucket) stays within the 63-character S3 limit. | `string` | n/a | yes |
| access\_log\_retention\_days | Days the access-log bucket keeps S3 server access logs. | `number` | `365` | no |
| allow\_not\_evaluable | Let the fairness gate pass when the test split has fewer than two subgroups of fairness\_gate.sensitive\_feature, so disparity cannot be measured (status not\_evaluable). Default false fails the pipeline instead; set true only for small demo datasets. | `bool` | `false` | no |
| audit\_bucket\_force\_destroy | Let terraform destroy delete the CloudTrail log bucket with its logs. Default false keeps the audit logs; empty the bucket (or set true) before destroying the stack. | `bool` | `false` | no |
| auto\_trigger\_marker\_key | Object key prefix in the raw-data bucket whose creation starts the pipeline. scripts/data\_uploader.sh writes this marker after a batch upload completes. | `string` | `"images/.batch_complete"` | no |
| backbone\_weights\_s3\_uri | Optional S3 URI of your own backbone weights: a prefix holding one <model>.weights.h5 per model, or a single .h5 file. The training jobs may read every object whose key starts with the URI's key (the S3Prefix channel downloads them all). Add the bucket and that prefix to boundary\_extra\_s3\_arns in stack-backend-setup. Empty trains from random initialisation. | `string` | `""` | no |
| baseline\_cnn | Optional training step for a small CNN trained from scratch (scripts/training/simple\_cnn\_trainer.py), the baseline the transfer-learning members are compared against. It trains on the same splits, also scores the test split (test\_metrics.json in its model artifact), and is never part of the ensemble or registered. Upload the tarball with scripts/script\_uploader.sh first. | <pre>object({<br/>    enabled         = bool<br/>    instance_type   = string<br/>    volume_size     = number<br/>    max_runtime     = number<br/>    hyperparameters = map(string)<br/>  })</pre> | <pre>{<br/>  "enabled": false,<br/>  "hyperparameters": {<br/>    "TRAINING_BATCH_SIZE": "32",<br/>    "TRAINING_EPOCHS": "30",<br/>    "TRAINING_LEARNING_RATE": "0.001"<br/>  },<br/>  "instance_type": "ml.c5.2xlarge",<br/>  "max_runtime": 7200,<br/>  "volume_size": 50<br/>}</pre> | no |
| bucket\_defaults | Default configuration for S3 buckets | <pre>object({<br/>    force_destroy       = bool<br/>    enable_versioning   = bool<br/>    block_public_access = bool<br/>  })</pre> | <pre>{<br/>  "block_public_access": true,<br/>  "enable_versioning": true,<br/>  "force_destroy": true<br/>}</pre> | no |
| budget\_alert\_emails | Email addresses that receive AWS Budgets alerts at 80% actual and 100% forecasted thresholds. | `list(string)` | `[]` | no |
| budget\_start\_date | Start of the AWS Budgets period, in the format YYYY-MM-DD\_HH:MM (UTC). | `string` | `"2026-01-01_00:00"` | no |
| cloudtrail\_retention\_days | Days to retain CloudTrail logs in S3 before lifecycle deletion. Ship to a SIEM or archive if your audit policy needs longer. | `number` | `400` | no |
| code\_commit\_sha | Default of the CodeCommitSha pipeline parameter: the Git commit that produced the model, recorded on the model package for audit lineage. Override per execution from CI. | `string` | `"local"` | no |
| dashboard\_config | Dashboard configuration JSON | `string` | `""` | no |
| dashboard\_name | CloudWatch dashboard name | `string` | `null` | no |
| data\_config | Data processing configuration | <pre>object({<br/>    content_type     = string<br/>    compression_type = string<br/>    s3_data_type     = string<br/>    s3_input_mode    = string<br/>    s3_upload_mode   = string<br/>  })</pre> | <pre>{<br/>  "compression_type": "None",<br/>  "content_type": "application/x-image",<br/>  "s3_data_type": "S3Prefix",<br/>  "s3_input_mode": "File",<br/>  "s3_upload_mode": "EndOfJob"<br/>}</pre> | no |
| dataset\_version | Default of the DatasetVersion pipeline parameter (for example a DVC hash such as dataset-v2.3-sha256:...), recorded on the registered model package for audit lineage. Override per execution from CI. | `string` | `"unversioned"` | no |
| debugger\_rule\_image | SageMaker Debugger rule-evaluator image URI for your Region, pinned to a version tag (see https://docs.aws.amazon.com/sagemaker/latest/dg/debugger-docker-images-rules.html). Required when enable\_debugger = true. | `string` | `null` | no |
| enable\_auto\_trigger | Enable auto-trigger of pipeline on new data upload | `bool` | `true` | no |
| enable\_cloudtrail | Create a multi-region CloudTrail trail with log-file integrity validation that records management events and data events (S3 object-level calls on the project buckets, invocations of the project Lambda functions). Set false when an organization trail already records this account. | `bool` | `true` | no |
| enable\_cloudtrail\_sns | Attach an SNS delivery-notification topic to the CloudTrail. Off by default. The topic is encrypted with the project CMK, whose key policy then grants the CloudTrail service principal (CloudTrail cannot publish to a topic on the AWS-managed alias/aws/sns key). The trail and S3/CloudWatch delivery work without it. | `bool` | `false` | no |
| enable\_debugger | Attach SageMaker Debugger built-in rules (Overfit, LossNotDecreasing) to the training steps. Off by default; the CloudWatch training metrics (and MLflow when enable\_mlflow = true) cover the same need. Amazon SageMaker Debugger is no longer open to new customers; existing customers can continue to use it. | `bool` | `false` | no |
| enable\_experiments | Associate each training step with a SageMaker Experiment trial component via ExperimentConfig. | `bool` | `true` | no |
| enable\_kms\_key\_rotation | Enable KMS key rotation | `bool` | `true` | no |
| enable\_managed\_spot\_training | Use EC2 Spot for all training steps. Requires checkpoint support in trainers. | `bool` | `true` | no |
| enable\_mlflow | Create a managed SageMaker MLflow tracking server (Small) for experiment tracking. Off by default because it is billed for every hour it runs. | `bool` | `false` | no |
| enable\_model\_card | Create a SageMaker Model Card documenting intended use and risk rating for the model package group. | `bool` | `true` | no |
| enable\_network\_isolation | Run the training jobs with network isolation (no outbound network access from the training container); backbone\_weights\_s3\_uri still reaches them as an input channel. Processing jobs are not isolated: they reach Amazon S3 through the training VPC (training\_vpc\_enabled). | `bool` | `true` | no |
| enable\_s3\_access\_logging | Create an access-log bucket (SSE-S3, which S3 server access logging requires) and send every project bucket's server access logs to it. | `bool` | `true` | no |
| enable\_sbom\_bucket | Create a dedicated S3 bucket to receive Syft-generated CycloneDX SBOMs from the patched-image CodeBuild. Low monthly cost; safe to leave on even if you don't wire the patched image yet. | `bool` | `true` | no |
| enable\_training\_monitoring | Enable training monitoring | `bool` | `true` | no |
| enable\_upload\_quarantine | Check every object uploaded under training\_data\_path in the raw-data bucket with a Lambda (allowed extension, opens with Pillow as that format, minimum size) and move failing files to quarantine\_prefix with a .reason.json next to each. The pipeline validation step still checks every image. | `bool` | `true` | no |
| fairness\_gate | Fairness gate the ensemble must clear before registration. max\_disparity bounds the larger of demographic-parity difference and equalized-odds difference, computed by scripts/bias/compute\_bias.py with Fairlearn. Must mirror DEFAULT\_THRESHOLD in that script. sensitive\_feature names the subgroup attribute reported in the bias report; use an attribute your data carries. | <pre>object({<br/>    max_disparity     = number<br/>    sensitive_feature = string<br/>  })</pre> | <pre>{<br/>  "max_disparity": 0.1,<br/>  "sensitive_feature": "subgroup"<br/>}</pre> | no |
| inference\_results\_retention\_days | Days the inference-results bucket keeps the uploaded images and predictions under predictions/, and noncurrent object versions, before S3 expires them. | `number` | `30` | no |
| kms\_deletion\_window\_days | Waiting period in days before the project KMS key is deleted (7 to 30). | `number` | `30` | no |
| kms\_key\_administrators | IAM role or user ARNs that administer the project KMS key. Empty keeps the account root as administrator, so the key can never become unmanageable; list existing principals only (the deploy role and a break-glass role). | `list(string)` | `[]` | no |
| log\_group\_names | Log group names for metric filters | `map(string)` | `{}` | no |
| log\_groups | Map of log groups to create | <pre>map(object({<br/>    name = string<br/>  }))</pre> | `{}` | no |
| log\_retention\_days | CloudWatch log retention in days. | `number` | `365` | no |
| metric\_namespaces | Metric namespaces for CloudWatch metrics | `map(string)` | `{}` | no |
| min\_images\_per\_class | Minimum images required per class for the validation step to pass. Lower it for small test datasets. | `number` | `100` | no |
| model\_card\_risk\_rating | Risk rating recorded on the Model Card (Low, Medium, High or Unknown). | `string` | `"High"` | no |
| monthly\_budget\_usd | Monthly spending budget in USD (project-scoped via tag filter). Set to 0 to disable the AWS Budgets resource entirely. | `number` | `200` | no |
| pipeline\_max\_parallel\_steps | Max concurrent steps a pipeline execution can run. Lets the three model trainers run in parallel. | `number` | `4` | no |
| positive\_class | Label folder name of the positive class (the class recall is measured on). Empty means the second class folder in alphabetical order. Passed to the pipeline steps as POSITIVE\_CLASS. | `string` | `""` | no |
| preprocessing\_target\_size | Target square resolution (pixels) the preprocessing job resizes every image to; the trainers downsample to their own input\_size from there. | `number` | `512` | no |
| processed\_data\_retention\_days | Days the processed-data bucket keeps each pipeline execution's validation report and train/validation/test splits (under executions/<execution-id>/) before S3 expires them. | `number` | `30` | no |
| quality\_gate | Defaults of the AccuracyThreshold, RecallThreshold, PrecisionThreshold and AucThreshold pipeline parameters: the bars the ensemble must clear before it is registered. Recall is highest because a missed positive (false negative) is the costly error. The Condition step, the evaluation and ensemble steps (QUALITY\_GATE) and the model package metadata read the parameter values, so a bar can be moved per execution. | <pre>object({<br/>    accuracy  = number<br/>    recall    = number<br/>    precision = number<br/>    auc_roc   = number<br/>  })</pre> | <pre>{<br/>  "accuracy": 0.85,<br/>  "auc_roc": 0.9,<br/>  "precision": 0.8,<br/>  "recall": 0.95<br/>}</pre> | no |
| quarantine\_min\_image\_size\_px | Uploads whose width or height is below this many pixels are quarantined. Matches the validation step's MIN\_RESOLUTION default (112). | `number` | `112` | no |
| quarantine\_prefix | Key prefix in the raw-data bucket that failing uploads are moved to. Must end with / and sit outside training\_data\_path so neither the pipeline trigger nor the preprocessing input reads it. | `string` | `"quarantine/"` | no |
| retraining\_reason | Default of the RetrainingReason pipeline parameter (manual, data\_upload, drift\_detected), recorded on the registered model package. The upload trigger passes data\_upload and the drift alarm passes drift\_detected per execution. | `string` | `"manual"` | no |
| sagemaker\_images | SageMaker container image configurations | <pre>object({<br/>    tensorflow_gpu_tag       = string<br/>    tensorflow_cpu_tag       = string<br/>    tensorflow_inference_tag = string<br/>  })</pre> | <pre>{<br/>  "tensorflow_cpu_tag": "2.19.0-cpu-py312-ubuntu22.04-sagemaker",<br/>  "tensorflow_gpu_tag": "2.19.0-gpu-py312-cu125-ubuntu22.04-sagemaker",<br/>  "tensorflow_inference_tag": "2.20-cpu-py312-amzn2023-sagemaker"<br/>}</pre> | no |
| sbom\_retention\_days | How long SBOM JSON files are kept before S3 expires them. | `number` | `730` | no |
| spot\_max\_wait\_buffer\_seconds | Extra wait time (seconds) SageMaker holds for Spot capacity on top of MaxRuntime | `number` | `1800` | no |
| training\_data\_path | Prefix in the raw-data bucket that holds the images, one folder per label: <prefix><label>/<file>. | `string` | `"images/"` | no |
| training\_input\_mode | SageMaker training input mode | `string` | `"FastFile"` | no |
| training\_keep\_alive\_seconds | KeepAlivePeriodInSeconds for warm pools. Set to 0 to disable. | `number` | `1800` | no |
| training\_vpc\_cidr | IPv4 CIDR of the training VPC (training\_vpc\_enabled). It is split into two private subnets; each job instance takes up to two addresses. | `string` | `"10.42.0.0/24"` | no |
| training\_vpc\_enabled | Run every Processing and Training job of the pipeline in a VPC this stack creates (network.tf): private subnets in two Availability Zones, no internet gateway, no NAT gateway, an S3 gateway endpoint limited to the project buckets, and a security group whose only egress is HTTPS to S3. The processing steps then install their pinned packages from the wheelhouse scripts/script\_uploader.sh uploads. Ignored when vpc\_config is set; false runs the jobs in the SageMaker service network as before. | `bool` | `true` | no |
| training\_vpc\_flow\_logs | Send VPC flow logs (accepted and rejected) of the training VPC to a CloudWatch log group encrypted with the project key, kept for log\_retention\_days. | `bool` | `true` | no |
| training\_vpc\_monitoring\_endpoint | Add a CloudWatch metrics (com.amazonaws.<region>.monitoring) interface endpoint to the training VPC so the scheduled drift and fairness jobs can run in it and still publish their metrics. Interface endpoints are billed per Availability Zone hour (two AZs here). | `bool` | `true` | no |
| upload\_quarantine\_reserved\_concurrency | Reserved concurrency for the upload quarantine Lambda. A full dataset upload sends one event per image; the cap keeps it from using the account's whole Lambda concurrency, and throttled events are retried by Lambda's asynchronous queue. | `number` | `10` | no |
| vpc\_config | Optional VPC of your own for the training and processing jobs; it takes precedence over training\_vpc\_enabled. The subnets need a route to Amazon S3 (gateway endpoint), and the processing steps install their packages from the wheelhouse in the scripts bucket, or from PyPI when it is reachable. | <pre>object({<br/>    subnet_ids         = list(string)<br/>    security_group_ids = list(string)<br/>  })</pre> | `null` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| access\_log\_bucket | Bucket that receives S3 server access logs (null when enable\_s3\_access\_logging = false) |
| auto\_trigger\_eventbridge\_rule | Name of the EventBridge rule for auto-triggering pipeline |
| cloudtrail\_trail\_arn | ARN of the audit trail (null when enable\_cloudtrail = false) |
| endpoint\_name | Name of the SageMaker endpoint |
| inference\_results\_bucket | Name of the inference results S3 bucket |
| job\_vpc\_config | VpcConfig (Subnets, SecurityGroupIds) every pipeline job runs with: the training VPC, or vpc\_config when set. Null when the jobs run without a VPC. |
| kms\_key\_arn | ARN of the KMS key |
| kms\_key\_id | ID of the KMS key |
| mlflow\_tracking\_server\_arn | ARN of the MLflow tracking server. Null when enable\_mlflow = false. |
| mlflow\_tracking\_server\_url | URL of the MLflow tracking server. Null when enable\_mlflow = false. |
| model\_artifacts\_bucket | Name of the model artifacts S3 bucket |
| model\_package\_group\_name | Name of the model package group |
| monitoring\_bucket | Name of the monitoring S3 bucket |
| network\_isolation\_enabled | Whether the training jobs run with network isolation (no outbound network from the training containers). |
| pipeline\_log\_groups | Pipeline step log group names |
| processed\_data\_bucket | Name of the processed data S3 bucket |
| raw\_data\_bucket | Name of the raw data S3 bucket |
| sagemaker\_execution\_role\_arn | ARN of the SageMaker execution role: the pipeline role, and the role of the endpoint model, the scheduled monitoring jobs, the A2I flow and the MLflow tracking server |
| sagemaker\_image\_uris | SageMaker Docker image URIs fetched dynamically from AWS |
| sagemaker\_job\_role\_arn | ARN of the role the pipeline's Processing and Training jobs run with |
| sagemaker\_pipeline\_arn | ARN of the SageMaker pipeline |
| sagemaker\_pipeline\_name | Name of the SageMaker pipeline |
| sbom\_bucket | Name of the SBOM S3 bucket. Null when enable\_sbom\_bucket = false. |
| sbom\_bucket\_arn | ARN of the SBOM S3 bucket. Null when enable\_sbom\_bucket = false. |
| scripts\_bucket | Name of the scripts S3 bucket |
| training\_dashboard\_url | Training monitoring dashboard URL |
| training\_data\_path | Prefix in the raw-data bucket that holds the images (<prefix><label>/<file>) |
| training\_log\_groups | Training metrics log group names |
| training\_vpc\_id | ID of the training VPC (null when training\_vpc\_enabled = false or vpc\_config is set) |
| upload\_quarantine\_function\_name | Lambda that checks each uploaded training image (null when enable\_upload\_quarantine = false) |
| upload\_quarantine\_location | Where failing uploads are moved, with a .reason.json next to each (null when enable\_upload\_quarantine = false) |
<!-- END_TF_DOCS -->

## File Structure

```
stack-training/
|-- auto_trigger.tf           # EventBridge rule, target and role that start the pipeline on upload
|-- backend.tf                # Partial S3 backend (values come from backend.hcl)
|-- backend.hcl.example       # Template for backend.hcl
|-- cloudtrail_budgets.tf     # CloudTrail trail (management and data events) and bucket, AWS Budgets budget
|-- data.tf                   # Caller identity and SageMaker prebuilt image lookups
|-- lambda/upload_quarantine/ # Upload quarantine Lambda source
|-- main.tf                   # KMS, S3 buckets, SageMaker roles, registry, Model Card, MLflow, pipeline
|-- monitor.tf                # CloudWatch log groups, metric filters and training dashboard
|-- network.tf                # Training VPC: private subnets, S3 gateway and CloudWatch metrics endpoints, security groups, flow logs
|-- outputs.tf                # Buckets, pipeline, registry, IAM, KMS, MLflow, SBOM outputs
|-- pipeline.json.tftpl       # SageMaker pipeline definition (rendered by templatefile)
|-- providers.tf              # AWS provider with default_tags
|-- quarantine.tf             # Upload quarantine Lambda, rule, role, layer and DLQ
|-- sbom.tf                   # SBOM bucket for the patched inference image builds
|-- terraform.tfvars          # Values for this environment
|-- terraform.tfvars.example  # Annotated example values
|-- variables.tf              # Input variables
`-- versions.tf               # Terraform and provider version constraints
```
