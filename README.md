# Image Classification MLOps on Amazon SageMaker

> [!WARNING]
> **Disclaimer.** This is sample code for demonstration and learning, not a
> production-ready system. It deploys real, billable AWS resources (an
> always-on Amazon SageMaker AI real-time endpoint, training and processing
> jobs, AWS WAF and more) that cost money for as long as they exist. Review
> [Costs](#costs), [Cleanup](#cleanup) and [SECURITY.md](SECURITY.md) before
> you deploy, and deploy only into a non-production account you control.

## Overview

This sample is an end-to-end MLOps pipeline for binary image classification on
Amazon SageMaker AI, written entirely in Terraform. It works with any labeled
images: put each of the two classes in its own folder, choose which class is
the positive class, and the pipeline trains, gates, deploys and monitors a
classifier for them. The sample ships no data (see
[Datasets and model weights](#datasets-and-model-weights)).

It covers the whole lifecycle:

- event-driven data validation and preprocessing with a group-aware split
  (images of one group never appear in more than one split),
- three convolutional networks (VGG16, DenseNet121, EfficientNetV2-M)
  trained in parallel and combined into an ensemble whose decision threshold
  is tuned on the validation split,
- a quality gate and a Fairlearn fairness gate scored on the test
  split, with a failed gate stopping the pipeline,
- governed deployment: every model registers as `PendingManualApproval`, and a
  person's approval triggers a blue/green endpoint update that sends 10% of
  the new fleet's capacity traffic first (canary) and rolls back
  automatically on the error and latency alarms,
- a public API behind AWS WAF and an API key, with optional Amazon Cognito
  sign-in for application users and optional Amazon Bedrock descriptions
  for low-confidence predictions,
- scheduled drift (PSI) and fairness monitoring that can start retraining.

Everything that persists (endpoint, endpoint configuration, auto-scaling,
alarms, schedules, registry) is a Terraform resource. AWS Lambda functions only
orchestrate: they serve predictions, roll an approved model onto the endpoint,
and refresh the endpoint weekly.

## Table of contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [What each stack deploys](#what-each-stack-deploys)
4. [Repository structure](#repository-structure)
5. [Prerequisites](#prerequisites)
6. [Datasets and model weights](#datasets-and-model-weights)
7. [Deployment](#deployment)
8. [Usage](#usage)
9. [Costs](#costs)
10. [Cleanup](#cleanup)
11. [Troubleshooting](#troubleshooting)
12. [Contributing](#contributing)
13. [Security](#security)
14. [License](#license)

## Architecture

![MLOps architecture: images from an on-premises image source arrive over an encrypted transfer in an Amazon S3 landing zone; Amazon EventBridge sends each image to a validation AWS Lambda function and starts Amazon SageMaker Pipelines, which runs Preprocess, Train three models and Evaluate and ensemble; the result is registered in the SageMaker Model Registry, a review board outside the cloud approves it, and the approved model is canary-deployed to the Amazon SageMaker AI endpoint behind Amazon API Gateway; a drift job reads the endpoint's captured data and sends a drift score to an Amazon CloudWatch alarm, which makes an EventBridge rule start retraining](docs/diagrams/mlops-architecture.svg)

The on-premises image source stands for any upstream system (the sample takes
JPEG or PNG uploads to Amazon S3), the validation Lambda function is the upload
quarantine Lambda, and Amazon Cognito is an optional setting. The figure leaves out two things that
are on by default: the private Amazon VPC the training and monitoring jobs run
in, and the AWS CloudTrail trail.

1. A data batch lands in the image data bucket. When the upload finishes, a
   `.batch_complete` marker object makes an Amazon EventBridge rule start the
   SageMaker pipeline.
2. Amazon SageMaker Pipelines validates, preprocesses, trains, evaluates and gates the
   model in a private VPC with no internet access, writes every artifact under
   a prefix for that execution, and registers a passing ensemble in the
   SageMaker Model Registry as pending.
3. A reviewer approves a version. The approved model is rolled onto the
   SageMaker real-time endpoint.
4. Users open the web UI through Amazon CloudFront (static files in a private
   S3 bucket) and send images to Amazon API Gateway through AWS WAF with an
   API key. An AWS Lambda function calls the endpoint and, for low-confidence
   results, optionally asks Amazon Bedrock for a guarded explanation.
5. The endpoint captures its responses to S3. Amazon EventBridge Scheduler runs a
   drift job every hour and a fairness job every day; both publish metrics to
   Amazon CloudWatch, whose alarms notify Amazon SNS and can start a retraining
   run.
6. The optional CI/CD stack deploys the same stacks with AWS CodePipeline and
   AWS CodeBuild, and a CodeBuild project rebuilds the patched inference image
   in Amazon ECR every month.
7. Across all stacks, customer managed AWS Key Management Service (AWS KMS)
   keys encrypt data at rest, AWS Identity and Access Management (IAM) roles
   are scoped to the project and bounded by a permissions boundary, and
   an AWS CloudTrail trail (on by default) records management events plus data
   events on the project buckets and Lambda functions.

The diagrams are SVG files in [docs/diagrams/](docs/diagrams/); PNG exports
of the same figures are in [docs/diagrams/png/](docs/diagrams/png/).

## What each stack deploys

The sample is four Terraform root modules (stacks) plus reusable modules in
`modules/`. They are applied in this order:

| Order | Stack | Purpose |
| --- | --- | --- |
| 1 | [stack-backend-setup](stack-backend-setup/README.md) | Bootstrap with local state: S3 state bucket, state KMS key, workload permissions boundary |
| 2 | [stack-training](stack-training/README.md) | Data and model buckets, private job VPC, SageMaker pipeline, Model Registry, Model Card, budget, CloudTrail trail, optional MLflow |
| 3 | [stack-inference](stack-inference/README.md) | Endpoint, API, web UI, auto-deploy, drift and fairness monitoring, Bedrock guardrail |
| 4 (optional) | [stack-cicd](stack-cicd/README.md) | CodePipeline and CodeBuild that apply stacks 2 and 3 from your GitHub repository |

### stack-backend-setup

Creates the versioned, KMS-encrypted Terraform state bucket (S3 native state
locking, no Amazon DynamoDB table), its KMS key, and the `<project_name>-workload-boundary`
IAM permissions boundary that every role in the other stacks carries. It keeps
its own state locally and prints the `backend.hcl` the other stacks use.

### stack-training

Creates a project KMS key, six S3 buckets (raw data, processed data, scripts,
model artifacts, inference results, monitoring) plus an SBOM bucket by default,
the SageMaker execution role, the Model Package Group, a Model Card, an AWS
Budgets budget, CloudWatch dashboards, the upload quarantine Lambda, and the
SageMaker pipeline with its EventBridge trigger. Two settings are on by default:

- a private VPC (`training_vpc_enabled`) for every pipeline Processing and
  Training job and the scheduled drift and fairness jobs: two private subnets,
  no internet or NAT gateway, an S3 gateway endpoint limited to the project
  buckets, a CloudWatch metrics interface endpoint
  (`training_vpc_monitoring_endpoint`) and VPC flow logs
  (`training_vpc_flow_logs`). The processing steps install their packages from
  wheelhouses that `make upload-scripts` uploads to the scripts bucket.
  `vpc_config` runs the jobs in subnets of your own instead
  ([Training VPC](stack-training/README.md#training-vpc));
- a multi-region CloudTrail trail (`enable_cloudtrail`) with management events
  and data events on the project buckets and Lambda functions. Turn it off
  where an organization trail already records the account
  ([Audit trail](stack-training/README.md#audit-trail)).

A managed MLflow tracking server (`enable_mlflow`) is available but off by
default.

![Training pipeline: in the raw data Amazon S3 bucket, a separate Amazon EventBridge rule sends each upload to a quarantine AWS Lambda function that moves bad images to a quarantine prefix, and an upload marker starts Amazon SageMaker Pipelines, which validates, preprocesses into the processed data bucket, trains three models in parallel, evaluates, builds an ensemble, runs a fairness check and, through one condition step, either registers the model as needing approval or fails; step code comes from the scripts bucket and outputs go to the model artifacts bucket](docs/diagrams/mlops-training-pipeline.svg)

1. As each image lands under the `training_data_path` prefix, the upload quarantine
   Lambda (`enable_upload_quarantine`, on by default) checks it: an allowed
   extension (`.jpg`, `.jpeg`, `.png`), opens with Pillow as that format, and
   at least 112 px on each side (`quarantine_min_image_size_px`). A file that
   fails is moved to `quarantine/<original key>` with a
   `<original key>.reason.json` next to it, and the
   `<project_name>/DataQuality` `QuarantinedImages` metric counts it. The
   quarantine prefix is outside the prefix the pipeline reads.
2. Uploading the `.batch_complete` marker to the data bucket fires the
   EventBridge rule, which starts an execution with
   `RetrainingReason=data_upload`.
3. **Validate data** (Processing job) finds the two class folders, checks
   image format, resolution, class balance and quality, and checks
   `manifest.csv` when there is one. Images that fail the quality check are
   listed with their reason in `exclusion_manifest.json` and kept out of
   training.
4. **Preprocess** resizes images to 512 x 512 and writes train, validation and
   test splits grouped by group id, so images of one group never appear in
   more than one split, plus `classes.json` and `manifest.csv` in each split.
   It runs on `pipeline_steps.preprocessing.instance_count` instances (2 in
   the shipped tfvars), each handling a share of the images
   (`ShardedByS3Key`); every instance computes the same split. The
   validation report and the splits go to `executions/<pipeline-execution-id>/`
   in the processed data bucket and expire after
   `processed_data_retention_days` (30).
5. **Train** VGG16, DenseNet121 and EfficientNetV2-M in parallel training
   jobs. By default every model starts from random initialisation and trains
   in one phase with every layer trainable; with your own backbone weights
   (`backbone_weights_s3_uri`, see
   [Datasets and model weights](#datasets-and-model-weights)) the trainers load
   them and fine-tune in two phases instead. Training images get flips, small
   shifts, rotations, brightness changes and a colour/intensity jitter (a
   random per-channel scale and offset on the RGB image, `color_jitter_sigma`
   in `scripts/training/training_config.py`, 0 turns it off); validation and
   test images are left as they are. Training jobs run with network isolation
   by default.
6. **Evaluate** tunes each model's threshold on the validation split and
   reports its metrics on the test split.
7. **Ensemble** combines the three models, tunes the ensemble threshold on the
   validation split and scores the test split at that threshold.
8. **Fairness check** runs Fairlearn over the ensemble's own test predictions
   at its tuned threshold, per subgroup of the `fairness_gate.sensitive_feature`
   attribute (default `subgroup`, from the file name or `manifest.csv`). It
   reports demographic parity, equalized odds and equal opportunity; the gate
   uses the larger of the first two. When no image carries that attribute the
   check is skipped (status `skipped`, logged) and passes.
9. **Condition** requires accuracy >= 0.85, recall >= 0.95 (recall of the
   positive class), precision >= 0.80, AUC >= 0.90 and a fairness disparity
   <= 0.10. If every check passes, the
   ensemble is registered as `PendingManualApproval`; otherwise the execution
   ends in a Fail step and nothing is registered. The four quality bars are
   pipeline parameters (`AccuracyThreshold`, `RecallThreshold`,
   `PrecisionThreshold`, `AucThreshold`) whose defaults come from
   `quality_gate`, so one execution can use other bars without a code
   change:

   ```bash
   aws sagemaker start-pipeline-execution \
     --pipeline-name "$(terraform -chdir=stack-training output -raw sagemaker_pipeline_name)" \
     --pipeline-parameters Name=RecallThreshold,Value=0.97
   ```

10. Evaluation, ensemble and fairness outputs are written under
    `<prefix>/<pipeline-execution-id>/`, so each model package points at its
    own weights and reports, and approving an older version deploys that
    version.
11. One optional step is off by default: a small CNN trained from scratch as
    a baseline for the three ensemble members (`baseline_cnn`, never
    registered).

### stack-inference

Creates the patched inference image (built once at apply time, then weekly;
the weekly endpoint refresher repins the endpoint to the newest build),
the SageMaker model, endpoint configuration and endpoint (Terraform-managed,
with blue/green canary deployment, auto-rollback alarms and auto-scaling), the
inference Lambda and its Pillow/NumPy layer, the API Gateway REST API with a
usage plan, API key and WAF web ACL, the CloudFront web UI, the auto-deploy
Lambda, the drift and fairness schedules and alarms, the retraining rule, SNS
alerts, a CloudWatch dashboard, a weekly endpoint refresh, the Bedrock
guardrail when hybrid inference is on, and an Amazon Cognito user pool with a
Cognito authorizer on the API when `api_authorization_type =
"COGNITO_USER_POOLS"`.

![Inference and monitoring: the browser loads the web UI from Amazon CloudFront and its Amazon S3 bucket, and posts images through AWS WAF to Amazon API Gateway with an API key; an AWS Lambda function invokes the Amazon SageMaker AI endpoint and, optionally, Amazon Bedrock with a guardrail for low-confidence cases; captured data in S3 feeds drift and fairness Processing jobs started by Amazon EventBridge Scheduler, which publish metrics to Amazon CloudWatch alarms that notify Amazon SNS; an approved model in the Model Registry (through an EventBridge rule and an auto-deploy Lambda) and a weekly refresher Lambda both update the endpoint as a canary, and the CloudWatch alarms roll it back](docs/diagrams/mlops-inference-monitoring.svg)

1. The browser loads the static web UI from CloudFront, which reads it from a
   private S3 bucket.
2. The browser posts the image directly to API Gateway, sending the API key in
   the `x-api-key` header. AWS WAF inspects the request first.
3. API Gateway invokes the inference Lambda, which validates and preprocesses
   the image and calls the endpoint with its request id as `InferenceId`.
4. When hybrid inference is on and the confidence is below the cutoff, the
   Lambda asks Amazon Bedrock to describe the image and the model's predicted
   class, filtered by a Bedrock guardrail. Without a configured guardrail the
   Lambda makes no Bedrock call.
5. The endpoint writes data capture to the monitoring bucket (model output by
   default; request payloads too when `data_capture_input = true`).
6. EventBridge Scheduler starts the PSI drift job hourly and the Fairlearn job
   daily. They read captured predictions, and the fairness job joins them with
   the ground-truth labels you upload to the `ground-truth/` prefix.
7. Both jobs publish metrics to CloudWatch, and CloudWatch alarms notify the
   SNS alerts topic.

### stack-cicd

Optional. Creates a CodePipeline with five stages (Source, Training-Deploy,
BaselineModelCreation, Script-Upload, Inference-Deploy with an optional manual
approval), four CodeBuild projects, an artifacts bucket, an SNS topic for
approvals and an AWS CodeConnections connection to your GitHub repository. See
[Deploy through CI/CD](#deploy-through-cicd).

## Repository structure

```
.
|-- stack-backend-setup/   # State bucket, state KMS key, permissions boundary (local state)
|-- stack-training/        # Buckets, upload quarantine, SageMaker pipeline, registry, Model Card, budget
|-- stack-inference/       # Endpoint, Lambda, API Gateway, WAF, CloudFront, monitoring
|-- stack-cicd/            # Optional CodePipeline and CodeBuild
|-- modules/               # Reusable Terraform modules (terraform-aws-*)
|-- scripts/               # Code the pipeline and scheduled jobs run, plus mlops_common
|-- ops-scripts/           # Local helpers: layer build, API test, monitoring check, cleanup
|-- tests/                 # pytest suite
|-- docs/diagrams/         # Architecture figures (SVG, PNG exports in png/)
|-- .github/workflows/     # GitHub Actions CI (static checks)
|-- Makefile               # Deploy, destroy and local check targets
`-- pyproject.toml         # Ruff, pytest and dev dependency group
```

## Prerequisites

**AWS account**

- An AWS account you can deploy to, with credentials that can create IAM
  roles, KMS keys, S3 buckets, SageMaker, Lambda, API Gateway, WAF, CloudFront
  and CodeBuild resources. Use a dedicated non-production account.
- Deploy in one Region (the stacks default to `us-east-1`).

**Service quotas**

- SageMaker training: the shipped `stack-training/terraform.tfvars` trains on
  `ml.c5.2xlarge` (CPU). To train on GPU (`ml.g*` or `ml.p*`, which selects the
  GPU image automatically), request the matching "for training job usage"
  quota in Service Quotas first; new accounts often have 0.
- SageMaker Processing: `ml.m5.4xlarge` (two at once for preprocessing),
  `ml.m5.large` and `ml.t3.medium` for processing job usage.
- SageMaker hosting: two `ml.m5.xlarge` for endpoint usage (up to three with
  the default auto-scaling maximum), plus room for the second fleet during a
  blue/green update: a rollout runs the old and new fleets side by side, so
  allow at least five.

**Amazon Bedrock**

- Hybrid inference is off in the module default but on in the shipped
  `stack-inference/terraform.tfvars` (`enable_bedrock_hybrid_inference = true`).
  When it is on, the model in `bedrock_model_id` (default
  `us.amazon.nova-pro-v1:0`, a cross-Region inference profile) must be
  available to the account, and the stack creates the Bedrock guardrail the
  Lambda requires (with no guardrail it skips Bedrock). Set it to `false` if
  you do not want Bedrock.

**Tools**

| Tool | Version | Used for |
| --- | --- | --- |
| Terraform | `~> 1.15` (every stack's `versions.tf`) | All stacks |
| AWS CLI | v2 | `local-exec` build of the patched image, approvals, cleanup |
| Python | 3.13 or later (`pyproject.toml`) | Helper scripts and tests |
| uv or pip | uv recommended | Building the Lambda layer, installing tools |
| make, bash, zip | any recent | Makefile targets, layer build |

`make seed-baseline` builds a Keras model locally, so the Python that
`python3` resolves to needs `boto3` and `tensorflow==2.19.0` (the version the
endpoint serves). A virtual environment
is the simplest way to keep that separate. `ops-scripts/test_api.py` needs
`requests` and `Pillow`. For the local checks you also need `ruff`, `pytest`
and `checkov` (`pip install --group dev` installs ruff and pytest).
`make upload-scripts` (also run by `make seed-baseline`) downloads the
processing steps' packages as wheels with `pip`, because the jobs have no route
to PyPI, so the machine that runs it needs PyPI access.

## Datasets and model weights

The sample ships no datasets and no model weights, and downloads neither.
During development the pipeline was tested on a public image dataset, which
the sample does not distribute. You are responsible for the licenses and
terms of use of any data and any weights you bring.

**Data.** Bring your own labeled JPEG or PNG images and upload them in this
layout (`scripts/data_uploader.sh` does it for you, see
[Quick start](#quick-start) step 8):

```
s3://<raw-data-bucket>/images/
|-- <class_a>/<group>__<name>.jpg
|-- <class_b>/<group>__<name>.png
`-- manifest.csv              (optional)
```

- `images/` is the default `training_data_path` in `stack-training`.
- Exactly two class folders, with any names. The folder name is the label.
- The positive class is the class that recall, the decision threshold and the
  endpoint's probability refer to. Set it with `positive_class` in
  `stack-training` (environment variable `POSITIVE_CLASS` in the pipeline);
  by default it is the second class folder in alphabetical order. Label 1 is
  the positive class, label 0 the other one.
- Group id. Images from one source (the same subject, session, device or
  scene) are near duplicates; if some land in training and others in test,
  the test metrics look better than the model is. Give each image a group id
  and preprocessing keeps every group in one split (train, validation and
  test, about 70/15/15 by group). An image without one is its own group, and
  the step logs a warning.
- File names carry the group id, and optionally a subgroup, as prefixes:
  `<group>__<name>.<ext>` (`g01__img_0001.jpg` is in group `g01`) or
  `<group>__<subgroup>__<name>.<ext>` (`g01__site-a__img_0001.jpg` is in group
  `g01`, subgroup `site-a`). A subgroup is an attribute such as a capture
  setting (a camera, site or zoom level) that the fairness gate compares.
- `manifest.csv` (optional) has the columns `file,label,group` plus any
  attribute columns, and overrides the file name: its `group` column sets the
  group id and an attribute column named `subgroup` sets the subgroup. `file`
  is relative to the data root (`<class>/<name>`), `label` is the class folder
  name (validation fails when it does not match the folder), and `group` may
  be empty. The fairness gate groups by `fairness_gate.sensitive_feature`
  (default `subgroup`); when no image carries it, the check is skipped.

```csv
file,label,group,subgroup
class_a/img_0001.jpg,class_a,g01,site-1
class_b/img_0002.png,class_b,g02,site-2
```

Preprocessing writes `classes.json` (the two class names and the positive
class) and the split's `manifest.csv` into each of train, validation and
test; the later steps and the endpoint read the class names from there.

**Model weights (optional).** The architectures are built in Keras code
without weights, so by default every model trains from random
initialisation. To start from your own backbone weights, set
`backbone_weights_s3_uri` in `stack-training` to an S3 prefix that holds
one `<model>.weights.h5` per model (`vgg16`, `densenet121`, `efficientnet`,
`simple_cnn`), or a single `.h5` file. The pipeline passes it to the
training jobs as a `weights` input channel (environment variable
`BACKBONE_WEIGHTS_S3_URI`), which also works with network isolation. Files
for VGG16, DenseNet121 and EfficientNetV2-M are Keras weights for the
architecture without its classification top (`include_top=False`); the
`simple_cnn` file holds the whole model. A trainer fails with a clear error
when the URI is set but its file is missing or ambiguous. The training jobs
may read every object under that URI, and `boundary_extra_s3_arns` in
`stack-backend-setup` must admit the bucket ARN and
`arn:aws:s3:::<bucket>/<key>*`.

## Deployment

Deploy the stacks in this order. `stack-backend-setup` comes first: it
creates the Terraform state bucket and the permissions boundary the other
stacks use. `stack-training` comes next. `stack-inference` reads
`stack-training` state and needs an Approved model package in the group,
because the endpoint cannot exist without one; the Quick start registers a
placeholder baseline for that and has you approve it. `stack-cicd` is
optional and deploys the same stacks from your GitHub repository.

### Settings you are most likely to change

Each stack's README lists every variable with its default. These are the ones
that shape a first deployment or harden it:

| Variable | Stack | Default | What it does |
| --- | --- | --- | --- |
| `positive_class` | `stack-training` | empty | The class folder of the positive class; when empty, the second folder in alphabetical order |
| `backbone_weights_s3_uri` | `stack-training` | empty | S3 location of your own backbone weights; empty trains every model from random initialisation |
| `quality_gate` | `stack-training` | accuracy 0.85, recall 0.95, precision 0.80, AUC 0.90 | Defaults of the pipeline's gate parameters |
| `inference_results_retention_days` | `stack-training` | 30 | Days before stored predictions and uploaded images (and their noncurrent versions) expire |
| `audit_bucket_force_destroy` | `stack-training` | `false` | Lets `terraform destroy` delete the CloudTrail and access-log buckets |
| `enable_s3_access_logging` | `stack-training` | `true` | S3 server access logs for the project buckets and the web UI bucket |
| `access_log_retention_days` | `stack-training` | 365 | Days the access-log bucket keeps the logs |
| `kms_key_administrators` | `stack-training` | empty | Roles that administer the project key; empty keeps the account root |
| `kms_deletion_window_days` | `stack-training` | 30 | Waiting period before a deleted key is removed |
| `debugger_rule_image` | `stack-training` | none | Rule image for Amazon SageMaker Debugger; required, with a version tag, when `enable_debugger` is on. Debugger is no longer open to new customers, so this only works for customers that already use it |
| `log_retention_days` | `stack-training`, `stack-inference` | 365 | Days CloudWatch log groups keep their events |
| `endpoint_network_isolation` | `stack-inference` | `true` | Runs the serving model without outbound network access |
| `patched_image_scan_block_severity` | `stack-inference` | `CRITICAL` | Scan gate: a patched image with an Amazon ECR finding at or above this severity is deleted and its build fails; `NONE` turns the gate off |
| `bedrock_guardrail_image_filters` | `stack-inference` | `true` | Applies the guardrail's content filters to the uploaded image as well as the text |
| `boundary_extra_s3_arns` | `stack-backend-setup` | empty | Extra bucket and object ARNs the permissions boundary admits, for example your backbone weights bucket and `<bucket>/<prefix>*` |
| `workload_project_name` | `stack-backend-setup` | empty | Project prefix the boundary admits; empty uses `project_name` |

### Quick start

Run everything from the repository root. The Makefile honours
`PROFILE=<name>` (or an exported `AWS_PROFILE`); every deploy target runs
`terraform plan -out` and applies the saved plan.

**0. Configure.** Review `stack-training/terraform.tfvars` and
`stack-inference/terraform.tfvars`: `project_name`, `environment`,
`aws_region`, `budget_alert_emails`, `alert_email`, instance types and the
Bedrock toggle. `training_data_path` (default `images/`) must match the
prefix `scripts/data_uploader.sh` writes to (`--prefix`, default `images`).
Set `positive_class` to the class folder
that is the positive class (default: the second folder in alphabetical order).

```bash
export AWS_PROFILE=<your-profile>
aws sts get-caller-identity
```

**1. Bootstrap the state backend.**

```bash
make bootstrap
```

**2. Write `backend.hcl` for the other stacks.**

```bash
make backend-config
```

**3. Build the Lambda layer.** Optional: `stack-inference` builds the zip at
apply time when it is missing.

```bash
make layer
```

**4. Deploy the training stack.**

```bash
make deploy-training
```

**5. Upload the scripts and seed the baseline model.**

```bash
make seed-baseline
```

The endpoint cannot exist without an approved model, so this registers a
placeholder baseline (a toy network that cannot classify images) as
`PendingManualApproval` and prints its ARN. It does nothing when the group
already holds an approved or pending package.

**6. Approve the baseline.** Nothing is approved automatically; this is a
deliberate manual step.

```bash
GROUP=$(terraform -chdir=stack-training output -raw model_package_group_name)
ARN=$(aws sagemaker list-model-packages --model-package-group-name "$GROUP" \
  --sort-by CreationTime --sort-order Descending --max-results 1 \
  --query 'ModelPackageSummaryList[0].ModelPackageArn' --output text)
aws sagemaker update-model-package --model-package-arn "$ARN" \
  --model-approval-status Approved \
  --approval-description "Placeholder for first endpoint deploy"
```

**7. Deploy the inference stack.** The target looks up the newest Approved
package in the group, the same query the CI/CD Inference-Deploy stage runs;
set `TF_VAR_model_package_arn` to pin a different version.

```bash
make deploy-inference
```

The first apply also builds the patched inference image in CodeBuild and waits
for it, which takes several minutes.

`make deploy-all` runs steps 1 to 5 and 7 in order. It cannot approve the
baseline for you, so on a first run it stops before the inference stack with
`No Approved model package in <group>`; approve the baseline (step 6) and run
`make deploy-inference`.

**8. Train on your own data.** Arrange your labeled images as described in
[Datasets and model weights](#datasets-and-model-weights), one folder per
class with an optional `manifest.csv`, and upload them. The uploader copies
every `<folder>/<class>/<image>` and `manifest.csv` to
`s3://<raw-data-bucket>/images/` (`--prefix` changes it), then writes the
`.batch_complete` marker that starts the pipeline.

```bash
./scripts/data_uploader.sh data/my-images
```

Run `./scripts/data_uploader.sh --help` for `--prefix`, `--append`, `--count`
and `--no-dvc`.

The upload quarantine Lambda checks every file as it lands and moves bad ones
to `quarantine/` in the raw data bucket, each with a `.reason.json`
([stack-training README](stack-training/README.md#upload-quarantine)). The
pipeline's validation step checks the images again, so a file the Lambda has
not reached when the marker starts the run still fails validation.

The gates are strict on purpose. With few groups, the group-aware test split
holds only a handful of them, and one group the models get wrong moves recall
or precision by several points, so a small dataset often ends at the Fail step
and registers nothing. A model that clears the gates needs more data (more
groups) or a stronger model, not lower thresholds.

When the execution registers a version, check its metrics in the registry and
approve it with the same `update-model-package` command. The approval event
triggers the auto-deploy Lambda, which rolls the new version onto the endpoint
with a blue/green canary update.

### Deploy through CI/CD

![CI/CD deployment: a push to GitHub starts AWS CodePipeline through an AWS CodeConnections source connection, with source artifacts in an Amazon S3 bucket; AWS CodeBuild stages deploy training, register the baseline in the Model Registry, upload scripts to the scripts bucket, and, after a manual approval in the inference deploy stage, deploy inference, with Terraform state for both deploys in the AWS KMS encrypted state bucket](docs/diagrams/mlops-cicd.svg)

1. A push to the tracked branch of your GitHub repository starts the pipeline
   through AWS CodeConnections.
2. **Training-Deploy** installs a pinned Terraform release, verifies it against
   HashiCorp's `SHA256SUMS`, and applies `stack-training` from a saved plan.
3. **BaselineModelCreation** registers the placeholder baseline as
   `PendingManualApproval` on the first run and prints its ARN in the build log.
4. **Script-Upload** uploads the pipeline scripts and the processing steps'
   wheelhouses to the scripts bucket.
5. **Inference-Deploy** waits for the manual approval action
   (`require_manual_approval`, default `true`), then builds the Lambda layer and
   applies `stack-inference` with the newest Approved package in the group. It
   fails if no package is approved yet.
6. Both Terraform stages keep their state in the KMS-encrypted state bucket
   created by `stack-backend-setup`.

Every push to `github_branch` applies `stack-training` with the CI/CD role, so
protect that branch before you connect the pipeline (see
[Protect the release branch](stack-cicd/README.md#protect-the-release-branch)).

Upgrading an existing deployment: run `make bootstrap` before
`make deploy-cicd`, because the state key policy now admits CloudWatch Logs for
the CodeBuild log groups, then import the log groups CodeBuild already created
(commands in [stack-cicd/README.md](stack-cicd/README.md)). On an existing
training deployment the pipeline steps move to the new job role on the next
`make deploy-training`, and model packages registered from then on name the
TensorFlow 2.20 Amazon Linux 2023 serving image.

Steps:

1. Push this repository to a GitHub repository you own.
2. Run `make bootstrap` and `make backend-config` (the pipeline uses the same
   state bucket).
3. In `stack-cicd/terraform.tfvars`, set `github_owner`, `github_repo`,
   `github_branch` and `state_bucket_name` (printed by `make backend-config`).
   They have no usable defaults and the placeholders are rejected.
4. Run `make deploy-cicd`.
5. Complete the CodeConnections handshake once: in the console open
   Developer Tools > Settings > Connections, select `<project_name>-github`,
   choose **Update pending connection**, and install the AWS Connector for
   GitHub app on the account that owns your repository. Check that
   `terraform -chdir=stack-cicd output github_connection_status` shows
   `AVAILABLE`.
6. Run the pipeline: choose **Release change** in CodePipeline or push to the
   tracked branch.
7. On the first run, approve the baseline package (ARN in the
   BaselineModelCreation log, command as in Quick start step 6) before you
   approve the pipeline's manual approval action.

Subscribers in `approval_notification_emails` must confirm the SNS
subscription before they get approval notices.

## Usage

### Call the API

The API requires an API key in the `x-api-key` header. Terraform outputs the
URL and the key:

```bash
API_URL=$(terraform -chdir=stack-inference output -raw api_gateway_url)
API_KEY=$(terraform -chdir=stack-inference output -raw api_key_value)
python3 ops-scripts/test_api.py --api-url "$API_URL" --api-key "$API_KEY" \
  --image-path data/my-images/<class>/<file>.png
```

Without `--image-path` the script samples `--count` images per class from
`--data-path` (default `data/`) and checks each prediction against the folder
label. When `--api-url` and `--api-key` are not given it reads the
`API_URL` and `API_KEY` environment variables.

The API has two routes:

- `POST /predict` with a JSON body `{"image": "<base64 image>"}`. The response
  carries `request_id`, `prediction`, `confidence`, `probabilities`,
  `threshold_used`, `routing` and, when hybrid inference answers, `reasoning`.
  `prediction` is a class name and `probabilities` maps both class names to
  their probability. The response does not include where the image is stored.
  The image must be JPEG or PNG; images larger than `max_image_bytes` (5 MB by
  default) return HTTP 413.
- `GET /results/{request_id}` returns the stored prediction for that request.

To have Amazon Cognito authenticate application users before they
can invoke the endpoint, set `api_authorization_type = "COGNITO_USER_POOLS"`
in `stack-inference`. The stack then creates a user pool and app client, and
API Gateway rejects any request without a valid ID token in the
`Authorization` header (HTTP 401) before the Lambda runs; the API key and WAF
still apply. The default stays `NONE` (API key only) because the static web
UI has no sign-in flow yet. How to create a user and call the API with a
token: [stack-inference/README.md](stack-inference/README.md#cognito-mode).

#### Explanations in the response

Add `"explain": true` to the `POST /predict` body to get per-image
explanations with the prediction (`--explain` in `test_api.py`). They are off
unless asked for, so a request without the field gets the same response, at
the same latency, as before. `{"explain": {"methods": ["gradcam"]}}` asks for
one method only (`gradcam` or `region_shapley`).

```json
{
  "request_id": "3f1c2a9e-5b7d-4e2a-9c1f-0a1b2c3d4e5f",
  "prediction": "class_b",
  "confidence": 0.91,
  "probabilities": {"class_a": 0.09, "class_b": 0.91},
  "threshold_used": 0.42,
  "model_info": "Image analysis using ensemble model",
  "routing": "high-confidence-custom",
  "attention_on_border": false,
  "border_attention_fraction": 0.1834,
  "explanations": {
    "gradcam": {
      "method": "grad-cam",
      "target": "class_b",
      "layer": "feature map feeding global average pooling (last convolutional block)",
      "combination": "ensemble-weighted average of per-model maps, each scaled to max 1",
      "grid_size": 14,
      "grid": [[0.021, 0.054, 0.112]],
      "top_region": {"box": [0.2857, 0.1429, 0.6429, 0.5], "peak_cell": [4, 6], "cells": 19},
      "elapsed_ms": 310
    },
    "region_shapley": {
      "method": "region Shapley values estimated by antithetic permutation sampling",
      "target": "positive class probability",
      "grid_size": 4,
      "values": [[0.012, -0.003, 0.041, 0.0]],
      "baseline": "per-channel mean colour (0 after normalisation)",
      "baseline_score": 0.3712,
      "full_score": 0.91,
      "sum": 0.5388,
      "permutations": 2,
      "evaluations": 32,
      "seed": 0,
      "elapsed_ms": 4100
    },
    "explain_ms": 4420
  }
}
```

In this example `class_b` is the positive class. `grid` (14 x 14) and
`values` (4 x 4) are cut to their first row here. The
whole `explanations` object is under 3 KB. How they are computed, on the
endpoint, for the ensemble that made the call:

- **Grad-CAM** for the predicted class. Each member model's SavedModel carries
  a `gradcam` signature: activations are the feature map that feeds its global
  average pooling layer (the last convolutional block), gradients are of the
  positive-class logit (negated for a negative-class call), and the map is resized to
  14 x 14. The handler scales each member's map to a maximum of 1 and averages
  them with the ensemble weights. `top_region.box` is `[x_min, y_min, x_max,
  y_max]` as fractions of the image, around the connected cells at 50% of the
  peak or more.
- **Region Shapley values**, estimated by sampling. The image is split into a
  4 x 4 grid; a region left out is set to the per-channel mean colour that the
  fixed per-channel mean/std normalisation maps to 0. The value
  of a region is its average marginal effect on the ensemble's positive-class
  probability over random orderings of the regions, drawn in antithetic
  pairs with a fixed seed. The values always sum to `full_score -
  baseline_score`. This is not the `shap` library, and 32 evaluations of 16
  regions is a coarse estimate, not an exact Shapley value.
- **Border check** on the Grad-CAM map. The inference Lambda adds
  `border_attention_fraction`, the share of the heatmap's mass in the outer
  band of the image (`gradcam_border_band`, 10 percent of each side by
  default, which on the 14 x 14 grid is the outermost ring of cells), and
  flags the prediction with `"attention_on_border": true` when that share is
  above `gradcam_border_threshold` (default 0.5). A model that looks at image
  edges, capture artefacts or padding instead of the subject has learned a
  shortcut; treat a flagged prediction like a low-confidence one. Both fields
  are present only when a Grad-CAM grid came back.

Each explained request costs up to `explanation_max_evaluations` (default 32)
masked-image passes through every member model, within
`explanation_time_budget_ms` (default 5000). When time runs short, fewer
permutations run and `permutations` says how many. Set
`enable_request_explanations = false` to turn the option off. A model package
trained before this feature reports `"status": "unavailable"`; retrain to get
the signatures.

The web UI is at `terraform -chdir=stack-inference output -raw
frontend_cloudfront_url`. It carries the same API key, so the key identifies
and meters callers; it does not authenticate them (see [SECURITY.md](SECURITY.md)).

### Monitoring and retraining

![Closed-loop monitoring and retraining: in the Detect group the Amazon SageMaker AI endpoint captures data to Amazon S3 and a drift job, started by Amazon EventBridge Scheduler, sends a PSI metric to an Amazon CloudWatch alarm; in the Respond group the alarm makes an Amazon EventBridge rule start Amazon SageMaker Pipelines, which registers a candidate in the Model Registry as pending approval; a review board approves it, and an auto-deploy AWS Lambda function canary-deploys the approved model back to the endpoint](docs/diagrams/mlops-retraining-loop.svg)

The figure shows only the drift alarm; the fairness alarm starts retraining
the same way.

1. A drift or fairness alarm in CloudWatch changes state to ALARM.
2. An EventBridge rule starts the SageMaker pipeline with
   `RetrainingReason=drift_detected`.
3. A version that clears the gates is registered as `PendingManualApproval`
   and waits for a reviewer.
4. The reviewer approves the package in the Model Registry.
5. The approval state change triggers an EventBridge rule that invokes the
   auto-deploy Lambda.
6. The Lambda creates a model and endpoint configuration for the approved
   package and updates the endpoint with the stack's deployment policy.
   SageMaker starts a new (green) fleet and, by default, routes 10% of its
   capacity (`canary_size_percent`, rounded up to one of the two instances)
   to it for `traffic_shift_wait_interval` seconds (300). If neither the
   error alarm (5XX or model errors) nor the latency alarm fires, the rest
   of the traffic shifts, the old fleet is kept for
   `termination_wait_seconds` (120) more and then terminated. An alarm at any
   point rolls all traffic back to the old fleet. The weekly endpoint refresh
   uses the same policy. `traffic_routing_type` selects `CANARY` (default),
   `LINEAR` (`linear_step_percent` per step) or `ALL_AT_ONCE`; canary and
   linear need at least two instances (`endpoint_initial_instance_count` and
   `endpoint_min_capacity`, both 2 by default), and serverless endpoints
   always shift all at once.
7. Failed asynchronous invocations of the Lambda go to an Amazon SQS
   dead-letter queue, and a queue-depth alarm notifies the SNS alerts topic.

What the monitors measure:

- **Drift** (`scripts/drift/compute_drift.py`, hourly): the Population
  Stability Index of the endpoint's positive-class probability scores over the last
  24 hours against a baseline score distribution. The alarm threshold is
  `drift_threshold` (0.2 by default, 0.1 in the shipped tfvars). It publishes
  nothing with fewer than 30 captured predictions or without a baseline. The
  auto-deploy Lambda writes the baseline after each rollout: it copies the
  deployed package's test scores (`predictions.json` next to its
  `model.tar.gz`) to
  `s3://<monitoring-bucket>/monitoring/baselines/output-only/statistics.json`.
  The placeholder baseline has no test scores, so drift is reported only once a
  trained model has been approved and rolled out.
- **Fairness** (`scripts/fairness/compute_fairness.py`, daily): joins captured
  predictions with ground-truth labels uploaded as JSON Lines
  (`{"request_id": ..., "label": 0|1, "group": "<subgroup>"}`) to the
  `ground-truth/` prefix of the monitoring bucket, and publishes the larger of
  the demographic-parity and equalized-odds differences (its
  `fairness_metrics.json` also carries the equal-opportunity difference). The
  sample does not populate that prefix; until someone does, the job publishes
  no metric.
- **Operations**: API Gateway 4XX/5XX, endpoint errors and latency alarms, a
  composite health alarm, and a CloudWatch dashboard. Set `alert_email` to get
  the SNS notifications. The inference Lambda publishes per-prediction metrics
  to `<project_name>/ModelPerformance` (`PositivePredictions` and
  `NegativePredictions` by predicted class, plus confidence counts), and
  preprocessing logs the split sizes per class (`TrainingPositiveCount`,
  `TrainingNegativeCount` and the same for `Validation` and `Test`).

`ops-scripts/ops_generate_endpoint_traffic.py --data-path <dataset root with
one folder per class>` sends labelled images straight to the endpoint
(default `image-classification-endpoint`) to seed data capture before real
traffic exists, and
`ops-scripts/verify_monitoring.sh` checks that the alarms, topics and rules
exist. For a test deployment, `test_traffic_enabled = true` in
`stack-inference` (off by default, needs `test_traffic_end_date`) sends a few
random images (`.jpg`, `.jpeg` or `.png` under `training_data_path`, any class
folder) from the raw data bucket to the inference function once an hour, at a random time
within the hour, until that date
([Test traffic](stack-inference/README.md#test-traffic)). Drift alarms that
traffic causes can start retraining pipeline runs, which cost the same as any
other run. The drift and fairness jobs need data capture, so they are skipped
when `use_serverless_inference = true`.

### Responsible AI

![Bias pipeline in Amazon SageMaker Pipelines: preprocess, train three models, evaluate and ensemble, then a bias check that always writes its report to S3; one quality gate checks accuracy and fairness together, registering a passing model in the SageMaker Model Registry as pending approval and sending a failing run to a fail step](docs/diagrams/mlops-fairness-gates.svg)

In the pipeline one condition step applies both gates after the fairness
check, and a failing execution ends in a Fail step with its evaluation and
fairness reports kept under its execution prefix.

- **Fairness gate in the pipeline.** Fairlearn scores the ensemble that would
  be registered, at its tuned threshold, per subgroup of an image attribute
  (`fairness_gate.sensitive_feature`, default `subgroup`, from the
  `<group>__<subgroup>__` file name or `manifest.csv`). When no image carries
  it the check is skipped and the run logs it; with it but fewer than two
  subgroups the result is "not evaluable" and the gate fails. Supply an attribute that matters for your use case before
  drawing any fairness conclusion.
- **Fairness on live traffic**, held to the same bar, once ground-truth
  labels are uploaded (see above).
- **Human approval** before any model serves traffic, including the baseline
  and drift-triggered retrains.
- **Model Card** recording intended use, a risk rating and caveats
  (`enable_model_card`).
- **Per-request explanations** (opt-in per call): `"explain": true` returns a
  Grad-CAM heatmap and region Shapley values with the prediction, computed on
  the endpoint for the served ensemble (see
  [Explanations in the response](#explanations-in-the-response)). They show
  which image regions drove the score. They help a human reviewer and are not
  validated against human annotations.
- **Hybrid inference** (optional): low-confidence predictions get a Bedrock
  description constrained by a guardrail (content filters, name
  anonymization); no guardrail, no Bedrock call.
- **Human review with Amazon Augmented AI (Amazon A2I)** (optional, `enable_human_review`, off by
  default). Amazon A2I is in maintenance mode and not open to new customers, so
  this only works in accounts that already use it.

## Costs

You pay for the resources while they exist. There are no NAT gateways or AWS
Network Firewall: the training VPC reaches Amazon S3 through a gateway
endpoint, which has no charge, and CloudWatch metrics through one interface
endpoint. Estimate your configuration with the
[AWS Pricing Calculator](https://calculator.aws/).

| Resource | Billed | Notes |
| --- | --- | --- |
| SageMaker real-time endpoint (`ml.m5.xlarge`, 2 to 3 instances) | Every hour it runs | The main standing cost, about $170 per instance per month in `us-east-1`, so about $340 for the default two (check your Region). Two is the minimum for canary traffic shifting; with `traffic_routing_type = "ALL_AT_ONCE"` you can run one. Both fleets are billed while a blue/green update runs. `use_serverless_inference = true` scales to zero but disables data capture and monitoring |
| SageMaker training jobs | Per run | 3 jobs per execution (4 with `baseline_cnn`); CPU `ml.c5.2xlarge` in the shipped tfvars, GPU if you change it. Managed Spot is available (`enable_managed_spot_training`) |
| SageMaker Processing jobs | Per run | 5 per pipeline execution, preprocessing on 2 instances, plus the hourly drift job and daily fairness job (`ml.t3.medium`, capped at 900 s) |
| VPC interface endpoint (CloudWatch metrics) | Every hour it exists, per Availability Zone, plus per GB | Two AZs (`training_vpc_monitoring_endpoint`, on by default). VPC flow logs (`training_vpc_flow_logs`) add CloudWatch Logs ingestion |
| AWS WAF | Monthly per web ACL and rule, plus per request | One regional web ACL with three rules (`api_enable_waf`) |
| API Gateway, Lambda, CloudFront | Per request | Low at demo traffic |
| Amazon Bedrock | Per token | Only for low-confidence predictions when hybrid inference is on |
| SageMaker MLflow tracking server | Every hour it runs | Off by default (`enable_mlflow`) |
| AWS CloudTrail trail | Data events per 100,000, plus S3 and CloudWatch Logs | On by default (`enable_cloudtrail`). S3 data events on the project buckets are the main part: a training run can create a few hundred thousand. Turn it off where an organization trail already records the account |
| Synthetic test traffic | Per run | Off by default (`test_traffic_enabled`). A few Lambda invocations and predictions an hour; drift alarms it causes can start retraining runs |
| Amazon S3 | Storage and requests | Buckets are versioned; images, capture and model artifacts accumulate |
| CodeBuild, ECR | Build minutes, storage | Weekly patched-image rebuild; the last 10 images are kept; CI/CD builds if you use `stack-cicd` |
| KMS, CloudWatch, SNS, SQS, EventBridge | Keys, metrics, alarms, logs | Small |

`stack-training` creates an AWS Budgets budget (`monthly_budget_usd`, default
200) scoped by the `Project` tag; set `budget_alert_emails` to be notified.
Destroy the stacks when you are not using them.

## Cleanup

The buckets default to `force_destroy = true` (`bucket_defaults` in
`stack-training`, `force_destroy_buckets` in `stack-inference` and
`stack-cicd`), so `terraform destroy` deletes them with their objects and
versions; set those to `false` to keep the data. The SageMaker resources that
pipeline runs and Lambda functions create are not in Terraform state and need
a cleanup step first. `make destroy` is the recommended path and does
everything for you:

```bash
make destroy PROFILE=<your-profile>
```

It runs `ops-scripts/cleanup_all.sh --destroy`, which asks you to type the
project name, then:

1. stops running pipeline executions and deletes what pipeline runs and
   Lambda functions created outside Terraform (endpoint, endpoint
   configurations, models, model packages, job log groups),
2. empties the project's buckets, including all object versions, and never
   touches the Terraform state bucket,
3. runs `terraform destroy` in `stack-cicd`, then `stack-inference`, then
   `stack-training` (`stack-inference` reads `stack-training` state, so this
   order matters).

Finally, empty the state bucket (it keeps state versions) and destroy the
bootstrap stack:

```bash
cd stack-backend-setup && terraform destroy
```

To run `terraform destroy` in each stack directory yourself, run the
pre-destroy cleanup first (steps 1 and 2 above, without the destroys), then
destroy `stack-inference`, `stack-training`, `stack-cicd` and finally
`stack-backend-setup`:

```bash
./ops-scripts/cleanup_all.sh --profile <your-profile>
export TF_VAR_state_bucket_name="$(terraform -chdir=stack-backend-setup output -raw state_bucket_id)"
export TF_VAR_state_bucket_region="$(terraform -chdir=stack-backend-setup output -raw state_bucket_region)"
export TF_VAR_permissions_boundary_arn="$(terraform -chdir=stack-backend-setup output -raw workload_boundary_arn)"
unset TF_VAR_model_package_arn
terraform -chdir=stack-inference destroy
terraform -chdir=stack-training destroy
terraform -chdir=stack-cicd destroy
```

`stack-inference` reads `stack-training` state, so it goes first. Leave
`model_package_arn` unset: the cleanup has deleted the model packages, and a
set value makes the destroy read the package it names. `stack-cicd` reads no
other stack's state, so it can go at any point before `stack-backend-setup`
(`make destroy` removes it first, so no pipeline run redeploys a stack during
the teardown). If a destroy stops on `BucketNotEmpty` (a bucket with
`force_destroy = false` that received objects after the cleanup), run the
cleanup again and repeat the destroy. Then empty the
state bucket and destroy `stack-backend-setup` as above.

Run `./ops-scripts/cleanup_all.sh --help` for `--project`, `--region`,
`--state-bucket` and `--yes`. Afterwards, check in the console that the
SageMaker endpoint and, if you enabled it, the MLflow tracking server are gone.
Custom CloudWatch metrics cannot be deleted and expire on their own.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Pipeline Source stage fails, or `github_connection_status` is `PENDING` | The CodeConnections handshake is not complete. Finish it in Developer Tools > Settings > Connections (see [Deploy through CI/CD](#deploy-through-cicd)), then release the change again. |
| Training job fails with `ResourceLimitExceeded` | No quota for the training instance type. Request the "for training job usage" quota in Service Quotas, or train on CPU (`ml.c5.2xlarge`, the shipped value). Instance types starting `ml.g` or `ml.p` use the GPU image; others use the CPU image. |
| Training job fails with a weights error | `backbone_weights_s3_uri` is set, but the prefix holds no `<model>.weights.h5` for that model, or several `.h5` files and none named for it. Fix the files under the prefix, or set `backbone_weights_s3_uri = ""` to train from random initialisation. |
| Pipeline ends at the Fail step | A gate failed. Read `quality_gate` in `ensemble_results.json` and `bias_metrics.json` under the execution's prefix in the model artifacts bucket. A `not_evaluable` fairness status means the test split held fewer than two subgroups of the `fairness_gate.sensitive_feature` attribute (file name or `manifest.csv`); for a small demo dataset set `allow_not_evaluable = true` in `stack-training/terraform.tfvars`. |
| `make deploy-inference` stops with `No Approved model package in <group>`, or the plan fails with `model_package_arn must be the versioned ARN of an Approved package` | Nothing in the group is approved yet, or `TF_VAR_model_package_arn` is not a versioned ARN. Approve the baseline (Quick start step 6) and run `make deploy-inference` again. In CI/CD the Inference-Deploy stage fails with `no Approved model package` for the same reason. |
| `Run 'make layer' to build the Lambda layer zip from the pinned versions` | `make deploy-inference` stops when the zip is missing, and both `make deploy-inference` and `make deploy-training` stop when it does not hold the pinned Pillow and NumPy versions. Run `make layer`. A plain `terraform apply` builds it on the first deploy and whenever `ops-scripts/build_lambda_layer.sh` changes (it needs bash, zip and uv or pip). |
| Apply fails with `ResourceAlreadyExistsException` on `/aws/codebuild/<project>-patched-image-build` | A deployment from an older version let the build create its own log group; the module now manages it. Run `terraform -chdir=stack-inference import module.patched_inference_image.aws_cloudwatch_log_group.build /aws/codebuild/<project>-patched-image-build`, or delete the group, and apply again. |
| The patched image build fails with `Scan gate` in its log | The pushed image had an Amazon ECR scan finding at or above `patched_image_scan_block_severity`, so the gate deleted it; the endpoint keeps the last image that passed. Wait for a patched base image, or raise the threshold (for example `HIGH` instead of `CRITICAL`) for a test deployment. |
| `BucketNotEmpty` on destroy | The bucket has `force_destroy = false` (any bucket after you set `bucket_defaults.force_destroy` or `force_destroy_buckets` to `false`). Use `make destroy`, or run `./ops-scripts/cleanup_all.sh` and retry the destroy. |
| `UpdateEndpoint`: "Could not find endpoint configuration" after an apply | An apply that replaced the stack's endpoint config (new base image tag, new model package) deleted the config the endpoint was still running, and a blue/green update needs it for rollback. Re-create a config under the missing name (copy of the new one), then run the update: `aws sagemaker update-endpoint` with the new config and the endpoint refresher's `DEPLOYMENT_CONFIG`. Patch rebuilds no longer replace it: the weekly refresher repins the image. |
| No fairness metric in CloudWatch | Expected until ground-truth labels are uploaded to `ground-truth/` in the monitoring bucket and at least 50 predictions match them. The job's CloudWatch log says why it published nothing. |
| No drift metric in CloudWatch | Fewer than 30 captured predictions in the window, or no baseline at `monitoring/baselines/output-only/statistics.json` yet: the auto-deploy Lambda writes it when it rolls out a trained package (see [Monitoring and retraining](#monitoring-and-retraining)). |
| `make deploy-training` fails with `ResourceAlreadyExistsException` for `/aws/sagemaker/ProcessingJobs` or `/aws/sagemaker/TrainingJobs` | SageMaker or an earlier deployment already created these account-wide log groups. Import them and apply again: `terraform -chdir=stack-training import 'module.cloudwatch_monitoring.aws_cloudwatch_log_group.processing_jobs[0]' /aws/sagemaker/ProcessingJobs` (and the same for `training_jobs[0]` with `/aws/sagemaker/TrainingJobs`), with the same `TF_VAR_*` values `make deploy-training` sets. The stack then owns them, so a destroy deletes them. |
| A validation, preprocessing or BiasCheck step, or the scheduled fairness job, fails or times out at `pip install` | The job runs in the training VPC, which has no route to PyPI, and its `<step>/wheels/` folder is missing from the scripts bucket. Run `make upload-scripts` from a machine with `pip` and PyPI access; it builds the wheelhouses and fails if any is missing afterwards. |
| `make seed-baseline` fails on `import tensorflow` | Install `boto3` and `tensorflow==2.19.0` into the Python that `python3` resolves to. |
| API returns 403 | Missing or wrong `x-api-key`, or the WAF rate rule blocked your IP. |
| API returns 401 `Unauthorized` | `api_authorization_type = "COGNITO_USER_POOLS"` and the request has no valid Cognito ID token in the `Authorization` header (missing, expired after 60 minutes, or from another user pool). The static web UI cannot sign in, so it gets 401 in this mode. |
| Uploaded images are missing from the `training_data_path` prefix | The upload quarantine Lambda moved them. Each one is under `quarantine/<original key>` in the raw data bucket with a `.reason.json` naming the failed check (extension, does not open, wrong format for its extension, or smaller than `quarantine_min_image_size_px`). Fix the file and upload it again. |
| `make deploy-inference` plan fails with `traffic shifting sends ... of the new fleet first` | Canary and linear traffic shifting need at least two instances. Keep `endpoint_initial_instance_count` and `endpoint_min_capacity` at 2 or more, or set `traffic_routing_type = "ALL_AT_ONCE"` to run one instance. |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Before you open a pull request, run the
same checks as CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)):

```bash
make fmt validate lint test
```

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) and [SECURITY.md](SECURITY.md) for more information.

## License

This library is licensed under the MIT-0 License. See the [LICENSE](LICENSE) file.
