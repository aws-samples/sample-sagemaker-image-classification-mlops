# Security

## Reporting a security issue

If you discover a potential security issue in this project, notify AWS/Amazon Security through the [vulnerability reporting page](https://aws.amazon.com/security/vulnerability-reporting/). Do **not** create a public GitHub issue.

## Disclaimer

This repository is sample code for demonstration and learning. It is not
intended for production use. It shows how an end-to-end MLOps lifecycle can be
expressed in Terraform on Amazon SageMaker AI.

Do not deploy it as-is for a production workload. Several choices favour a
readable public sample over production hardening; they are listed under
[Known limitations](#known-limitations) and
[What you must still do](#what-you-must-still-do). Review both before adapting
this code.

Deploying this project creates real, billable AWS resources. See the
[Costs](README.md#costs) and [Cleanup](README.md#cleanup) sections of the
README.

## What this sample deploys

- **Amazon SageMaker AI**: Amazon SageMaker Pipelines, training and processing
  jobs, the Model Registry, a Model Card, a real-time endpoint and, optionally,
  a managed MLflow tracking server.
- **Amazon Simple Storage Service (Amazon S3)**: buckets for raw data,
  processed data, scripts, model artifacts, inference results, monitoring, the
  SBOM, the audit trail, server access logs, the web UI and Terraform state.
- **AWS Key Management Service (AWS KMS)**: customer managed keys for the
  project and for the Terraform state.
- **AWS Identity and Access Management (IAM)**: one role per component and a
  permissions boundary on every workload role.
- **AWS Lambda**: the inference API, upload quarantine, approval-driven
  deployment, the weekly endpoint refresh and optional test traffic.
- **Amazon API Gateway**: the REST API with an API key and usage plan.
- **AWS WAF**: a regional web ACL in front of the API.
- **Amazon CloudFront**: the static web UI.
- **Amazon Cognito** (optional): a user pool that authenticates API callers.
- **Amazon Bedrock** (optional): descriptions of low-confidence predictions,
  filtered by an Amazon Bedrock guardrail.
- **Amazon Augmented AI (Amazon A2I)** (optional): human review of
  low-confidence predictions.
- **Amazon EventBridge and Amazon EventBridge Scheduler**: the pipeline
  triggers, the approval rule, and the drift, fairness, refresh and test
  traffic schedules.
- **Amazon CloudWatch**: metrics, alarms, dashboards and log groups.
- **Amazon Simple Notification Service (Amazon SNS)**: alert and approval
  notifications.
- **Amazon Simple Queue Service (Amazon SQS)**: dead-letter queues.
- **Amazon Elastic Container Registry (Amazon ECR)**: the patched inference
  image.
- **AWS CodeBuild**: the patched image build and, in the optional CI/CD stack,
  the deploy stages.
- **AWS CodePipeline and AWS CodeConnections** (optional): the CI/CD pipeline
  and its GitHub connection.
- **Amazon Virtual Private Cloud (Amazon VPC)**: the private training VPC with
  an S3 gateway endpoint, a CloudWatch metrics interface endpoint and flow logs.
- **AWS CloudTrail**: a multi-Region trail with data events on the project
  buckets and Lambda functions.
- **AWS X-Ray**, **Application Auto Scaling** and **AWS Budgets**: tracing,
  endpoint scaling and a cost budget.

## Data handling

- The sample ships no dataset and no model weights, and downloads neither. It
  was tested during development on a public image dataset that it does not
  distribute. No data is committed; `data/` is gitignored.
- You are responsible for the data and any backbone weights you bring, and for
  their licenses and terms of use. Keep personal or confidential data out of
  them unless your account and processes are approved for that data, and never
  commit them.
- The inference AWS Lambda function logs only the method, path, request id and
  payload size, never the image or the model response. Error responses are
  generic.
- Uploaded images and their predictions are stored in the inference results
  bucket under `predictions/<request_id>/` so `GET /results/{id}` can return
  the prediction. A lifecycle rule expires those objects and their noncurrent
  versions after `inference_results_retention_days` (default 30, set in
  `stack-training`).
- The API never returns Amazon S3 URIs: `POST /predict` does not include the
  image location, and `GET /results/{id}` strips it even from records written
  by an older version.
- Endpoint data capture stores model output only by default. Set
  `data_capture_input = true` only if you also want every request payload
  (every uploaded image) in the monitoring bucket.
- CloudWatch log groups keep their events for `log_retention_days` (365 by
  default).
- S3 server access logs for the project buckets and the web UI bucket, and the
  Amazon CloudFront standard logs (v2) of the web UI under `cloudfront/`, go to
  the access-log bucket (`enable_s3_access_logging`, default `true`), which
  expires them after `access_log_retention_days` (default 365).
- Fairness subgroups come from an image attribute you supply
  (`fairness_gate.sensitive_feature`, default `subgroup`: the
  `<group>__<subgroup>__` file name prefix or a `manifest.csv` column), and
  from the `group` field of the ground-truth labels for the live monitor.
  When no image carries it, the in-pipeline fairness check is skipped. Choose
  an attribute that matters for your use case before drawing any fairness
  conclusion.

## Controls in place

### Encryption

- Customer managed AWS KMS keys with rotation encrypt the Terraform state
  bucket, every project S3 bucket (the web UI bucket included), the CloudWatch
  log groups the stacks create (Lambda, AWS WAF, Amazon VPC flow logs, the
  AWS CloudTrail log group and the patched image build; the CI/CD stack's
  AWS CodeBuild log groups use the Terraform state key), the CloudTrail log files, Lambda
  environment variables, every SQS dead-letter queue (the monitoring schedules'
  queue included), the Amazon Bedrock guardrail, the Amazon ECR repository,
  SageMaker job volumes and outputs, and the endpoint's ML storage volume. Keys
  are deleted only after a 30-day window (`kms_deletion_window_days`).
- With `enable_training_monitoring` (on in the shipped `terraform.tfvars`),
  `stack-training` creates and owns the SageMaker job log groups
  `/aws/sagemaker/TrainingJobs` and `/aws/sagemaker/ProcessingJobs`, on the
  project key with `log_retention_days`. Every SageMaker job in the account
  and Region writes to them, so their logs use this project's key and
  `terraform destroy` deletes the groups; in an account where they already
  exist, import them first or turn the option off. Deploy into a dedicated
  account. The endpoint log group (`/aws/sagemaker/Endpoints/<name>`) is
  created by SageMaker AI and stays on CloudWatch Logs' default encryption
  with no retention limit unless you set one.
- The Amazon SNS alerts topic that the CloudWatch alarms notify is encrypted
  with the project key, whose key policy lets CloudWatch alarms in this account
  use it, so alarm notifications are delivered.
- The optional Amazon A2I human review writes its output encrypted with the
  project key.
- The optional CI/CD stack keeps its AWS CodePipeline artifacts bucket and its
  approvals topic on the Terraform state key.
- The access-log bucket uses Amazon S3 managed keys (SSE-S3), the only
  encryption S3 server access logging delivers to.
- The optional Amazon Cognito user pool is encrypted at rest with an AWS owned
  key; the AWS provider has no customer managed key setting for user pools yet.
- Bucket policies and the SQS queue policies deny requests that do not use TLS
  (`aws:SecureTransport`), public access is blocked on every bucket, and
  object ownership is `BucketOwnerEnforced`.

### Identity and access

- Every IAM role that `stack-training` and `stack-inference` create carries the
  `<project_name>-workload-boundary` permissions boundary from
  `stack-backend-setup` (`permissions_boundary_arn` is required; `make` and
  the CI/CD stages pass it), and every role has a description. The boundary limits
  roles to the services the workload uses, limits Amazon S3, Lambda and
  CodeBuild to project-prefixed resources and AWS KMS to keys tagged with the
  project, and allows `iam:PassRole` only on project roles. It also denies
  passing the CI/CD roles and every CodeBuild call on the four CI/CD deploy
  projects, so no workload role can act as the CI/CD pipeline.
- The pipeline's Processing and Training jobs run with their own job role,
  which reads the scripts and data and writes only the job output prefixes.
  The execution role (pipeline, endpoint model, scheduled jobs, A2I flow,
  MLflow server) cannot write the scripts, and neither role can approve a
  model package or deploy an endpoint. The execution role registers model
  packages only as `PendingManualApproval`: its `sagemaker:CreateModelPackage`
  grant requires that `sagemaker:ModelApprovalStatus`.
- The CI/CD CodeBuild role is scoped per service to project resources, split
  across customer managed policies. It can create roles, and change their
  policies, only with the workload boundary (it can also update, tag and
  delete any `<project_name>-*` role), can attach only an allowlist of managed
  policies, is denied attaching the CI/CD policies or the boundary itself to
  any role, and is denied changes to the CI/CD roles and their policies. Its
  Terraform state access is limited to the training and inference state and
  lock files; it cannot administer the state bucket, delete state versions or
  change the state key. AWS KMS keys and Amazon CloudFront distributions are
  scoped by the `Project` tag, and so are Amazon API Gateway REST APIs, API
  keys and usage plans (their child resources inherit the tag), and the role
  may tag only resources without a
  `Project` tag or with this project's, using the stacks' four tag keys.
- The internet-facing inference Lambda and the weekly endpoint refresher have
  separate roles. The inference role can invoke the endpoint, start an
  Amazon A2I human loop and read and write its results, but cannot change a
  model, an endpoint configuration or the endpoint, and holds no
  `iam:PassRole`; its `bedrock:InvokeModel` is limited to the configured
  inference profile and that profile's foundation model. Of the inference
  stack's functions, only the refresher can create models and endpoint
  configurations and update the endpoint; the auto-deploy Lambda function
  (on an approval event) and the CI/CD role can as well.
- Role policies are scoped to project-prefixed ARNs, or to the `Project` tag,
  wherever the service supports resource-level permissions, with two
  exceptions: SageMaker job names are generated by the pipeline, so the
  pipeline role reaches the processing, training and transform jobs of the
  stack's Region and account; and the CI/CD role's CloudFront origin access
  controls and response headers policies (item 4 below). Project-prefixed
  bucket names are also denied in other accounts (`s3:ResourceAccount`),
  because bucket names are global. Lambda functions write only to project log
  groups, the inference, refresher and test traffic functions only to their
  own. Every `iam:PassRole` is constrained by
  `iam:PassedToService`. No AWS managed `*FullAccess` policies are used.
  Service trust policies carry `aws:SourceAccount` and `aws:SourceArn`
  conditions where the service sets them.
- The statements that still use `Resource "*"`, and why each one needs it:
  1. Actions that support no resource-level permissions, so IAM accepts only
     `*`:
     - `ecr:GetAuthorizationToken` (SageMaker roles, patched image build role,
       CI/CD build role). The image pulls themselves are limited to
       the named repositories.
     - `cloudwatch:PutMetricData` (SageMaker roles, inference and
       upload quarantine Lambda functions, CI/CD build role), each limited to
       the project's metric namespaces with a `cloudwatch:namespace`
       condition.
     - `xray:PutTraceSegments` and `xray:PutTelemetryRecords` for the Lambda
       functions with active tracing.
     - `inspector2:ListFindings` (patched image build role and boundary),
       for the image scan gate.
     - Read-only list, describe and search calls: SageMaker `List*` and
       `Search`, Application Auto Scaling `Describe*`, CloudWatch
       `GetMetricData`, `GetMetricStatistics`, `ListMetrics` and
       `ListDashboards` (CI/CD build role), CloudWatch Logs `DescribeLogGroups`,
       `s3:ListAllMyBuckets`, `scheduler:ListSchedules`, `wafv2:ListWebACLs`,
       CloudTrail `DescribeTrails` and `ListTrails`, `iam:GetAccountSummary`
       and `iam:ListAccountAliases`, `cloudformation:GetResource` (used by the
       AWS Cloud Control provider) and `sts:GetCallerIdentity`.
     - The CloudWatch Logs log-delivery calls that set up AWS WAF logging
       (`logs:CreateLogDelivery`, `logs:DeleteLogDelivery`,
       `logs:PutResourcePolicy`, `logs:DescribeResourcePolicies`).
     - The AWS managed policy `AmazonAPIGatewayPushToCloudWatchLogs` on the
       API Gateway logging role, which only API Gateway assumes. The
       `aws_api_gateway_account` setting it is attached through is account
       and Region wide, so applying the stack replaces any CloudWatch Logs
       role an existing API Gateway setup uses.
  2. Create calls whose resource does not exist yet: CloudFront
     `CreateOriginAccessControl` and `CreateResponseHeadersPolicy` with their
     `List*` calls, and `cloudfront:CreateDistribution` and `kms:CreateKey`,
     both allowed only with the project's `Project` request tag and the four
     default tag keys.
  3. `kms:ListKeys` and `kms:ListAliases` for the CI/CD build role (no
     resource type).
  4. CloudFront origin access controls and response headers policies for the
     CI/CD build role, on `origin-access-control/*` and
     `response-headers-policy/*` of the account: they have generated IDs and
     support no condition keys, so they cannot be limited to this project.
  5. The Amazon EC2 network-interface actions SageMaker needs for jobs in a
     VPC (SageMaker roles and boundary). The SageMaker documentation
     grants them on `*`; the job-creation checks fail when they are scoped.
  6. The deny statement `DenyAttachingCiPoliciesAndBoundary`, which applies to
     every role and is limited by `iam:PolicyARN`.
  7. The permissions boundary's service statement: a boundary is a ceiling,
     not a grant, so every action it lists still needs a scoped identity
     policy.
  8. AWS KMS key policies, where `Resource "*"` means the key itself. Their
     service statements are limited by encryption context or by
     `aws:SourceAccount` and `aws:SourceArn`; key administration goes to the
     principals in `kms_key_administrators` (the account root when empty).

### Network isolation

- Every pipeline Processing and Training job, and the scheduled drift and
  fairness jobs, run in a private Amazon VPC that `stack-training` creates
  (`training_vpc_enabled`, default `true`): two private subnets with no
  internet gateway and no NAT gateway, an S3 gateway endpoint whose policy
  allows only the project buckets (so a job cannot copy data to another
  bucket), and a CloudWatch metrics interface endpoint
  (`training_vpc_monitoring_endpoint`) for the scheduled jobs' metrics. The
  jobs' security group allows outbound HTTPS only to S3 and that endpoint,
  plus traffic between instances of one job; the VPC's default security group
  has no rules. VPC flow logs (`training_vpc_flow_logs`, default `true`)
  record accepted and rejected flows.
- Every Processing and Training job of the pipeline encrypts traffic between
  its instances (`EnableInterContainerTrafficEncryption`), and the jobs'
  security group allows it. A `vpc_config` of your own needs UDP 500 and ESP
  (protocol 50) between its members.
- Training jobs run with network isolation by default
  (`enable_network_isolation`): the containers have no outbound network
  access. Your own backbone weights (`backbone_weights_s3_uri`, optional)
  reach them as an input channel; by default the models train from random
  initialisation.
- The serving model runs with network isolation (`endpoint_network_isolation`,
  default `true`): the inference handler only calls the TensorFlow Serving
  process in its own container.
- Processing jobs are not network isolated, because their scripts call S3
  (and the scheduled jobs CloudWatch) themselves; the VPC limits what they can
  reach. They install pinned Python packages from wheelhouses in the scripts
  bucket, not from PyPI.
- `vpc_config` runs the jobs in subnets of your own instead, and
  `training_vpc_enabled = false` runs them in the SageMaker service network.
  The endpoint and the Lambda functions do not run in a VPC.

### API access and AWS WAF

- The Amazon API Gateway routes `POST /predict` and `GET /results/{id}` require
  an API key (`x-api-key`) attached to a usage plan (10 requests per second,
  burst 20, 10,000 requests per month per key by default), plus stage
  throttling (20 requests per second, burst 50) and reserved Lambda
  concurrency (50).
- The API key is metering, not authentication. It is injected into the static
  web UI, so anyone who loads the page can read it. It limits and identifies
  traffic; it does not prove who the caller is.
- To authenticate callers, set `api_authorization_type` in `stack-inference`
  (default `NONE`, API key only). The API key, usage plan and AWS WAF stay on
  in every mode.
  - `COGNITO_USER_POOLS`: the stack creates an Amazon Cognito user pool and an
    app client without a secret (or uses the pools in
    `api_cognito_user_pool_arns`), and API Gateway rejects a request without a
    valid ID token in the `Authorization` header (HTTP 401) before the Lambda
    runs. The pool has no self sign-up (administrators create users), requires
    12-character passwords with upper case, lower case, digits and symbols,
    offers authenticator-app MFA (`cognito_mfa_configuration`, `OPTIONAL` by
    default or `ON`), and issues ID tokens valid for 60 minutes. Threat
    protection (`cognito_threat_protection_mode`) is off by default. The
    static web UI has no sign-in flow yet, so it stops working in this mode.
  - `AWS_IAM`: callers sign requests with SigV4 and need `execute-api:Invoke`
    on the API. Browsers get temporary credentials from an Amazon Cognito
    identity pool.
- A regional AWS WAF web ACL (`api_enable_waf`, default `true`) is associated
  with the API stage: `AWSManagedRulesCommonRuleSet` (with
  `SizeRestrictions_BODY` set to count, because `/predict` carries a base64
  image; the API request model and the Lambda enforce the real size limit,
  `max_image_bytes`, 5 MB by default, HTTP 413 above it),
  `AWSManagedRulesKnownBadInputsRuleSet`, and a per-IP rate-based rule that
  blocks an IP after `api_waf_rate_limit` requests (300 by default) in a
  5-minute window. WAF logs go to an AWS KMS encrypted CloudWatch Logs log
  group with the `x-api-key` header redacted.
- CORS allows only the Amazon CloudFront origin of the web UI. CloudFront has
  no web ACL; it serves only static files, redirects viewers to HTTPS and adds
  security headers through a response headers policy: HTTP Strict Transport
  Security with `includeSubDomains` and `preload`, frame protection, content
  type sniffing protection, a referrer policy, XSS protection and a Content
  Security Policy. The policy allows scripts and styles from the page's own
  origin only (the page has no inline script or style), images from `blob:`
  URLs, and requests to the prediction API's URL only.
- `GET /results/{id}` accepts only a UUID-shaped request id. Any key holder who
  knows a request id can read that result.
- The optional synthetic test traffic (`test_traffic_enabled`, off by default,
  for test deployments only) invokes the inference Lambda directly, so its
  requests do not pass API Gateway, WAF or the authorizer. Its role can only
  read the `training_data_path` prefix in the raw data bucket, decrypt with
  the project key and invoke the inference function, and its schedule stops at
  `test_traffic_end_date`. Do not turn it on for an endpoint that serves real
  users.

### Inference input and model output

- The inference Lambda accepts JPEG and PNG only. It checks the image format
  before it decodes the pixels, checks the payload size before decoding, and
  treats a Pillow decompression-bomb warning as an error, so an oversized image
  is rejected instead of being decoded.
- Amazon Bedrock is called only with a guardrail configured: without
  `BEDROCK_GUARDRAIL_ID` and its version the Lambda makes no Bedrock call. The
  stack publishes a numbered guardrail version for the Lambda (never the
  working draft), encrypted with the project key. It filters hate, insults,
  sexual content, violence and misconduct in the prompt and the response (the
  first four in the uploaded image as well, `bedrock_guardrail_image_filters`)
  and anonymises names in the output. The prompt text is fixed by the Lambda;
  the caller supplies only the image. A prompt attack filter is configured,
  but Amazon Bedrock evaluates it only on input marked with guardrail tags,
  which the function does not send, so it checks nothing today. Only
  predictions below the confidence threshold (0.70 by default) go to Amazon
  Bedrock.
- Model archives are extracted one member at a time, and only regular files
  that resolve inside the target directory: links, devices and paths that
  escape the directory are rejected. Where Python has extraction filters
  (3.12 and later, and the security backports), `tarfile`'s `filter="data"`
  applies as well.

### Human-gated promotion

- The pipeline registers every model version, the placeholder baseline
  included, as `PendingManualApproval`. A person approves a version in the
  Model Registry with their own credentials: no role in the stacks holds
  `sagemaker:UpdateModelPackage`, and every `sagemaker:CreateModelPackage`
  grant requires `sagemaker:ModelApprovalStatus` = `PendingManualApproval`,
  so no role can register a package as `Approved`.
- The auto-deploy Lambda acts only on approval events for this project's model
  package group. Besides the EventBridge rule's filter, its own code checks the
  package ARN, account and group, and that the event's `ModelApprovalStatus`
  is `Approved`, before it deploys.
- A blue/green canary rollout with alarm-driven rollback puts the approved
  version on the endpoint.

### Audit and monitoring joins

- A multi-Region CloudTrail trail with log-file validation is on by default
  (`enable_cloudtrail`). It records management events in the account plus data
  events: object-level S3 calls on the project buckets and invocations of the
  project's Lambda functions. Its bucket and the access-log bucket are kept on
  `terraform destroy` unless `audit_bucket_force_destroy = true`. In an account
  an organization trail already records, turn the trail off and add those data
  events to the organization trail.
- The inference Lambda passes its request id as the endpoint `InferenceId`, so
  data capture, the stored result, the API response and the ground-truth label
  you upload all share one key. The fairness job joins on it and skips
  predictions without a label instead of guessing.

### Supply chain and dependencies

- Downloads are pinned and verified. CodeBuild checks the Terraform release
  against HashiCorp's `SHA256SUMS`, verifies that file's signature with
  HashiCorp's published key, and applies only a saved plan. The patched image
  build installs Syft from its versioned release tarball after checking a
  pinned SHA-256. The GitLab pipeline installs the Automated Security Helper
  (ASH) from github.com/awslabs/automated-security-helper at a pinned commit,
  not the PyPI package of the same name, which is not the AWS project.
- The inference image is the AWS Deep Learning Container patched by a
  CodeBuild project at first apply and weekly after that
  (`rebuild_schedule_expression`), and the weekly endpoint refresher repins the
  live endpoint to the newest build, so container patches go live without an
  apply. The ECR repository is tag immutable with scan on push; each build
  pushes a dated tag, and the endpoint and the auto-deploy Lambda pin the image
  by digest. A CycloneDX SBOM is written to the SBOM bucket per build.
- The image build applies every available OS update and upgrades `pip`,
  `setuptools` and `wheel` without pinning them, on purpose: each weekly image
  should carry the newest patches. A scan gate then checks the pushed image:
  an image with an Amazon ECR scan finding at or above
  `patched_image_scan_block_severity` (default `CRITICAL`) is deleted and the
  build fails, and a CloudWatch alarm on failed builds notifies the alerts
  topic. The image is pushed before the gate runs, so if a build stops during
  the gate (the build timeout is 120 minutes) or the delete fails, an
  unchecked image can stay in the repository, and the next apply or weekly
  refresh would pin it as the newest; the failed-build alarm is the signal to
  delete it. Otherwise the endpoint keeps the last image that passed. Amazon ECR basic scanning covers OS
  packages; Amazon Inspector enhanced scanning also covers Python packages,
  and the build role can read its findings (`inspector2:ListFindings`).
- Terraform `~> 1.15` is pinned in each stack's `versions.tf`, with the AWS
  provider `~> 6.54` in `stack-inference` (needed for the Amazon Bedrock
  guardrail's image filters) and `~> 6.0` in the other stacks. Python 3.13 or later is used for local tooling
  (`pyproject.toml`). Training and serving use AWS Deep Learning Containers;
  the scheduled drift and fairness jobs use the SageMaker scikit-learn image.
  Processing steps install the packages pinned in each step's
  `requirements.txt` from wheels that `scripts/script_uploader.sh` downloads at
  upload time. Python tooling (`ruff`, `pytest`, `checkov`) is used for checks
  and is not deployed.
- Keep dependencies current when adapting this project, and review the SBOM in
  the SBOM bucket for the exact contents of a built inference image.

### Continuous integration

- On GitHub, [.github/workflows/ci.yml](.github/workflows/ci.yml) runs on every
  push to `main` and every pull request, with read-only permissions, actions
  pinned by commit and no AWS credentials: `terraform fmt` and `validate` on
  all four stacks, `checkov`, `ruff` and `pytest`.
- `.gitlab-ci.yml` is provided for teams that mirror the sample into GitLab;
  it runs `ruff`, the GitLab managed security scanners and ASH, and does not
  run on GitHub.
- Run the same checks locally with `make fmt validate lint test`.

## Known limitations

| # | Item | Impact | Recommendation |
| --- | --- | --- | --- |
| 1 | API key is the only caller control by default | Anyone who loads the web UI can call the API within the usage plan and WAF limits. The web UI has no sign-in, so it works only in API key mode | Set `api_authorization_type` to `COGNITO_USER_POOLS` (the stack creates the user pool) or `AWS_IAM`, and add a sign-in flow to the web UI |
| 2 | CodeBuild privileged mode for the patched image build | Needed for docker-in-docker; a compromised buildspec could escalate inside the build environment | Use a rootless builder, or build images in a dedicated account |
| 3 | KMS key administration defaults to the account root | Any sufficiently privileged principal in the account can administer the keys | Set `kms_key_administrators` to the roles that may administer the keys |
| 4 | Log retention defaults to 365 days | Older logs are deleted | Raise `log_retention_days` if your policy needs a longer history, or ship logs to a SIEM |
| 5 | Endpoint and Lambda functions outside a VPC | Traffic to AWS services uses public service endpoints (the model container itself is network isolated) | Add private subnets and VPC endpoints for SageMaker, S3 and Amazon Bedrock |
| 6 | Stored images and predictions expire after `inference_results_retention_days` (30 by default) | Uploaded images stay in the inference results bucket until then, and `GET /results/{id}` returns 404 afterwards | Set `inference_results_retention_days` to match your retention policy |
| 7 | Fairness is only as good as the attribute you supply | When no image carries a subgroup (file name or `manifest.csv`) the in-pipeline fairness check is skipped | Supply a meaningful attribute and a ground-truth feed |
| 8 | Explanations are unvalidated and cost endpoint compute | `"explain": true` returns Grad-CAM and sampled region Shapley values that nobody has checked against human annotations, and each explained request runs up to `explanation_max_evaluations` extra forward passes per member model | Validate the maps with domain experts before showing them to users; keep the caps, or set `enable_request_explanations = false` on a public API |
| 9 | No cross-Region replication, Lambda code signing or custom CloudFront certificate | Reduced DR and deployment integrity controls; with the default certificate CloudFront still accepts older TLS versions | Add them for production |
| 10 | The optional `stack-cicd` CodeBuild role has no permissions for the training VPC (Amazon EC2), the Amazon Cognito user pool, the Amazon Bedrock guardrail the CloudFront standard log delivery (CloudWatch Logs `*Delivery*` calls in us-east-1) or the patched image CodeBuild project (create, update, start) | A pipeline deploy fails when those options are on, which includes the defaults `training_vpc_enabled` and `enable_s3_access_logging` | Deploy those options with `make` from a workstation, or extend the role in `stack-cicd/main.tf` first |
| 11 | Tag-based scoping in the CI/CD role | A KMS key or CloudFront distribution in the account with no `Project` tag can be tagged into the project (needed for the tags sent at creation) and then managed as a project resource, and every CloudFront origin access control and response headers policy in the account can be changed. The state key and state bucket are explicitly denied | Deploy into a dedicated account |
| 12 | No approval before the CI/CD Training-Deploy stage | Every push to `github_branch` applies `stack-training` (IAM roles, KMS keys, CloudTrail) with the CI/CD role, so anyone who can push to that branch acts as that role | Protect the branch (pull requests with an approving review by someone other than the author, stale approvals dismissed, no force pushes, deletion or bypass), limit who can merge and limit the AWS Connector for GitHub app to the repository, or add a manual approval before Training-Deploy (`stack-cicd/README.md`, "Protect the release branch") |

## What you must still do

Before adapting this project for anything beyond a demo, at minimum:

1. **Authenticate callers** with Amazon Cognito (`api_authorization_type =
   "COGNITO_USER_POOLS"`) or IAM instead of the API key alone, add a sign-in
   flow to the web UI, stop rendering the API key into the page, and limit
   `GET /results/{id}` to the caller who made the prediction.
2. **Choose an approver process.** Decide who may approve model packages, and
   give `sagemaker:UpdateModelPackage` on the group only to them.
3. **Set `kms_key_administrators`** to the roles that may administer the keys,
   and separate key users from administrators.
4. **Use a custom domain** with an AWS Certificate Manager certificate and the
   `TLSv1.2_2021` security policy on CloudFront.
5. **Review the `Resource "*"` statements** listed above and narrow any your
   account can scope further, and deploy into a dedicated account.
6. **Check log retention** (365 days by default) against your policy, and keep
   an audit trail with data events: the stack's trail, or an organization
   trail that records the same events.
7. **Move serving into a VPC** with VPC endpoints. Training and the scheduled
   monitoring jobs already run in the private training VPC.
8. **Harden the image build** (rootless builder or separate account), sign
   images before the refresher repins them, and add Lambda code signing.
9. **Protect what must survive a destroy**: keep `audit_bucket_force_destroy =
   false`, set the bucket `force_destroy` settings to `false`, and turn on
   Cognito deletion protection once the pool holds real users.
10. **Set data retention**: `inference_results_retention_days` for the
    inference results bucket, and a lifecycle rule for the monitoring bucket.
11. **Provide real ground truth and sensitive attributes** for the fairness
    gate and the fairness monitor.
12. **Complete the compliance review** that applies to your data and use case
    (for example a privacy assessment for personal data, or the EU AI Act).
    The quality and fairness gates here are illustrative and are not a
    substitute for validating the model for your use case.

## Scanner findings kept

Every check below is skipped on purpose, with its reason in
[.checkov.yaml](.checkov.yaml):

| Check | Reason |
| --- | --- |
| CKV2_AWS_29 | The API's AWS WAF association is gated on `enable_waf` (default `true`), which Checkov does not resolve through the module |
| CKV_AWS_68 | The CloudFront distribution serves a static page from a private bucket; the API it calls has the regional web ACL, and a CloudFront web ACL must live in us-east-1 and is billed per ACL |
| CKV2_AWS_47 | Same CloudFront web ACL decision as CKV_AWS_68 |
| CKV2_AWS_51 | API Gateway client certificates need a custom domain name, which a sample cannot provide |
| CKV2_AWS_42 | A custom CloudFront certificate needs a custom domain name |
| CKV_AWS_117 | The Lambda functions call public AWS service endpoints; a VPC would need NAT or one interface endpoint per service |
| CKV_AWS_144 | Training data is uploaded by the user and models can be retrained; add cross-Region replication for disaster recovery in production |
| CKV_AWS_120 | Inference responses are per image and must never be served from a cache to another caller |
| CKV_AWS_225 | Same caching decision as CKV_AWS_120, at method level |
| CKV_AWS_374 | Geo restriction adds nothing for a static demo page |
| CKV_AWS_310 | Origin failover adds nothing for a static demo page |
| CKV_AWS_272 | Lambda code signing needs an AWS Signer profile per deployment |
| CKV2_AWS_62 | Only the web UI bucket has no event notifications, and nothing would consume them |
| CKV_AWS_50 | False positive: X-Ray tracing is on, but Checkov does not resolve it for module instances that use `count` |
| CKV_TF_1 | `stack-backend-setup` uses Terraform Registry modules pinned by version; a commit hash applies to Git sources only |

Thirteen more Checkov skips are inline in the Terraform, each with its reason:
CKV_AWS_174 (the minimum viewer TLS version can be set only with a custom
certificate; with the default `*.cloudfront.net` certificate CloudFront keeps
TLSv1, Known limitations item 9), CKV_AWS_316 (`docker build` in the patched
image build needs privileged mode), CKV2_AWS_5 twice (the jobs' security group is attached by SageMaker through
the pipeline's `VpcConfig`; the CloudWatch interface endpoint's security
group is attached through its `security_group_ids`, which Checkov does not
follow for count-indexed resources), CKV2_AWS_10 (the trail streams to its
log group; same Checkov limitation), CKV_AWS_394 (Availability Zone names and
IDs differ per account and Region, so a sample cannot pin them), CKV_AWS_86
(the distribution's access logs use standard logging v2 through the
CloudWatch Logs delivery resources), CKV2_AWS_77 (the web ACL has the
known-bad-inputs rule set; its association is gated on `enable_waf`), and
CKV_AWS_286, CKV_AWS_288, CKV_AWS_289, CKV_AWS_290 and CKV_AWS_355 on the
permissions boundary, which grants nothing on its own. The Terraform files also carry 29
inline ignore comments for the GitLab scanners, each with its reason next to
it. There are no `# nosec`, `# noqa` or `nosemgrep` suppressions in the Python
code.
