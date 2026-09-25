# Security

## Disclaimer

This repository is sample code for demonstration and learning. It is not a
production system and not a cleared clinical product. It shows how an
end-to-end MLOps lifecycle can be expressed in Terraform on Amazon SageMaker.

Do not deploy it as-is for clinical, diagnostic or any other production
workload. Several choices favour a readable public sample over production
hardening; they are listed under [Known limitations](#known-limitations) and
[What you must still do](#what-you-must-still-do). Review both before adapting
this code.

Deploying this project creates real, billable AWS resources. See the Costs and
Cleanup sections of [README.md](README.md).

## Reporting vulnerabilities

If you discover a potential security issue in this project, notify AWS Security
via the [vulnerability reporting page](https://aws.amazon.com/security/vulnerability-reporting/)
or email <aws-security@amazon.com>. **Do not** create a public issue or pull
request describing the vulnerability.

## Data handling

- The sample is built around a public histopathology dataset and contains no
  PHI or PII. No dataset is committed; `data/` is gitignored.
- Dataset licensing is your responsibility. Confirm the terms of any dataset you
  supply, and do not commit PHI or PII.
- The inference Lambda logs only the method, path, request id and payload size,
  never the image or the model response. Error responses are generic.
- Uploaded images and their predictions are stored in the inference results
  bucket under `predictions/<request_id>/` so `GET /results/{id}` can return
  them. The bucket is KMS-encrypted and versioned and has no expiry rule.
- Endpoint data capture stores model output only by default. Set
  `data_capture_input = true` only if you also want every request payload
  (every uploaded image) in the monitoring bucket.
- The dataset carries no demographic metadata, so both fairness checks use
  image magnification as a subgroup proxy. Supply a real sensitive attribute
  before drawing any fairness conclusion.

## Security model

### API access

- `POST /predict` and `GET /results/{id}` require an **API key** (`x-api-key`)
  attached to a usage plan (10 requests per second, burst 20, 10,000 requests
  per month per key by default), plus stage throttling (20 requests per second,
  burst 50) and reserved Lambda concurrency (50).
- **The API key is metering, not authentication.** It is injected into the
  static web UI, so anyone who loads the page can read it. It limits and
  identifies traffic; it does not prove who the caller is.
- To authenticate callers, set `api_authorization_type` in `stack-inference`:
  - `AWS_IAM`: callers sign requests with SigV4 and need `execute-api:Invoke`
    on the API. Browsers get temporary credentials from an Amazon Cognito
    identity pool.
  - `COGNITO_USER_POOLS`: set `api_cognito_user_pool_arns`; callers send the
    user pool ID token in the `Authorization` header. The static web UI would
    need a sign-in flow added.
- CORS allows only the CloudFront origin of the web UI.
- `GET /results/{id}` accepts only a UUID-shaped request id. Any key holder who
  knows a request id can read that result.

### AWS WAF

A regional web ACL (`api_enable_waf`, default `true`) is associated with the API
stage:

1. `AWSManagedRulesCommonRuleSet`, with `SizeRestrictions_BODY` set to count
   because `/predict` carries a base64 image. The API request model and the
   Lambda enforce the real size limit (`max_image_bytes`, 5 MB by default,
   HTTP 413 above it).
2. `AWSManagedRulesKnownBadInputsRuleSet`.
3. A per-IP rate-based rule that blocks an IP after `api_waf_rate_limit`
   requests (300 by default) in a 5-minute window.

WAF logs go to a KMS-encrypted CloudWatch log group with the `x-api-key` header
redacted. CloudFront has no web ACL; it serves only static files.

### Identity and access

- Every IAM role that `stack-training` and `stack-inference` create carries the
  `<project_name>-workload-boundary` **permissions boundary** from
  `stack-backend-setup`. It limits roles to the services the workload uses and
  allows `iam:PassRole` only on project roles, so no project role can grant
  itself IAM, Organizations or account-level access.
- Role policies are scoped to project-prefixed ARNs wherever the service
  supports resource-level permissions. Actions that accept only `*` (for
  example `cloudwatch:PutMetricData`) are isolated in their own statements.
  Every `iam:PassRole` is constrained by `iam:PassedToService`. No AWS managed
  `*FullAccess` policies are used.
- The CI/CD CodeBuild role is scoped per service to project resources, split
  across customer managed policies. It can create or change only roles that
  carry the workload boundary, can attach only an allowlist of managed
  policies, and is denied changes to the CI/CD roles, their policies and the
  boundary itself.
- Model promotion requires a human: the pipeline registers every version,
  including the placeholder baseline, as `PendingManualApproval`. The
  auto-deploy Lambda acts only on `Approved` events for this project's model
  package group.

### Encryption

- Customer managed KMS keys with rotation encrypt the Terraform state bucket,
  every project S3 bucket, CloudWatch log groups, Lambda environment variables,
  SQS dead-letter queues, the ECR repository, SageMaker job volumes and outputs,
  and the endpoint's ML storage volume.
- Bucket policies deny non-TLS requests; public access is blocked on every
  bucket; CloudFront redirects viewers to HTTPS. The distribution uses the
  default `*.cloudfront.net` certificate, so its `TLSv1.2_2021` minimum takes
  effect only once you attach your own ACM certificate.

### Training isolation and networking

- Training jobs run with **network isolation** by default
  (`enable_network_isolation`): the containers have no outbound network access
  and read ImageNet weights from the scripts bucket.
- Processing jobs are not isolated because they install Python packages at
  start-up.
- `vpc_config` in `stack-training` optionally runs training and Processing jobs
  in your private subnets. The endpoint and the Lambda functions do not run in a
  VPC.

### Monitoring joins and audit

- The inference Lambda passes its request id as the endpoint `InferenceId`, so
  data capture, the stored result, the API response and the confirmed outcome a
  clinician uploads all share one key. The fairness job joins on it and skips
  predictions without a confirmed label instead of guessing.
- An account CloudTrail trail with log-file validation is available
  (`enable_cloudtrail`) but off by default, because most accounts are already
  covered by an organization trail.

### Supply chain

- The inference image is the AWS Deep Learning Container patched by a CodeBuild
  project at first apply and monthly after that. The ECR repository is tag
  immutable with scan on push; each build pushes a dated tag, and the endpoint
  and the auto-deploy Lambda pin the image by digest. A CycloneDX SBOM is
  written to the SBOM bucket per build.
- CodeBuild verifies the Terraform release against HashiCorp's `SHA256SUMS` and
  applies only a saved plan.

## Continuous integration

On GitHub, [.github/workflows/ci.yml](.github/workflows/ci.yml) runs on every
push to `main` and every pull request, with read-only permissions and no AWS
credentials: `terraform fmt` and `validate` on all four stacks, `checkov`, `ruff`
and `pytest`. GitHub CodeQL code scanning also runs on the repository. Every
Checkov skip in [.checkov.yaml](.checkov.yaml) and every inline `# nosec` states
its reason.

`.gitlab-ci.yml` is provided for teams that mirror the sample into GitLab; it
does not run on GitHub.

Run the same checks locally with `make fmt validate lint test`.

## Known limitations

| # | Item | Impact | Recommendation |
| --- | --- | --- | --- |
| 1 | API key is the only caller control by default | Anyone who loads the web UI can call the API within the usage plan and WAF limits | Switch `api_authorization_type` to `AWS_IAM` or `COGNITO_USER_POOLS` |
| 2 | CodeBuild privileged mode for the patched image build | Needed for docker-in-docker; a compromised buildspec could escalate inside the build environment | Use a rootless builder, or build images in a dedicated account |
| 3 | KMS key administration defaults to the account root | Any sufficiently privileged principal in the account can administer the keys | Pass explicit administrator ARNs to the KMS module |
| 4 | Log retention of 14 to 30 days | Limited forensic history | Raise `log_retention_days` to 365 or more, or ship logs to a SIEM |
| 5 | Endpoint and Lambda functions outside a VPC; hosted model without network isolation | Traffic to AWS services uses public service endpoints | Add private subnets and VPC endpoints for SageMaker, S3 and Bedrock, and enable network isolation on the model |
| 6 | Stored images and predictions have no expiry | Uploaded images accumulate in the inference results bucket | Add a lifecycle rule that matches your retention policy |
| 7 | Fairness uses a proxy subgroup | Magnification says nothing about patient demographics | Supply a real sensitive attribute and a confirmed-outcome feed |
| 8 | Explainability is a placeholder | The evaluation step writes a uniform, channel-level placeholder report, and the optional `explainability` field in API responses points at a location no job in this sample writes to | Add a real attribution job (for example Grad-CAM) before relying on explanations |
| 9 | No cross-Region replication, Lambda code signing or custom CloudFront certificate | Reduced DR and deployment integrity controls | Add them for production |

## What you must still do

Before adapting this project for anything beyond a demo, at minimum:

1. **Authenticate callers** (limitation 1) and review who may hold the API key.
2. **Choose an approver process.** Decide who may approve model packages and
   restrict `sagemaker:UpdateModelPackage` to them.
3. **Set KMS key administrators** and, if needed, separate key users from
   administrators.
4. **Extend log retention** and turn on an audit trail if no organization
   trail covers the account.
5. **Move serving into a VPC** with VPC endpoints, and consider
   `vpc_config` for training.
6. **Harden the image build** (rootless builder or separate account) and add
   Lambda code signing.
7. **Set data retention** on the inference results and monitoring buckets.
8. **Provide real ground truth and sensitive attributes** for the fairness
   monitor.
9. **Complete the compliance review.** For any clinical use, complete the
   applicable regulatory assessment (for example HIPAA or the EU AI Act) and
   execute a Business Associate Addendum with AWS where required. The quality
   and fairness gates here are illustrative and are not a substitute for
   clinical validation.

## Dependencies

- **Terraform** `~> 1.15` with the AWS provider `~> 6.0`, pinned in each stack's
  `versions.tf`.
- **Python** 3.13 or later for local tooling (`pyproject.toml`). Training and
  serving use AWS Deep Learning Containers; the scheduled drift and fairness
  jobs use the SageMaker scikit-learn image.
- Python tooling (`ruff`, `pytest`, `checkov`) is used for checks and is not
  deployed.

Keep dependencies current when adapting this project, and review the SBOM in the
SBOM bucket for the exact contents of a built inference image.
