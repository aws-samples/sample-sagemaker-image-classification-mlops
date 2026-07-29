# ops-scripts

Operational helpers for humans - local-dev convenience scripts for building, testing, verifying, and cleaning up deployed infrastructure. **Not invoked by SageMaker, Lambda, or CI/CD** (the CI/CD buildspecs duplicate the logic inline for isolation).

## What is in here

| Script                  | Purpose                                                                          |
| ----------------------- | -------------------------------------------------------------------------------- |
| `build_lambda_layer.sh` | Build the Pillow + numpy Lambda layer locally for `inference/`                   |
| `cleanup_all.sh`        | ⚠️ Destructive. Empties S3 buckets, deletes logs, model packages, endpoints      |
| `test_api.py`           | Send a base64-encoded image to the deployed inference API and print results      |
| `verify_monitoring.sh`  | Smoke-check that CloudWatch metrics, alarms, SNS topics, EventBridge rules exist |

## Typical usage

```bash
# Build the Lambda layer locally (usually only needed for dev iteration;
# the inference-deploy CodeBuild job rebuilds it from scratch).
./ops-scripts/build_lambda_layer.sh

# Hit the deployed API with a test image
API_URL=$(cd stack-inference && terraform output -raw api_gateway_url)
python ops-scripts/test_api.py --api-url "$API_URL" --image-path data/breast_benign/sample.png

# Verify monitoring is wired up after a fresh deploy
./ops-scripts/verify_monitoring.sh

# Teardown everything that Terraform doesn't manage directly
# (review the script first - it deletes live resources)
./ops-scripts/cleanup_all.sh
```

## Naming convention

- Shell: `snake_case.sh` (e.g., `build_lambda_layer.sh`)
- Python: `snake_case.py` (e.g., `test_api.py`)
- Verb-first for action scripts: `build_*`, `cleanup_*`, `verify_*`, `test_*`
