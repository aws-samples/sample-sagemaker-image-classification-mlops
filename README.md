# Image Classification MLOps on Amazon SageMaker

> [!WARNING]
> **Disclaimer.** This is sample code for demonstration and learning. It is
> not a cleared clinical product, has not been validated for diagnostic use,
> and must not be used to make medical decisions. It deploys real, billable AWS
> resources (an always-on SageMaker real-time endpoint, training and Processing
> jobs, AWS WAF and more) that cost money for as long as they exist. Review
> [Costs](#costs), [Cleanup](#cleanup) and [SECURITY.md](SECURITY.md) before
> you deploy, and deploy only into a non-production account you control.

## Overview

This sample is an end-to-end MLOps pipeline for binary image classification on
Amazon SageMaker, written entirely in Terraform. The worked example classifies
breast histopathology images (the public BreakHis dataset) as **benign** or
**malignant**, but nothing in the architecture is specific to that dataset:
change the data and the labels to reuse it for another binary image problem.

It covers the whole lifecycle:

- event-driven data validation and preprocessing with a patient-grouped split,
- three transfer-learning models trained in parallel and combined into an
  ensemble whose decision threshold is tuned on the validation split,
- a clinical quality gate and a Fairlearn fairness gate scored on the test
  split, with a failed gate stopping the pipeline,
- governed deployment: every model registers as `PendingManualApproval`, and a
  person's approval triggers a blue/green endpoint update that sends 10% of
  the new fleet's capacity traffic first (canary) and rolls back
  automatically on the error and latency alarms,
- a public API behind AWS WAF and an API key, with optional Amazon Bedrock
  reasoning for low-confidence predictions,
- scheduled drift (PSI) and fairness monitoring that can start retraining.

Everything that persists (endpoint, endpoint configuration, auto-scaling,
alarms, schedules, registry) is a Terraform resource. Lambda functions only
orchestrate: they serve predictions, roll an approved model onto the endpoint,
and refresh the endpoint weekly.

## Table of contents

1. [Architecture](#architecture)
2. [What each stack deploys](#what-each-stack-deploys)
3. [Repository structure](#repository-structure)
4. [Prerequisites](#prerequisites)
5. [Quick start](#quick-start)
6. [Deploy through CI/CD](#deploy-through-cicd)
7. [Call the API](#call-the-api)
8. [Monitoring and retraining](#monitoring-and-retraining)
9. [Responsible AI](#responsible-ai)
10. [Costs](#costs)
11. [Cleanup](#cleanup)
12. [Troubleshooting](#troubleshooting)
13. [Security](#security)
14. [Contributing](#contributing)
15. [License](#license)

## Architecture

![Overall architecture: data and training, serving, monitoring and CI/CD groups inside the AWS Cloud, with KMS, CloudTrail and IAM across all stacks](docs/diagrams/mlops-architecture.svg)

1. A data batch lands in the image data bucket. When the upload finishes, a
   `.batch_complete` marker object makes an Amazon EventBridge rule start the
   SageMaker pipeline.
2. SageMaker Pipelines validates, preprocesses, trains, evaluates and gates the
   model, writes every artifact under a prefix for that execution, and
   registers a passing ensemble in the SageMaker Model Registry as pending.
3. A reviewer approves a version. The approved model is rolled onto the
   SageMaker real-time endpoint.
4. Users open the web UI through Amazon CloudFront (static files in a private
   S3 bucket) and send images to Amazon API Gateway through AWS WAF with an
   API key. An AWS Lambda function calls the endpoint and, for low-confidence
   results, optionally asks Amazon Bedrock for a guarded explanation.
5. The endpoint captures its responses to S3. EventBridge Scheduler runs a
   drift job every hour and a fairness job every day; both publish metrics to
   Amazon CloudWatch, whose alarms notify Amazon SNS and can start a retraining
   run.
6. The optional CI/CD stack deploys the same stacks with AWS CodePipeline and
   AWS CodeBuild, and a CodeBuild project rebuilds the patched inference image
   in Amazon ECR every month.
7. Across all stacks, customer managed AWS KMS keys encrypt data at rest, IAM
   roles are scoped to the project and bounded by a permissions boundary, and
   an AWS CloudTrail trail can be turned on for audit.

The diagrams are SVG files in [docs/diagrams/](docs/diagrams/); PNG exports
of the same figures are in [docs/diagrams/png/](docs/diagrams/png/).

## What each stack deploys

The sample is four Terraform root modules (stacks) plus reusable modules in
`modules/`. They are applied in this order:

| Order | Stack | Purpose |
| --- | --- | --- |
| 1 | [stack-backend-setup](stack-backend-setup/README.md) | Bootstrap with local state: S3 state bucket, state KMS key, workload permissions boundary |
| 2 | [stack-training](stack-training/README.md) | Data and model buckets, SageMaker pipeline, Model Registry, Model Card, budget, optional MLflow and CloudTrail |
| 3 | [stack-inference](stack-inference/README.md) | Endpoint, API, web UI, auto-deploy, drift and fairness monitoring, Bedrock guardrail |
| 4 (optional) | [stack-cicd](stack-cicd/README.md) | CodePipeline and CodeBuild that apply stacks 2 and 3 from your GitHub repository |

### stack-backend-setup

Creates the versioned, KMS-encrypted Terraform state bucket (S3 native state
locking, no DynamoDB), its KMS key, and the `<project_name>-workload-boundary`
IAM permissions boundary that every role in the other stacks carries. It keeps
its own state locally and prints the `backend.hcl` the other stacks use.

### stack-training

Creates a project KMS key, six S3 buckets (raw data, processed data, scripts,
model artifacts, inference results, monitoring) plus an SBOM bucket by default,
the SageMaker execution role, the Model Package Group, a Model Card, an AWS
Budgets budget, CloudWatch dashboards, the upload quarantine Lambda, and the
SageMaker pipeline with its EventBridge trigger. A managed MLflow tracking server (`enable_mlflow`) and a
multi-region CloudTrail trail (`enable_cloudtrail`) are available but off by
default.

![Training pipeline: an upload marker starts SageMaker Pipelines, which validates, preprocesses, trains three models in parallel, evaluates, builds an ensemble, runs a Fairlearn check and either registers the model as pending or fails](docs/diagrams/mlops-training-pipeline.svg)

1. As each image lands under `medical_image_data/`, the upload quarantine
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
3. **Validate data** (Processing job) checks image format, resolution, class
   balance and quality.
4. **Preprocess** resizes images to 512 x 512 and writes train, validation and
   test splits grouped by patient, so images of one patient never appear in
   more than one split.
5. **Train** VGG16, DenseNet121 and EfficientNetV2M in parallel training jobs
   with two-phase transfer learning. Training images get flips, small shifts
   and rotations, and a random H&E stain jitter, because stain colour differs
   more between patients than between classes and the models otherwise learn
   colour instead of tissue structure. Training jobs run with network
   isolation by default and read ImageNet weights from the scripts bucket.
6. **Evaluate** tunes each model's threshold on the validation split and
   reports its metrics on the test split.
7. **Ensemble** combines the three models, tunes the ensemble threshold on the
   validation split and scores the test split at that threshold.
8. **Fairness check** runs Fairlearn over the ensemble's own test predictions
   at its tuned threshold, per magnification subgroup.
9. **Condition** requires accuracy >= 0.85, recall >= 0.95, precision >= 0.80,
   AUC >= 0.90 and a fairness disparity <= 0.10. If every check passes, the
   ensemble is registered as `PendingManualApproval`; otherwise the execution
   ends in a Fail step and nothing is registered.
10. Evaluation, ensemble and fairness outputs are written under
    `<prefix>/<pipeline-execution-id>/`, so each model package points at its
    own weights and reports, and approving an older version deploys that
    version.

### stack-inference

Creates the patched inference image (built once at apply time, then monthly),
the SageMaker model, endpoint configuration and endpoint (Terraform-managed,
with blue/green canary deployment, auto-rollback alarms and auto-scaling), the
inference Lambda and its Pillow/NumPy layer, the API Gateway REST API with a
usage plan, API key and WAF web ACL, the CloudFront web UI, the auto-deploy
Lambda, the drift and fairness schedules and alarms, the retraining rule, SNS
alerts, a CloudWatch dashboard, a weekly endpoint refresh, and the Bedrock
guardrail when hybrid inference is on.

![Inference and monitoring: the browser loads the web UI from CloudFront and posts images through WAF to API Gateway with an API key; Lambda invokes the endpoint and Bedrock; captured data feeds scheduled PSI and Fairlearn jobs that publish to CloudWatch and SNS](docs/diagrams/mlops-inference-monitoring.svg)

1. The browser loads the static web UI from CloudFront, which reads it from a
   private S3 bucket.
2. The browser posts the image directly to API Gateway, sending the API key in
   the `x-api-key` header. AWS WAF inspects the request first.
3. API Gateway invokes the inference Lambda, which validates and preprocesses
   the image and calls the endpoint with its request id as `InferenceId`.
4. When hybrid inference is on and the confidence is below the cutoff, the
   Lambda asks Amazon Bedrock for a natural-language explanation, filtered by a
   Bedrock guardrail.
5. The endpoint writes data capture to the monitoring bucket (model output by
   default; request payloads too when `data_capture_input = true`).
6. EventBridge Scheduler starts the PSI drift job hourly and the Fairlearn job
   daily. They read captured predictions, and the fairness job joins them with
   the confirmed outcomes a clinician uploads to the `ground-truth/` prefix.
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
|-- ops-scripts/           # Local helpers: layer build, API test, dataset download, cleanup
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
- SageMaker Processing: `ml.m5.4xlarge`, `ml.m5.large` and `ml.t3.medium` for
  processing job usage.
- SageMaker hosting: two `ml.m5.xlarge` for endpoint usage (up to three with
  the default auto-scaling maximum), plus room for the second fleet during a
  blue/green update: a rollout runs the old and new fleets side by side, so
  allow at least five.

**Amazon Bedrock**

- Hybrid inference is off in the module default but on in the shipped
  `stack-inference/terraform.tfvars` (`enable_bedrock_hybrid_inference = true`).
  When it is on, the model in `bedrock_model_id` (default
  `us.amazon.nova-pro-v1:0`, a cross-Region inference profile) must be
  available to the account. Set it to `false` if you do not want Bedrock.

**Tools**

| Tool | Version | Used for |
| --- | --- | --- |
| Terraform | `~> 1.15` (every stack's `versions.tf`) | All stacks |
| AWS CLI | v2 | `local-exec` build of the patched image, approvals, cleanup |
| Python | 3.13 or later (`pyproject.toml`) | Helper scripts and tests |
| uv or pip | uv recommended | Building the Lambda layer, installing tools |
| make, bash, zip | any recent | Makefile targets, layer build |

`make seed-baseline` and `scripts/download_pretrained_weights.py` build Keras
models locally, so the Python that `python3` resolves to needs `boto3` and
`tensorflow==2.19.0` (the version the endpoint serves). A virtual environment
is the simplest way to keep that separate. `ops-scripts/test_api.py` needs
`requests` and `Pillow`. For the local checks you also need `ruff`, `pytest`
and `checkov` (`pip install --group dev` installs ruff and pytest).

## Quick start

Run everything from the repository root. The Makefile honours
`PROFILE=<name>` (or an exported `AWS_PROFILE`); every deploy target runs
`terraform plan -out` and applies the saved plan.

**0. Configure.** Review `stack-training/terraform.tfvars` and
`stack-inference/terraform.tfvars`: `project_name`, `environment`,
`aws_region`, `budget_alert_emails`, `alert_email`, instance types and the
Bedrock toggle. `training_data_path` must match the prefix
`scripts/data_uploader.sh` writes to (`medical_image_data/`).

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

**5. Upload ImageNet weights (network isolation on, the default).** Training
jobs have no internet access, so the trainers read weights from the scripts
bucket. Do this once before the first pipeline run. The target does nothing
when `enable_network_isolation = false`; it needs TensorFlow locally.

```bash
make weights
```

**6. Upload the scripts and seed the baseline model.**

```bash
make seed-baseline
```

The endpoint cannot exist without an approved model, so this registers a
placeholder baseline (a toy network that cannot classify images) as
`PendingManualApproval` and prints its ARN. It does nothing when the group
already holds an approved or pending package.

**7. Approve the baseline.** Nothing is approved automatically; this is a
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

**8. Deploy the inference stack.** The target looks up the newest Approved
package in the group, the same query the CI/CD Inference-Deploy stage runs;
set `TF_VAR_model_package_arn` to pin a different version.

```bash
make deploy-inference
```

The first apply also builds the patched inference image in CodeBuild and waits
for it, which takes several minutes.

`make deploy-all` runs steps 1 to 6 and 8 in order. It cannot approve the
baseline for you, so on a first run it stops before the inference stack with
`No Approved model package in <group>`; approve the baseline (step 7) and run
`make deploy-inference`.

**9. Train a real model.** Download BreakHis (about 4 GB) and upload it; the
uploader writes the `.batch_complete` marker that starts the pipeline.

```bash
./ops-scripts/data_download_breakhis.sh data/breakhis
./scripts/data_uploader.sh data/breakhis
```

The upload quarantine Lambda checks every file as it lands and moves bad ones
to `quarantine/` in the raw data bucket, each with a `.reason.json`
([stack-training README](stack-training/README.md#upload-quarantine)). The
pipeline's validation step checks the images again, so a file the Lambda has
not reached when the marker starts the run still fails validation.

Expect the gates to fail on BreakHis with the default models. BreakHis has 82
patients, so the patient-grouped test split holds 13 of them (4 benign), and a
single patient the models get wrong moves recall or precision by several
points. In a September 2026 run the ensemble scored accuracy 0.76, recall 0.90,
precision 0.76 and AUC 0.79 on the test split (AUC 0.96 on validation), so the
pipeline stopped at the Fail step and registered nothing. Most errors came
from three test patients whose stain colour looks like the other class. Treat
BreakHis as a way to exercise the pipeline; a model that clears the gates
needs more patients or a stronger model, not lower thresholds.

When the execution registers a version, check its metrics in the registry and
approve it with the same `update-model-package` command. The approval event
triggers the auto-deploy Lambda, which rolls the new version onto the endpoint
with a blue/green canary update. Keep the file names: the patient-grouped split and
the fairness gate read the BreakHis patient id and magnification from them.

## Deploy through CI/CD

![CI/CD deployment: a push to GitHub starts CodePipeline, whose CodeBuild stages deploy training, register the baseline, upload scripts and weights, and, after manual approval, deploy inference, with state in the KMS-encrypted state bucket](docs/diagrams/mlops-cicd.svg)

1. A push to the tracked branch of your GitHub repository starts the pipeline
   through AWS CodeConnections.
2. **Training-Deploy** installs a pinned Terraform release, verifies it against
   HashiCorp's `SHA256SUMS`, and applies `stack-training` from a saved plan.
3. **BaselineModelCreation** registers the placeholder baseline as
   `PendingManualApproval` on the first run and prints its ARN in the build log.
4. **Script-Upload** uploads the pipeline scripts and the ImageNet weights to
   the scripts bucket.
5. **Inference-Deploy** waits for the manual approval action
   (`require_manual_approval`, default `true`), then builds the Lambda layer and
   applies `stack-inference` with the newest Approved package in the group. It
   fails if no package is approved yet.
6. Both Terraform stages keep their state in the KMS-encrypted state bucket
   created by `stack-backend-setup`.

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
   BaselineModelCreation log, command as in Quick start step 7) before you
   approve the pipeline's manual approval action.

Subscribers in `approval_notification_emails` must confirm the SNS
subscription before they get approval notices.

## Call the API

The API requires an API key in the `x-api-key` header. Terraform outputs the
URL and the key:

```bash
API_URL=$(terraform -chdir=stack-inference output -raw api_gateway_url)
API_KEY=$(terraform -chdir=stack-inference output -raw api_key_value)
python3 ops-scripts/test_api.py --api-url "$API_URL" --api-key "$API_KEY" \
  --image-path data/breakhis/breast_benign/<file>.png
```

Without `--image-path` the script samples `--count` images per class from
`--data-path` (default `data/`) and checks each prediction against the folder
label. Without `--api-url` and `--api-key` it reads both from `terraform
output`.

The API has two routes:

- `POST /predict` with a JSON body `{"image": "<base64 image>"}`. The response
  carries `request_id`, `prediction`, `confidence`, `probabilities`,
  `threshold_used`, `routing` and, when hybrid inference answers, `reasoning`.
  Images larger than `max_image_bytes` (5 MB by default) return HTTP 413.
- `GET /results/{request_id}` returns the stored prediction for that request.

### Explanations in the response

Add `"explain": true` to the `POST /predict` body to get per-image
explanations with the prediction (`--explain` in `test_api.py`). They are off
unless asked for, so a request without the field gets the same response, at
the same latency, as before. `{"explain": {"methods": ["gradcam"]}}` asks for
one method only (`gradcam` or `region_shapley`).

```json
{
  "request_id": "3f1c2a9e-5b7d-4e2a-9c1f-0a1b2c3d4e5f",
  "prediction": "malignant",
  "confidence": 0.91,
  "probabilities": {"benign": 0.09, "malignant": 0.91},
  "threshold_used": 0.42,
  "model_info": "Image analysis using ensemble model",
  "routing": "high-confidence-custom",
  "explanations": {
    "gradcam": {
      "method": "grad-cam",
      "target": "malignant",
      "layer": "feature map feeding global average pooling (last convolutional block)",
      "combination": "ensemble-weighted average of per-model maps, each scaled to max 1",
      "grid_size": 14,
      "grid": [[0.021, 0.054, 0.112]],
      "top_region": {"box": [0.2857, 0.1429, 0.6429, 0.5], "peak_cell": [4, 6], "cells": 19},
      "elapsed_ms": 310
    },
    "region_shapley": {
      "method": "region Shapley values estimated by antithetic permutation sampling",
      "target": "malignant probability",
      "grid_size": 4,
      "values": [[0.012, -0.003, 0.041, 0.0]],
      "baseline": "ImageNet mean colour (0 after normalisation)",
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

`grid` (14 x 14) and `values` (4 x 4) are cut to their first row here. The
whole `explanations` object is under 3 KB. How they are computed, on the
endpoint, for the ensemble that made the call:

- **Grad-CAM** for the predicted class. Each member model's SavedModel carries
  a `gradcam` signature: activations are the feature map that feeds its global
  average pooling layer (the last convolutional block), gradients are of the
  malignant logit (negated for a benign call), and the map is resized to
  14 x 14. The handler scales each member's map to a maximum of 1 and averages
  them with the ensemble weights. `top_region.box` is `[x_min, y_min, x_max,
  y_max]` as fractions of the image, around the connected cells at 50% of the
  peak or more.
- **Region Shapley values**, estimated by sampling. The image is split into a
  4 x 4 grid; a region left out is set to the ImageNet mean colour. The value
  of a region is its average marginal effect on the ensemble's malignant
  probability over random orderings of the regions, drawn in antithetic
  pairs with a fixed seed. The values always sum to `full_score -
  baseline_score`. This is not the `shap` library, and 32 evaluations of 16
  regions is a coarse estimate, not an exact Shapley value.

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

## Monitoring and retraining

![Retraining loop: a drift or fairness alarm makes an EventBridge rule start the pipeline with RetrainingReason, the new version waits in the registry for a reviewer, and the approval triggers the auto-deploy Lambda that runs a blue/green update with rollback](docs/diagrams/mlops-retraining-loop.svg)

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
  Stability Index of the endpoint's malignant-probability scores over the last
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
  predictions with confirmed outcomes uploaded as JSON Lines
  (`{"request_id": ..., "label": 0|1, "group": "<subgroup>"}`) to the
  `ground-truth/` prefix of the monitoring bucket, and publishes the larger of
  the demographic-parity and equalized-odds differences. The sample does not
  populate that prefix; until someone does, the job publishes no metric.
- **Operations**: API Gateway 4XX/5XX, endpoint errors and latency alarms, a
  composite health alarm, and a CloudWatch dashboard. Set `alert_email` to get
  the SNS notifications.

`ops-scripts/ops_generate_endpoint_traffic.py` sends labelled images straight
to the endpoint to seed data capture before real traffic exists, and
`ops-scripts/verify_monitoring.sh` checks that the alarms, topics and rules
exist. The drift and fairness jobs need data capture, so they are skipped when
`use_serverless_inference = true`.

## Responsible AI

- **Fairness gate in the pipeline.** Fairlearn scores the ensemble that would
  be registered, at its tuned threshold, per subgroup. BreakHis carries no
  demographic data, so the subgroup is image magnification, an honest proxy.
  With fewer than two subgroups the result is "not evaluable" and the gate
  fails. Supply a real sensitive attribute before drawing any fairness
  conclusion.
- **Fairness on live traffic**, held to the same bar, once confirmed outcomes
  are uploaded (see above).
- **Human approval** before any model serves traffic, including the baseline
  and drift-triggered retrains.
- **Model Card** recording intended use, a High risk rating and clinical
  caveats (`enable_model_card`).
- **Per-request explanations** (opt-in per call): `"explain": true` returns a
  Grad-CAM heatmap and region Shapley values with the prediction, computed on
  the endpoint for the served ensemble (see
  [Explanations in the response](#explanations-in-the-response)). They show
  which image regions drove the score. They are decision support for a
  reviewer and are not validated against pathologist annotations.
- **Hybrid inference** (optional): low-confidence predictions get a Bedrock
  explanation constrained by a guardrail (content filters, name
  anonymization).
- **Human review with Amazon A2I** (optional, `enable_human_review`, off by
  default). Amazon A2I is in maintenance mode and not open to new customers, so
  this only works in accounts that already use it.

## Costs

You pay for the resources while they exist. There are no NAT gateways, AWS
Network Firewall or VPC endpoints by default (nothing runs in a VPC unless you
set `vpc_config` in `stack-training`). Estimate your configuration with the
[AWS Pricing Calculator](https://calculator.aws/).

| Resource | Billed | Notes |
| --- | --- | --- |
| SageMaker real-time endpoint (`ml.m5.xlarge`, 2 to 3 instances) | Every hour it runs | The main standing cost, about $170 per instance per month in `us-east-1`, so about $340 for the default two (check your Region). Two is the minimum for canary traffic shifting; with `traffic_routing_type = "ALL_AT_ONCE"` you can run one. Both fleets are billed while a blue/green update runs. `use_serverless_inference = true` scales to zero but disables data capture and monitoring |
| SageMaker training jobs | Per run | 3 jobs per execution; CPU `ml.c5.2xlarge` in the shipped tfvars, GPU if you change it. Managed Spot is available (`enable_managed_spot_training`) |
| SageMaker Processing jobs | Per run | 5 per pipeline execution, plus the hourly drift job and daily fairness job (`ml.t3.medium`, capped at 900 s) |
| AWS WAF | Monthly per web ACL and rule, plus per request | One regional web ACL with three rules (`api_enable_waf`) |
| API Gateway, Lambda, CloudFront | Per request | Low at demo traffic |
| Amazon Bedrock | Per token | Only for low-confidence predictions when hybrid inference is on |
| SageMaker MLflow tracking server | Every hour it runs | Off by default (`enable_mlflow`) |
| AWS CloudTrail trail | Per event delivered, plus S3 | Off by default (`enable_cloudtrail`); leave it off when an organization trail covers the account |
| Amazon S3 | Storage and requests | Buckets are versioned; images, capture and model artifacts accumulate |
| CodeBuild, ECR | Build minutes, storage | Monthly patched-image rebuild; the last 10 images are kept; CI/CD builds if you use `stack-cicd` |
| KMS, CloudWatch, SNS, SQS, EventBridge | Keys, metrics, alarms, logs | Small |

`stack-training` creates an AWS Budgets budget (`monthly_budget_usd`, default
200) scoped by the `Project` tag; set `budget_alert_emails` to be notified.
Destroy the stacks when you are not using them.

## Cleanup

`force_destroy` is `false` on the buckets, so they must be emptied before
Terraform can delete them. `make destroy` does that for you:

```bash
make destroy PROFILE=<your-profile>
```

It runs `ops-scripts/cleanup_all.sh --destroy`, which asks you to type the
project name, then:

1. deletes what pipeline runs and Lambda functions created outside Terraform
   (endpoint, endpoint configurations, models, model packages, job log groups),
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

Run `./ops-scripts/cleanup_all.sh --help` for `--project`, `--region`,
`--state-bucket` and `--yes`. Afterwards, check in the console that the
SageMaker endpoint and, if you enabled it, the MLflow tracking server are gone.
Custom CloudWatch metrics cannot be deleted and expire on their own.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Pipeline Source stage fails, or `github_connection_status` is `PENDING` | The CodeConnections handshake is not complete. Finish it in Developer Tools > Settings > Connections (see [Deploy through CI/CD](#deploy-through-cicd)), then release the change again. |
| Training job fails with `ResourceLimitExceeded` | No quota for the training instance type. Request the "for training job usage" quota in Service Quotas, or train on CPU (`ml.c5.2xlarge`, the shipped value). Instance types starting `ml.g` or `ml.p` use the GPU image; others use the CPU image. |
| Training job fails at start or cannot load weights | Network isolation is on and `pretrained-weights/` in the scripts bucket is empty. Run `make weights` (Quick start step 5), or set `enable_network_isolation = false`. |
| Pipeline ends at the Fail step | A gate failed. Read `clinical_quality_gate` in `ensemble_results.json` and `bias_metrics.json` under the execution's prefix in the model artifacts bucket. A `not_evaluable` fairness status means the file names carried fewer than two magnification subgroups; for a small demo dataset set `allow_not_evaluable = true` in `stack-training/terraform.tfvars`. |
| `make deploy-inference` stops with `No Approved model package in <group>`, or the plan fails with `model_package_arn must be the versioned ARN of an Approved package` | Nothing in the group is approved yet, or `TF_VAR_model_package_arn` is not a versioned ARN. Approve the baseline (Quick start step 7) and run `make deploy-inference` again. In CI/CD the Inference-Deploy stage fails with `no Approved model package` for the same reason. |
| `Lambda layer zip missing: run 'make layer'` | `make deploy-inference` checks for the zip first. Run `make layer`. A plain `terraform apply` builds it automatically when missing (it needs bash, zip and uv or pip); delete the zip to force a rebuild. |
| `BucketNotEmpty` on destroy | Buckets have `force_destroy = false`. Use `make destroy`, or run `./ops-scripts/cleanup_all.sh` and retry the destroy. |
| No fairness metric in CloudWatch | Expected until confirmed outcomes are uploaded to `ground-truth/` in the monitoring bucket and at least 50 predictions match them. The job's CloudWatch log says why it published nothing. |
| No drift metric in CloudWatch | Fewer than 30 captured predictions in the window, or no baseline at `monitoring/baselines/output-only/statistics.json` yet: the auto-deploy Lambda writes it when it rolls out a trained package (see [Monitoring and retraining](#monitoring-and-retraining)). |
| `make deploy-training` fails with `ResourceAlreadyExistsException` for `/aws/sagemaker/ProcessingJobs` or `/aws/sagemaker/TrainingJobs` | SageMaker or an earlier deployment already created these account-wide log groups. Import them and apply again: `terraform -chdir=stack-training import 'module.cloudwatch_monitoring.aws_cloudwatch_log_group.processing_jobs[0]' /aws/sagemaker/ProcessingJobs` (and the same for `training_jobs[0]` with `/aws/sagemaker/TrainingJobs`), with the same `TF_VAR_*` values `make deploy-training` sets. The stack then owns them, so a destroy deletes them. |
| `make seed-baseline` fails on `import tensorflow` | Install `boto3` and `tensorflow==2.19.0` into the Python that `python3` resolves to. |
| API returns 403 | Missing or wrong `x-api-key`, or the WAF rate rule blocked your IP. |
| Uploaded images are missing from `medical_image_data/` | The upload quarantine Lambda moved them. Each one is under `quarantine/<original key>` in the raw data bucket with a `.reason.json` naming the failed check (extension, does not open, wrong format for its extension, or smaller than `quarantine_min_image_size_px`). Fix the file and upload it again. |
| `make deploy-inference` plan fails with `traffic shifting sends ... of the new fleet first` | Canary and linear traffic shifting need at least two instances. Keep `endpoint_initial_instance_count` and `endpoint_min_capacity` at 2 or more, or set `traffic_routing_type = "ALL_AT_ONCE"` to run one instance. |

## Security

See [SECURITY.md](SECURITY.md) for the security model, known limitations, what
you must still do before any real use, and how to report a vulnerability.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Before you open a pull request, run the
same checks as CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)):

```bash
make fmt validate lint test
```

## License

This library is licensed under the MIT-0 License. See the [LICENSE](LICENSE)
file. Dataset licensing is your responsibility; confirm the terms of any
dataset you use and never commit PHI or PII.
